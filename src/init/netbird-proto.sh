#!/bin/sh
# NetBird protocol handler for TP-Link AX53 netifd.
#
# netifd is the normal lifecycle owner. The handler calls the shared NetBird
# runtime library directly; /sbin/netbird-ctl is only a manual/diagnostic CLI
# facade and is not part of protocol setup/teardown.

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

. /lib/netbird/netbird.sh
. /lib/netbird/netbird-runtime.sh

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

    # netbird is accepted only as a migration alias for profiles produced by the
    # earlier hybrid implementation. New native profiles are always netbirdvpn.
    case "$vpntype" in
        netbirdvpn|netbird) ;;
        *)
            echo "netbird: unexpected vpntype=$vpntype" >/dev/console
            proto_setup_failed "$config"
            return 1
            ;;
    esac

    if ! nb_runtime_connect >/dev/null 2>&1; then
        echo "netbird: runtime start failed" >/dev/console
        proto_notify_error "$config" START_FAILED
        proto_setup_failed "$config"
        return 1
    fi

    while [ "$tries" -gt 0 ]; do
        if nb_runtime_is_connected; then
            netbird_publish_up "$config"
            echo "netbird: netifd setup connected on $NB_IFNAME" >/dev/console
            return 0
        fi
        tries=$((tries - 1))
        sleep 1
    done

    echo "netbird: connection timeout" >/dev/console
    nb_runtime_stop >/dev/null 2>&1 || true
    proto_notify_error "$config" CONNECT_TIMEOUT
    proto_setup_failed "$config"
    return 1
}

proto_netbird_teardown() {
    local config="$1"
    echo "netbird: netifd teardown start ($config)" >/dev/console
    nb_runtime_stop >/dev/null 2>&1 || true
    netbird_publish_down "$config"
    echo "netbird: netifd teardown complete" >/dev/console
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol netbird
}
