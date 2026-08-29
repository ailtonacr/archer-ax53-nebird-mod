#!/bin/sh
# Native NetBird runtime lifecycle helpers for TP-Link Archer AX53.
#
# This file is sourced after /lib/netbird/netbird.sh. It deliberately overrides
# the historical lifecycle helpers that called back into /sbin/netbird-ctl.
# The dependency direction is now one-way:
#
#   vpnc/netifd -> netbird.sh + netbird-runtime.sh -> NetBird binary
#   netbird-ctl -> netbird.sh + netbird-runtime.sh -> NetBird binary
#
# netbird-ctl is therefore only a CLI facade; it is never an implementation
# dependency of the shared runtime library or the netifd protocol handler.

NB_IFNAME="${NB_IFNAME:-wt0}"

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

nb_daemon_ping() {
    [ -S "$NB_SOCK" ] || return 1
    nb_payload_status
    [ $? -eq "$NB_ST_READY" ] || return 1
    "$NB_BIN" status -j --daemon-addr "unix://$NB_SOCK" >/dev/null 2>&1
}

# Override the legacy implementation in netbird.sh. No controller dependency.
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

# A netifd link is UP only when all three facts are simultaneously true:
#   1. the wt0 device exists;
#   2. NetBird reports daemonStatus=Connected;
#   3. management.connected=true inside the management object itself.
# Do not accept an unrelated signal.connected=true as proof of management.
nb_runtime_is_connected() {
    [ -d "/sys/class/net/$NB_IFNAME" ] || return 1
    [ -S "$NB_SOCK" ] || return 1

    local status compact management
    status="$(nb_status_json 2>/dev/null)" || return 1
    compact="$(printf '%s' "$status" | tr -d '\r\n\t ')"

    printf '%s' "$compact" | grep -q '"daemonStatus":"Connected"' || return 1
    management="$(printf '%s' "$compact" | sed -n 's/.*"management":{\([^}]*\)}.*/\1/p')"
    [ -n "$management" ] || return 1
    printf '%s' "$management" | grep -q '"connected":true' || return 1
    return 0
}

nb_fw_priority_values() {
    NB_FW_CIDR="$(nb_get "$NB_SETTINGS_FILE" advertise_cidr "")"
    NB_FW_HOMEIF="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
    [ -n "$NB_FW_HOMEIF" ] || NB_FW_HOMEIF="br-lan"
}

nb_fw_clear_priority() {
    nb_fw_priority_values
    [ -n "$NB_FW_CIDR" ] || return 0
    while iptables -D FORWARD -i "$NB_IFNAME" -o "$NB_FW_HOMEIF" -d "$NB_FW_CIDR" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$NB_FW_HOMEIF" -o "$NB_IFNAME" -s "$NB_FW_CIDR" -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -i "$NB_FW_HOMEIF" -o "$NB_IFNAME" -s "$NB_FW_CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o "$NB_FW_HOMEIF" -s 100.64.0.0/10 -d "$NB_FW_CIDR" -j MASQUERADE 2>/dev/null; do :; done
}

nb_fw_prioritize_lan() {
    nb_fw_clear_priority
    [ "$(nb_get "$NB_SETTINGS_FILE" advertise_lan "0")" = "1" ] || return 0
    nb_fw_priority_values
    [ -n "$NB_FW_CIDR" ] || return 1

    iptables -I FORWARD 1 -i "$NB_IFNAME" -o "$NB_FW_HOMEIF" -d "$NB_FW_CIDR" -j ACCEPT || return 1
    iptables -I FORWARD 2 -i "$NB_FW_HOMEIF" -o "$NB_IFNAME" -s "$NB_FW_CIDR" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || return 1
    iptables -t nat -I POSTROUTING 1 -o "$NB_FW_HOMEIF" -s 100.64.0.0/10 \
        -d "$NB_FW_CIDR" -j MASQUERADE || return 1
    return 0
}

nb_runtime_remove_firewall() {
    nb_fw_clear_priority
    nb_fw_block
}

nb_runtime_apply_firewall() {
    nb_fw_access
    if ! nb_fw_prioritize_lan; then
        nb_runtime_remove_firewall
        return 1
    fi
    return 0
}

# nb_runtime_connect [setup-key-file]
# Start the daemon if needed and issue exactly one `netbird up` command. The
# optional setup key is always a file path and is never copied into logs.
nb_runtime_connect() {
    local keyfile="${1:-}" rc
    if [ -n "$keyfile" ] && [ ! -f "$keyfile" ]; then
        echo "netbird: setup key file missing" >&2
        return 1
    fi

    nb_ensure_settings
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
        nb_runtime_apply_firewall || return 1
    else
        nb_runtime_remove_firewall
    fi
    return "$rc"
}

# Disconnect must never download/materialize a missing payload. If no daemon is
# present there is simply nothing to disconnect; firewall cleanup still runs.
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

# Compatibility names used by older local callers. They now resolve directly
# to the shared runtime and cannot recurse through netbird-ctl.
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
    nb_ensure_settings
    nb_set "$NB_SETTINGS_FILE" enrolled 0
    nb_set "$NB_SETTINGS_FILE" enable 0
}
