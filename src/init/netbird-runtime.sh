#!/bin/sh
# Native NetBird runtime lifecycle helpers for TP-Link Archer AX53.
#
# This file is sourced after /lib/netbird/netbird.sh. The dependency direction
# is one-way:
#
#   vpnc/netifd -> netbird.sh + netbird-runtime.sh -> NetBird binary
#   netbird-ctl -> netbird.sh + netbird-runtime.sh -> NetBird binary
#
# netbird-ctl is therefore only a CLI facade; it is never an implementation
# dependency of the shared runtime library or the netifd protocol handler.

NB_IFNAME="${NB_IFNAME:-wt0}"
NB_FW_STATE="/tmp/netbird-firewall.state"
NB_FW_STATE_NEW="/tmp/netbird-firewall.state.new"

nb_bool_arg() {
    local key="$1" flag="$2" def="${3:-0}" value
    value="$(nb_get "$NB_SETTINGS_FILE" "$key" "$def")"
    if [ "$value" = "1" ]; then
        printf '%s\n' "${flag}=true"
    else
        printf '%s\n' "${flag}=false"
    fi
}

# Canonical flags for every `netbird up` invocation. There must be exactly one
# builder so enrollment and ordinary connection cannot drift or duplicate flags.
nb_up_flags() {
    local wg_port
    wg_port="$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")"
    printf '%s ' \
        "$(nb_bool_arg disable_dns --disable-dns 1)" \
        "$(nb_bool_arg disable_firewall --disable-firewall 1)" \
        "$(nb_bool_arg disable_client_routes --disable-client-routes 1)" \
        "$(nb_bool_arg disable_server_routes --disable-server-routes 1)" \
        "$(nb_bool_arg disable_ipv6 --disable-ipv6 1)" \
        "$(nb_bool_arg network_monitor --network-monitor 0)" \
        "--wireguard-port=${wg_port}"
}

nb_runtime_validate_settings() {
    if [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ] && \
       [ "$(nb_get "$NB_SETTINGS_FILE" disable_server_routes "1")" != "0" ]; then
        echo "netbird: LAN routing requires server routes to be enabled" >&2
        return 1
    fi
    return 0
}

nb_daemon_ping() {
    [ -S "$NB_SOCK" ] || return 1
    nb_payload_status
    [ $? -eq "$NB_ST_READY" ] || return 1
    "$NB_BIN" status -j --daemon-addr "unix://$NB_SOCK" >/dev/null 2>&1
}

nb_is_running() {
    nb_daemon_ping
}

nb_status_json() {
    nb_payload_status
    local payload_rc=$?
    if [ "$payload_rc" -eq "$NB_ST_READY" ] && [ -S "$NB_SOCK" ]; then
        "$NB_BIN" status -j --daemon-addr "unix://$NB_SOCK" 2>/dev/null && return 0
        printf '%s\n' '{"daemonStatus":"Stopped","cliVersion":"","daemonVersion":"","management":{"url":"","connected":false,"error":"failed to query daemon"},"signal":{"url":"","connected":false},"peers":{"total":0,"connected":0},"netbirdIp":"","publicKey":"","fqdn":""}'
        return 1
    fi
    printf '%s\n' '{"daemonStatus":"Stopped","cliVersion":"","daemonVersion":"","management":{"url":"","connected":false,"error":"daemon not running"},"signal":{"url":"","connected":false},"peers":{"total":0,"connected":0},"netbirdIp":"","publicKey":"","fqdn":""}'
    return 1
}

# Pure status parser, kept separate from wt0/socket checks so its semantics can
# be unit-tested offline. It intentionally ignores signal.connected.
nb_status_json_is_connected() {
    local status="$1" compact management
    compact="$(printf '%s' "$status" | tr -d '\r\n\t ')"
    printf '%s' "$compact" | grep -q '"daemonStatus":"Connected"' || return 1
    management="$(printf '%s' "$compact" | sed -n 's/.*"management":{\([^}]*\)}.*/\1/p')"
    [ -n "$management" ] || return 1
    printf '%s' "$management" | grep -q '"connected":true' || return 1
    return 0
}

# A netifd link is UP only when all three facts are simultaneously true:
#   1. the wt0 device exists;
#   2. NetBird reports daemonStatus=Connected;
#   3. management.connected=true inside the management object itself.
nb_runtime_is_connected() {
    [ -d "/sys/class/net/$NB_IFNAME" ] || return 1
    [ -S "$NB_SOCK" ] || return 1
    local status
    status="$(nb_status_json 2>/dev/null)" || return 1
    nb_status_json_is_connected "$status"
}

nb_fw_current_values() {
    NB_FW_PORT="$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")"
    NB_FW_CIDR="$(nb_get "$NB_SETTINGS_FILE" advertise_cidr "")"
    NB_FW_HOMEIF="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
    [ -n "$NB_FW_HOMEIF" ] || NB_FW_HOMEIF="br-lan"
    if [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ]; then
        NB_FW_ACCESS="lan"
    else
        NB_FW_ACCESS="home"
    fi
}

nb_fw_write_state() {
    umask 077
    cat > "$NB_FW_STATE_NEW" <<EOF
port=$NB_FW_PORT
access=$NB_FW_ACCESS
cidr=$NB_FW_CIDR
homeif=$NB_FW_HOMEIF
EOF
    chmod 0600 "$NB_FW_STATE_NEW" && mv -f "$NB_FW_STATE_NEW" "$NB_FW_STATE"
}

nb_fw_read_state() {
    [ -f "$NB_FW_STATE" ] || return 1
    NB_FW_PORT="$(nb_get "$NB_FW_STATE" port "")"
    NB_FW_ACCESS="$(nb_get "$NB_FW_STATE" access "home")"
    NB_FW_CIDR="$(nb_get "$NB_FW_STATE" cidr "")"
    NB_FW_HOMEIF="$(nb_get "$NB_FW_STATE" homeif "")"
    [ -n "$NB_FW_PORT" ] && [ -n "$NB_FW_HOMEIF" ] || return 1
    return 0
}

nb_fw_clear_priority_values() {
    local cidr="$1" homeif="$2"
    [ -n "$cidr" ] || return 0
    while iptables -D FORWARD -i "$NB_IFNAME" -o "$homeif" -d "$cidr" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$homeif" -o "$NB_IFNAME" -s "$cidr" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$homeif" -o "$NB_IFNAME" -s "$cidr" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o "$homeif" -s 100.64.0.0/10 -d "$cidr" -j MASQUERADE 2>/dev/null; do :; done
}

nb_fw_prioritize_lan_values() {
    local access="$1" cidr="$2" homeif="$3"
    nb_fw_clear_priority_values "$cidr" "$homeif"
    [ "$access" = "lan" ] || return 0
    [ -n "$cidr" ] || return 1

    iptables -I FORWARD 1 -i "$NB_IFNAME" -o "$homeif" -d "$cidr" -j ACCEPT || return 1
    iptables -I FORWARD 2 -i "$homeif" -o "$NB_IFNAME" -s "$cidr" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
    iptables -t nat -I POSTROUTING 1 -o "$homeif" -s 100.64.0.0/10 \
        -d "$cidr" -j MASQUERADE || return 1
    return 0
}

nb_runtime_remove_firewall() {
    if nb_fw_read_state; then
        nb_fw_clear_priority_values "$NB_FW_CIDR" "$NB_FW_HOMEIF"
        nb_fw_block "$NB_FW_PORT" "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"
        rm -f "$NB_FW_STATE" "$NB_FW_STATE_NEW"
        return 0
    fi

    # Upgrade/recovery fallback when no applied-state snapshot exists yet.
    nb_fw_current_values
    nb_fw_clear_priority_values "$NB_FW_CIDR" "$NB_FW_HOMEIF"
    nb_fw_block "$NB_FW_PORT" "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"
    rm -f "$NB_FW_STATE" "$NB_FW_STATE_NEW"
}

nb_runtime_apply_firewall() {
    # Remove the exact previously-applied rules before installing the current
    # settings. This makes CIDR/port changes A->B deterministic and fail closed.
    nb_runtime_remove_firewall
    nb_fw_current_values
    if ! nb_fw_access "$NB_FW_PORT" "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"; then
        nb_fw_block "$NB_FW_PORT" "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"
        return 1
    fi
    if ! nb_fw_write_state; then
        nb_fw_block "$NB_FW_PORT" "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"
        return 1
    fi
    if ! nb_fw_prioritize_lan_values "$NB_FW_ACCESS" "$NB_FW_CIDR" "$NB_FW_HOMEIF"; then
        nb_runtime_remove_firewall
        return 1
    fi
    return 0
}

nb_runtime_connect() {
    local keyfile="${1:-}" rc
    if [ -n "$keyfile" ] && [ ! -f "$keyfile" ]; then
        echo "netbird: setup key file missing" >&2
        return 1
    fi

    nb_ensure_settings
    nb_runtime_validate_settings || return 1
    nb_materialize 1 >/dev/null 2>&1 || return $?
    nb_is_running || nb_daemon_start || return 1

    if [ -n "$keyfile" ]; then
        "$NB_BIN" up --daemon-addr "unix://$NB_SOCK" \
            --management-url "$(nb_mgmt_url)" $(nb_up_flags) \
            --setup-key-file "$keyfile"
    else
        "$NB_BIN" up --daemon-addr "unix://$NB_SOCK" \
            --management-url "$(nb_mgmt_url)" $(nb_up_flags)
    fi
    rc=$?

    if [ "$rc" -eq 0 ]; then
        if ! nb_runtime_apply_firewall; then
            nb_runtime_stop >/dev/null 2>&1 || true
            return 1
        fi
    else
        nb_runtime_remove_firewall
    fi
    return "$rc"
}

nb_runtime_disconnect() {
    local rc=0
    if [ -S "$NB_SOCK" ] && [ -x "$NB_BIN" ]; then
        "$NB_BIN" down --daemon-addr "unix://$NB_SOCK" >/dev/null 2>&1 || rc=$?
    fi
    nb_runtime_remove_firewall
    return "$rc"
}

nb_runtime_stop() {
    nb_runtime_disconnect >/dev/null 2>&1 || true
    nb_daemon_stop
    return 0
}

nb_runtime_restart() {
    nb_runtime_stop
    nb_runtime_connect
}

nb_start() {
    nb_ensure_settings
    [ "$(nb_get "$NB_SETTINGS_FILE" enable "0")" = "1" ] || return 0
    nb_runtime_connect
}

nb_stop() {
    nb_runtime_stop
}

nb_enroll() {
    local keyfile="$1"
    [ -f "$keyfile" ] || { echo "netbird: setup key file missing" >&2; return 1; }
    nb_runtime_connect "$keyfile"
}

nb_clean() {
    nb_runtime_stop
    rm -f "$NB_CONFIG_FILE"
    rm -rf "$NB_STATE_DIR"
    # Do not call nb_ensure_settings() here: profile deletion must not recreate
    # state/ after it has just been removed. Reset metadata only when settings
    # still exist; the auxiliary controller removes that file after stock CRUD.
    if [ -f "$NB_SETTINGS_FILE" ]; then
        nb_set "$NB_SETTINGS_FILE" enrolled 0
        nb_set "$NB_SETTINGS_FILE" enable 0
    fi
    return 0
}
