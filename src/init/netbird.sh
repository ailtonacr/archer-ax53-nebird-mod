#!/bin/sh
# NetBird base library for TP-Link Archer AX53 V1 (QSDK/OpenWrt, Linux 4.4.60).
#
# This file owns persistent settings, R2 payload materialization, daemon process
# primitives and TP-Link firewall entrypoints. Connection lifecycle, status
# interpretation and canonical `netbird up` flags live in netbird-runtime.sh.
# Dependency direction is deliberately one-way: the base library never calls
# the netbird-ctl CLI facade.

. /lib/functions.sh
. /lib/functions/service.sh 2>/dev/null || true

NB_CONFIG_DIR="/tp_data/netbird"
NB_STATE_DIR="$NB_CONFIG_DIR/state"
NB_CONFIG_FILE="$NB_CONFIG_DIR/default.json"
NB_SETTINGS_FILE="$NB_CONFIG_DIR/settings"

NB_BIN="/tmp/netbird"
NB_BIN_NEW="/tmp/netbird.new"
NB_VALID="/tmp/netbird.valid"
NB_VALID_NEW="/tmp/netbird.valid.new"
NB_MATERIALIZE_LOCK="/tmp/netbird-materialize.lock"
NB_DL_STAMP="/tmp/netbird-dl-last"
NB_SOCK="/tmp/netbird.sock"
NB_LOG="/tmp/netbird.log"
NB_PID="/var/run/netbird.pid"

NB_DL_CLIENT="/usr/bin/curl"
NB_DL_CACERT="/etc/ssl/certs/ca-certificates.crt"
NB_DL_CONNECT_TIMEOUT="5"
NB_DL_MAX_TIME="30"
NB_DL_COOLDOWN="300"

NB_VERSION="0.77.1"
NB_PAYLOAD_URL="https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/netbird-dict8.xz"
NB_PAYLOAD_XZ_SIZE="9455188"
NB_PAYLOAD_XZ_SHA256="4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941"
NB_EXPECTED_SIZE="39125176"
NB_EXPECTED_SHA256="6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6"

NB_DEFAULT_MGMT="https://netbird.ailton.dev.br"
NB_DEFAULT_PORT="51820"

NB_ST_READY=0
NB_ST_NOT_DOWNLOADED=1
NB_ST_DOWNLOAD_FAILED=2
NB_ST_INVALID=3

nb_get() {
    local file="$1" key="$2" def="${3:-}"
    [ -f "$file" ] || { echo "$def"; return 1; }
    local val
    val=$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1)
    val=$(echo "$val" | sed 's/[[:space:]]*$//')
    if [ -n "$val" ]; then echo "$val"; else echo "$def"; fi
}

nb_set() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || { echo "${key}=${value}" > "$file"; return 0; }
    tmp="$file.tmp"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed "s/^${key}=.*/${key}=${value}/" "$file" > "$tmp"
    else
        cat "$file" > "$tmp"
        echo "${key}=${value}" >> "$tmp"
    fi
    mv -f "$tmp" "$file"
}

nb_ensure_settings() {
    mkdir -p "$NB_CONFIG_DIR"
    [ -d "$NB_CONFIG_DIR" ] && chmod 0700 "$NB_CONFIG_DIR"
    if [ ! -f "$NB_SETTINGS_FILE" ]; then
        cat > "$NB_SETTINGS_FILE" <<EOF
version=1
enable=0
enrolled=0
management_url=${NB_DEFAULT_MGMT}
hostname=
disable_dns=1
disable_firewall=1
disable_client_routes=1
disable_server_routes=1
disable_ipv6=1
network_monitor=0
advertise_lan=0
advertise_cidr=
wireguard_port=${NB_DEFAULT_PORT}
EOF
    fi
    chmod 0600 "$NB_SETTINGS_FILE"
    mkdir -p "$NB_STATE_DIR"
    chmod 0700 "$NB_STATE_DIR"
}

nb_payload_mark_valid() {
    local ver size sha
    [ -x "$NB_BIN" ] && [ -f "$NB_VALID" ] || return 1
    ver=$(sed -n 's/^version=//p' "$NB_VALID" 2>/dev/null | head -n 1)
    size=$(sed -n 's/^size=//p' "$NB_VALID" 2>/dev/null | head -n 1)
    sha=$(sed -n 's/^sha256=//p' "$NB_VALID" 2>/dev/null | head -n 1)
    [ "$ver" = "$NB_VERSION" ] && [ "$size" = "$NB_EXPECTED_SIZE" ] && \
        [ "$sha" = "$NB_EXPECTED_SHA256" ] || return 1
    [ "$(ls -ln "$NB_BIN" 2>/dev/null | awk '{print $5}')" = "$NB_EXPECTED_SIZE" ]
}

nb_payload_write_marker() {
    umask 077
    cat > "$NB_VALID_NEW" <<EOF
version=$NB_VERSION
size=$NB_EXPECTED_SIZE
sha256=$NB_EXPECTED_SHA256
EOF
    chmod 0600 "$NB_VALID_NEW" && mv -f "$NB_VALID_NEW" "$NB_VALID"
}

nb_payload_status() {
    if nb_payload_mark_valid; then
        return "$NB_ST_READY"
    elif [ -e "$NB_BIN" ]; then
        return "$NB_ST_INVALID"
    fi
    return "$NB_ST_NOT_DOWNLOADED"
}

nb_payload_verify() {
    local sz sha
    [ -x "$NB_BIN" ] || { rm -f "$NB_VALID"; return "$NB_ST_NOT_DOWNLOADED"; }
    sz=$(ls -ln "$NB_BIN" 2>/dev/null | awk '{print $5}')
    if [ "$sz" != "$NB_EXPECTED_SIZE" ]; then
        rm -f "$NB_VALID" "$NB_BIN"
        return "$NB_ST_INVALID"
    fi
    sha=$(sha256sum "$NB_BIN" 2>/dev/null | awk '{print $1}')
    if [ "$sha" != "$NB_EXPECTED_SHA256" ] || ! nb_payload_write_marker; then
        rm -f "$NB_VALID" "$NB_VALID_NEW" "$NB_BIN"
        return "$NB_ST_INVALID"
    fi
    return "$NB_ST_READY"
}

# Streamed two-pass materialization keeps only the decoded ELF in tmpfs. The
# compressed and decoded SHA256 values are both pinned and validated fail-closed.
nb_materialize() (
    local force="$1"
    nb_payload_mark_valid && return "$NB_ST_READY"

    if ! mkdir "$NB_MATERIALIZE_LOCK" 2>/dev/null; then
        local tries=30
        while [ "$tries" -gt 0 ]; do
            nb_payload_mark_valid && return "$NB_ST_READY"
            [ -d "$NB_MATERIALIZE_LOCK" ] || return "$NB_ST_DOWNLOAD_FAILED"
            tries=$((tries - 1))
            sleep 1
        done
        return "$NB_ST_DOWNLOAD_FAILED"
    fi
    trap 'rc=$?; rmdir "$NB_MATERIALIZE_LOCK" 2>/dev/null; exit "$rc"' EXIT
    trap 'rmdir "$NB_MATERIALIZE_LOCK" 2>/dev/null; exit 1' HUP INT TERM

    nb_payload_mark_valid && return "$NB_ST_READY"
    rm -f "$NB_VALID" "$NB_VALID_NEW"
    if [ -e "$NB_BIN" ]; then
        nb_payload_verify && return "$NB_ST_READY"
    fi

    [ -n "$NB_PAYLOAD_URL" ] || {
        echo "netbird: no payload URL configured" >&2
        return "$NB_ST_NOT_DOWNLOADED"
    }

    if [ "$force" != "1" ] && [ -f "$NB_DL_STAMP" ]; then
        local last now
        last=$(cat "$NB_DL_STAMP" 2>/dev/null || echo 0)
        now=$(date +%s 2>/dev/null || echo 0)
        if [ $(( ${now:-0} - ${last:-0} )) -lt "$NB_DL_COOLDOWN" ]; then
            return "$NB_ST_DOWNLOAD_FAILED"
        fi
    fi
    date +%s > "$NB_DL_STAMP" 2>/dev/null

    rm -f "$NB_BIN_NEW" "$NB_VALID"
    echo "netbird: downloading payload (${NB_VERSION}) ..." >&2

    local sha empty_sha
    empty_sha="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    sha=$( "$NB_DL_CLIENT" -fsS --connect-timeout "$NB_DL_CONNECT_TIMEOUT" \
           --max-time "$NB_DL_MAX_TIME" --cacert "$NB_DL_CACERT" \
           "$NB_PAYLOAD_URL" 2>>"$NB_LOG" | sha256sum | awk '{print $1}' )
    if [ "$sha" = "$empty_sha" ]; then
        echo "netbird: payload download failed (no data received)" >&2
        return "$NB_ST_DOWNLOAD_FAILED"
    fi
    if [ "$sha" != "$NB_PAYLOAD_XZ_SHA256" ]; then
        echo "netbird: xz sha256 mismatch" >&2
        return "$NB_ST_INVALID"
    fi

    if ! "$NB_DL_CLIENT" -fsS --connect-timeout "$NB_DL_CONNECT_TIMEOUT" \
         --max-time "$NB_DL_MAX_TIME" --cacert "$NB_DL_CACERT" \
         "$NB_PAYLOAD_URL" 2>>"$NB_LOG" | /sbin/xzmini > "$NB_BIN_NEW" 2>>"$NB_LOG"; then
        rm -f "$NB_BIN_NEW"
        echo "netbird: decode failed" >&2
        return "$NB_ST_INVALID"
    fi

    local sz
    sz=$(wc -c < "$NB_BIN_NEW" 2>/dev/null)
    if [ "$sz" != "$NB_EXPECTED_SIZE" ]; then
        rm -f "$NB_BIN_NEW"
        echo "netbird: size mismatch $sz != $NB_EXPECTED_SIZE" >&2
        return "$NB_ST_INVALID"
    fi
    sha=$(sha256sum "$NB_BIN_NEW" | awk '{print $1}')
    if [ "$sha" != "$NB_EXPECTED_SHA256" ]; then
        rm -f "$NB_BIN_NEW"
        echo "netbird: sha256 mismatch" >&2
        return "$NB_ST_INVALID"
    fi

    chmod 0755 "$NB_BIN_NEW"
    mv -f "$NB_BIN_NEW" "$NB_BIN"
    if ! nb_payload_write_marker; then
        rm -f "$NB_VALID" "$NB_VALID_NEW" "$NB_BIN"
        return "$NB_ST_INVALID"
    fi
    return "$NB_ST_READY"
)

nb_state_name() {
    case "$1" in
        0) echo "READY" ;;
        1) echo "PAYLOAD_NOT_DOWNLOADED" ;;
        2) echo "PAYLOAD_DOWNLOAD_FAILED" ;;
        3) echo "PAYLOAD_INVALID" ;;
        *) echo "UNKNOWN" ;;
    esac
}

nb_mgmt_url() {
    nb_get "$NB_SETTINGS_FILE" management_url "$NB_DEFAULT_MGMT"
}

# Process primitives only. Connection semantics are in netbird-runtime.sh.
nb_daemon_start() {
    nb_materialize || return $?
    nb_ensure_settings
    mkdir -p /var/run
    rm -f "$NB_PID" "$NB_SOCK"
    local hostname args
    hostname=$(nb_get "$NB_SETTINGS_FILE" hostname "")
    args="service run --config $NB_CONFIG_FILE --management-url $(nb_mgmt_url) --daemon-addr unix://$NB_SOCK --log-file $NB_LOG --log-level info"
    [ -n "$hostname" ] && args="$args --hostname $hostname"
    export NB_STATE_DIR NB_LOG_MAX_SIZE_MB=2
    SERVICE_PID_FILE="$NB_PID" SERVICE_DAEMONIZE=1 SERVICE_WRITE_PID=1 \
        service_start "$NB_BIN" $args
}

nb_daemon_stop() {
    [ -S "$NB_SOCK" ] && [ -x "$NB_BIN" ] && \
        "$NB_BIN" down --daemon-addr "unix://$NB_SOCK" >/dev/null 2>&1 || true
    SERVICE_PID_FILE="$NB_PID" service_stop "$NB_BIN"
    rm -f "$NB_PID" "$NB_SOCK"
}

# Optional explicit values let the runtime remove the exact firewall state that
# was previously installed, even after settings were changed by a later Save.
nb_fw_access() {
    local port access cidr homeif
    port="${1:-$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")}"
    if [ $# -ge 2 ]; then
        access="$2"
    elif [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ]; then
        access="lan"
    else
        access="home"
    fi
    if [ $# -ge 3 ]; then cidr="$3"; else cidr="$(nb_get "$NB_SETTINGS_FILE" advertise_cidr "")"; fi
    if [ $# -ge 4 ]; then
        homeif="$4"
    else
        homeif="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
        [ -n "$homeif" ] || homeif="br-lan"
    fi
    fw netbird_access "$port" "$access" "$cidr" "$homeif" 2>/dev/null
}

nb_fw_block() {
    local port access cidr homeif
    port="${1:-$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")}"
    if [ $# -ge 2 ]; then
        access="$2"
    elif [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ]; then
        access="lan"
    else
        access="home"
    fi
    if [ $# -ge 3 ]; then cidr="$3"; else cidr="$(nb_get "$NB_SETTINGS_FILE" advertise_cidr "")"; fi
    if [ $# -ge 4 ]; then
        homeif="$4"
    else
        homeif="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
        [ -n "$homeif" ] || homeif="br-lan"
    fi
    fw netbird_block "$port" "$access" "$cidr" "$homeif" 2>/dev/null
}
