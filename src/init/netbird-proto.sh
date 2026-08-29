#!/bin/sh
# NetBird protocol handler for TP-Link AX53 netifd.
#
# Transitional implementation:
# netifd owns the VPN interface lifecycle, while /sbin/netbird-ctl remains the
# tested adapter to the existing NetBird runtime. Once validated in hardware,
# the control helpers will move into /lib/netbird/netbird.sh directly.

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

NB_IFNAME="wt0"
NB_CONNECT_TIMEOUT=30

proto_netbird_init_config() {
    proto_config_add_string "management_url"
    proto_config_add_string "hostname"
    proto_config_add_int "wireguard_port"
    proto_config_add_string "access"

    local kill_switch_support
    kill_switch_support="$(uci get profile.@vpn_client[0].kill_switch_support -q -c /etc/profile.d)"
    if [ "$kill_switch_support" = "yes" ]; then
        proto_config_add_string "kill_switch"
    fi

    available=1
    no_device=1
}

netbird_runtime_connected() {
    [ -d "/sys/class/net/$NB_IFNAME" ] || return 1
    [ -S /tmp/netbird.sock ] || return 1

    local status
    status="$(/sbin/netbird-ctl status 2>/dev/null)" || return 1

    echo "$status" |
        grep -q '"daemonStatus"[[:space:]]*:[[:space:]]*"Connected"' ||
        return 1

    echo "$status" |
        grep -q '"management"[[:space:]]*:' ||
        return 1

    echo "$status" |
        grep -q '"connected"[[:space:]]*:[[:space:]]*true' ||
        return 1

    return 0
}

netbird_publish_up() {
    local config="$1"

    proto_init_update "$NB_IFNAME" 1 1
    proto_set_keep 1
    proto_send_update "$config"
}

netbird_publish_down() {
    local config="$1"

    proto_init_update "$NB_IFNAME" 0
    proto_send_update "$config"
}

proto_netbird_setup() {
    local config="$1"
    local enabled="off"
    local vpntype="none"
    local tries="$NB_CONNECT_TIMEOUT"

    echo "netbird: netifd setup start ($config)" >/dev/console

    config_load vpn
    config_get enabled client enabled "off"
    config_get vpntype client vpntype "none"

    if [ "$enabled" != "on" ]; then
        echo "netbird: VPN Client disabled" >/dev/console
        proto_setup_failed "$config"
        return 1
    fi

    case "$vpntype" in
        netbird|netbirdvpn)
            ;;
        *)
            echo "netbird: unexpected vpntype=$vpntype" >/dev/console
            proto_setup_failed "$config"
            return 1
            ;;
    esac

    if ! /sbin/netbird-ctl up >/dev/null 2>&1; then
        echo "netbird: runtime start failed" >/dev/console
        proto_notify_error "$config" START_FAILED
        proto_setup_failed "$config"
        return 1
    fi

    while [ "$tries" -gt 0 ]; do
        if netbird_runtime_connected; then
            netbird_publish_up "$config"
            echo "netbird: netifd setup connected on $NB_IFNAME" >/dev/console
            return 0
        fi

        tries=$((tries - 1))
        sleep 1
    done

    echo "netbird: connection timeout" >/dev/console

    /sbin/netbird-ctl stop >/dev/null 2>&1 || true

    proto_notify_error "$config" CONNECT_TIMEOUT
    proto_setup_failed "$config"
    return 1
}

proto_netbird_teardown() {
    local config="$1"

    echo "netbird: netifd teardown start ($config)" >/dev/console

    /sbin/netbird-ctl stop >/dev/null 2>&1 || true

    netbird_publish_down "$config"

    echo "netbird: netifd teardown complete" >/dev/console
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol netbird
}
