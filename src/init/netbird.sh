#!/bin/sh
# NetBird shared library for TP-Link Archer AX53 V1 (QSDK/OpenWrt, Linux 4.4.60).
#
# Architecture (R2 runtime): the NetBird binary is NOT stored on any MTD/UBI
# partition. On demand it is downloaded over HTTPS from a public Cloudflare R2
# bucket, stream-decoded with /sbin/xzmini into /tmp (tmpfs), hash-validated
# (compressed + ELF sha256 are pinned here), then executed. Identity and
# settings remain persistent in /tp_data/netbird. If the download fails the
# boot/service path is fail-closed: NetBird stays stopped, everything else
# (WAN / WiFi / DHCP / WireGuard legacy) is untouched.
#
# This file is sourced by /etc/init.d/netbird and /sbin/netbird-ctl. It must
# NOT rely on a JSON parser: the router busybox shell has none, so our own
# settings file uses a simple key=value format.

. /lib/functions.sh
. /lib/functions/service.sh 2>/dev/null || true

# --- paths -----------------------------------------------------------------
NB_CONFIG_DIR="/tp_data/netbird"         # persistent identity + settings
NB_STATE_DIR="$NB_CONFIG_DIR/state"      # NetBird runtime state (NB_STATE_DIR)
NB_CONFIG_FILE="$NB_CONFIG_DIR/default.json"   # NetBird profile config (0600)
NB_SETTINGS_FILE="$NB_CONFIG_DIR/settings"     # our settings (key=value, 0600)

NB_BIN="/tmp/netbird"                    # materialized binary (tmpfs)
NB_BIN_NEW="/tmp/netbird.new"            # staging during decode
NB_VALID="/tmp/netbird.valid"            # metadata written after deep validation
NB_VALID_NEW="/tmp/netbird.valid.new"    # atomic marker staging path
NB_MATERIALIZE_LOCK="/tmp/netbird-materialize.lock"
NB_DL_STAMP="/tmp/netbird-dl-last"       # last download attempt timestamp (cooldown)
NB_SOCK="/tmp/netbird.sock"              # daemon control socket
NB_LOG="/tmp/netbird.log"                # runtime log (tmpfs, rotated)
NB_PID="/var/run/netbird.pid"            # daemon pid file

# --- downloader (HTTPS, TLS verified; pinned payload) ----------------------
NB_DL_CLIENT="/usr/bin/curl"
NB_DL_CACERT="/etc/ssl/certs/ca-certificates.crt"  # device CA bundle (verified)
NB_DL_CONNECT_TIMEOUT="5"
NB_DL_MAX_TIME="30"
NB_DL_COOLDOWN="300"                     # seconds between automatic retries

# --- NetBird payload constants (validated offline; immutable R2 object) ----
NB_VERSION="0.77.1"
NB_PAYLOAD_URL="https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/netbird-dict8.xz"
NB_PAYLOAD_XZ_SIZE="9455188"             # 9,455,188 bytes (compressed)
NB_PAYLOAD_XZ_SHA256="4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941"
NB_EXPECTED_SIZE="39125176"              # 39,125,176 bytes (uncompressed ELF)
NB_EXPECTED_SHA256="6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6"

# --- defaults ---------------------------------------------------------------
NB_DEFAULT_MGMT="https://netbird.ailton.dev.br"
NB_DEFAULT_PORT="51820"                  # WireGuard/ICE UDP port

# --- payload/materialization states (fail-closed; no MTD/UBI involvement) ---
NB_ST_READY=0                    # payload materialized + hash-valid
NB_ST_NOT_DOWNLOADED=1           # no payload yet / nothing to download
NB_ST_DOWNLOAD_FAILED=2          # HTTPS download failed (network/TLS/cooldown)
NB_ST_INVALID=3                  # download ok but size/hash/decode validation failed

# ---------------------------------------------------------------------------
# settings helpers
# ---------------------------------------------------------------------------

# nb_get <file> <key> [default]  -> prints value (or default) to stdout
nb_get() {
    local file="$1" key="$2" def="${3:-}"
    [ -f "$file" ] || { echo "$def"; return 1; }
    local val
    val=$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1)
    val=$(echo "$val" | sed 's/[[:space:]]*$//')
    if [ -n "$val" ]; then echo "$val"; else echo "$def"; fi
}

# nb_set <file> <key> <value>  -> write/update a key=value line (atomic-ish)
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

# nb_ensure_settings  -> create settings with safe defaults if absent
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

# ---------------------------------------------------------------------------
# payload materialization (R2 HTTPS download + xzmini + pinned validation)
# ---------------------------------------------------------------------------

# The marker is trusted only for this tmpfs lifetime. Its metadata is created
# atomically after the compressed and decoded payload hashes have both passed.
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

# Cheap runtime state query for UI polling. It never downloads, hashes, or
# changes the payload. A present executable without a valid marker is unsafe.
nb_payload_status() {
    if nb_payload_mark_valid; then
        return "$NB_ST_READY"
    elif [ -e "$NB_BIN" ]; then
        return "$NB_ST_INVALID"
    fi
    return "$NB_ST_NOT_DOWNLOADED"
}

# Explicit O(n) integrity check for diagnostics and repair paths only.
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

# nb_materialize [force]  -> ensure /tmp/netbird is present and hash-valid.
#
#   force=1 bypasses the automatic-attempt cooldown (used by boot start and by
#   explicit manual actions: UI start/restart, enroll). Non-forced callers
#   (status / payload-status polling) respect the cooldown, so there is no
#   aggressive download loop.
#
#   RAM strategy: this AX53's /tmp is a RAM-backed tmpfs (~96 MiB) and the
#   device is tight on memory. To keep the peak low, NOTHING stores the
#   9.45 MiB compressed object. Pass 1 streams the download straight into
#   sha256sum to verify the PINNED compressed hash; pass 2 streams it straight
#   into /sbin/xzmini -> /tmp/netbird.new. Peak tmpfs stays at the single
#   39,125,176-byte decoded ELF. Both hashes are pinned and validated before
#   anything is made executable (fail-closed).
#
#   returns: 0 READY | 1 PAYLOAD_NOT_DOWNLOADED | 2 PAYLOAD_DOWNLOAD_FAILED
#            | 3 PAYLOAD_INVALID
nb_materialize() (
    local force="$1"

    # Fast path for a payload already validated in this tmpfs lifetime.
    nb_payload_mark_valid && return "$NB_ST_READY"

    # Only materialization paths take this lock. Polling calls
    # nb_payload_status(), so it never waits for a slow download or hash.
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

    # Another caller may have completed materialization before we got the lock.
    nb_payload_mark_valid && return "$NB_ST_READY"
    rm -f "$NB_VALID" "$NB_VALID_NEW"

    # A pre-marker payload is not trusted until the explicit deep check passes.
    if [ -e "$NB_BIN" ]; then
        nb_payload_verify && return "$NB_ST_READY"
    fi

    [ -n "$NB_PAYLOAD_URL" ] || {
        echo "netbird: no payload URL configured" >&2
        return "$NB_ST_NOT_DOWNLOADED"
    }

    # throttle automatic attempts (manual actions force a retry)
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

    # Pass 1: verify the COMPRESSED sha256 by streaming (nothing stored on tmpfs)
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

    # Pass 2: stream-decode straight to the staging file (XZ stream CRC64 is
    # also verified by xzmini/liblzma); no compressed copy kept in tmpfs.
    if ! "$NB_DL_CLIENT" -fsS --connect-timeout "$NB_DL_CONNECT_TIMEOUT" \
         --max-time "$NB_DL_MAX_TIME" --cacert "$NB_DL_CACERT" \
         "$NB_PAYLOAD_URL" 2>>"$NB_LOG" | /sbin/xzmini > "$NB_BIN_NEW" 2>>"$NB_LOG"; then
        rm -f "$NB_BIN_NEW"
        echo "netbird: decode failed" >&2
        return "$NB_ST_INVALID"
    fi

    # validate the decoded ELF before making it executable
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

# nb_state_name <code>  -> human-readable state name for a NB_ST_* code
nb_state_name() {
    case "$1" in
        0) echo "READY" ;;
        1) echo "PAYLOAD_NOT_DOWNLOADED" ;;
        2) echo "PAYLOAD_DOWNLOAD_FAILED" ;;
        3) echo "PAYLOAD_INVALID" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# ---------------------------------------------------------------------------
# flag building
# ---------------------------------------------------------------------------

# nb_mgmt_url -> management url from settings (or default)
nb_mgmt_url() {
    nb_get "$NB_SETTINGS_FILE" management_url "$NB_DEFAULT_MGMT"
}

# nb_flag_bool <key> <flag> -> append --flag when key == 1
nb_flag_bool() {
    local key="$1" flag="$2"
    [ "$(nb_get "$NB_SETTINGS_FILE" "$key" "0")" = "1" ] && echo "$flag"
}

# nb_common_flags -> --config/--management-url/--log/--log-level
nb_common_flags() {
    local mgmt
    mgmt=$(nb_mgmt_url)
    printf '%s' "--config $NB_CONFIG_FILE --management-url $mgmt --daemon-addr unix://$NB_SOCK --log-file $NB_LOG --log-level info"
}

# nb_up_flags -> flags for `netbird up` (disable-* options from settings)
nb_up_flags() {
    local f=""
    f="$f $(nb_flag_bool disable_dns --disable-dns)"
    f="$f $(nb_flag_bool disable_firewall --disable-firewall)"
    f="$f $(nb_flag_bool disable_client_routes --disable-client-routes)"
    f="$f $(nb_flag_bool disable_server_routes --disable-server-routes)"
    f="$f $(nb_flag_bool disable_ipv6 --disable-ipv6)"
    if [ "$(nb_get "$NB_SETTINGS_FILE" network_monitor "0")" = "1" ]; then
        f="$f --network-monitor=true"
    else
        f="$f --network-monitor=false"
    fi
    echo "$f"
}

# ---------------------------------------------------------------------------
# daemon / service lifecycle
# ---------------------------------------------------------------------------

nb_is_running() {
    [ -S "$NB_SOCK" ] && /sbin/netbird-ctl daemon-ping >/dev/null 2>&1
}

# nb_daemon_start -> start the foreground daemon via start-stop-daemon
nb_daemon_start() {
    nb_materialize || return $?
    nb_ensure_settings
    mkdir -p /var/run
    local hostname
    hostname=$(nb_get "$NB_SETTINGS_FILE" hostname "")
    local args
    args="service run --config $NB_CONFIG_FILE --management-url $(nb_mgmt_url) --daemon-addr unix://$NB_SOCK --log-file $NB_LOG --log-level info"
    [ -n "$hostname" ] && args="$args --hostname $hostname"
    export NB_STATE_DIR NB_LOG_MAX_SIZE_MB=2
    SERVICE_PID_FILE="$NB_PID" SERVICE_DAEMONIZE=1 SERVICE_WRITE_PID=1 \
        service_start "$NB_BIN" $args
}

# nb_daemon_stop -> stop the foreground daemon
nb_daemon_stop() {
    [ -S "$NB_SOCK" ] && "$NB_BIN" down --daemon-addr "unix://$NB_SOCK" >/dev/null 2>&1
    SERVICE_PID_FILE="$NB_PID" service_stop "$NB_BIN"
    rm -f "$NB_PID" "$NB_SOCK"
}

# nb_start -> connect (enable). starts daemon if needed.
nb_start() {
    local enable
    enable=$(nb_get "$NB_SETTINGS_FILE" enable "0")
    nb_ensure_settings
    nb_materialize 1 || return $?
    nb_is_running || nb_daemon_start || return 1
    if [ "$enable" = "1" ]; then
        /sbin/netbird-ctl up || return 1
    fi
    return 0
}

# nb_stop -> disconnect + stop daemon
nb_stop() {
    [ -S "$NB_SOCK" ] && /sbin/netbird-ctl down >/dev/null 2>&1
    nb_daemon_stop
}

# nb_enroll <key-file> -> enroll with a setup key (file contains the secret)
nb_enroll() {
    local keyfile="$1"
    [ -f "$keyfile" ] || { echo "netbird: setup key file missing" >&2; return 1; }
    nb_ensure_settings
    nb_materialize 1 || return $?
    nb_is_running || nb_daemon_start || return 1
    # register + connect using the key file (secret never enters argv)
    /sbin/netbird-ctl up --setup-key-file "$keyfile" \
        --management-url "$(nb_mgmt_url)" $(nb_up_flags)
}

# nb_clean -> full re-enroll / delete: stop, wipe identity+state, keep settings
nb_clean() {
    nb_stop
    rm -f "$NB_CONFIG_FILE"
    rm -rf "$NB_STATE_DIR"
    nb_ensure_settings
    nb_set "$NB_SETTINGS_FILE" enrolled 0
}

# ---------------------------------------------------------------------------
# firewall
# ---------------------------------------------------------------------------

nb_fw_access() {
    local port access
    port=$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")
    if [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ]; then
        access="lan"
    else
        access="home"
    fi
    fw netbird_access "$port" "$access" 2>/dev/null || true
}

nb_fw_block() {
    local port access
    port=$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")
    if [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ]; then
        access="lan"
    else
        access="home"
    fi
    fw netbird_block "$port" "$access" 2>/dev/null || true
}
