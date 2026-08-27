#!/bin/sh
[ -x /usr/sbin/openvpn ] || exit 0

FW_LIBDIR=${FW_LIBDIR:-/lib/firewall}
. $FW_LIBDIR/fw.sh
. $FW_LIBDIR/tpcmd.sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /lib/functions/service.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

SERVICE_DAEMONIZE=1
SERVICE_WRITE_PID=1
SERVICE_PID_FILE="/var/run/openvpn-client.pid"
authfile="/etc/openvpn/openvpn.passwd"
BLACKHOLE_METRIC=65535

proto_openvpn_init_config() {
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "connect"
	proto_config_add_string "disconnect"
	local kill_switch_support=`uci get profile.@vpn_client[0].kill_switch_support -c "/etc/profile.d"`
	if [ "$kill_switch_support" == "yes" ]; then
		proto_config_add_string "kill_switch"
	fi
	available=1
	no_device=1
}

openvpn_add_mssfix() {
	local mss_rule=$(fw list 4 m FORWARD | grep -i "zone_wan_ovpnc_MSSFIX")
	[ -z "${mss_rule}" ] && {
		fw add 4 m zone_wan_ovpnc_MSSFIX
		fw add 4 m FORWARD zone_wan_ovpnc_MSSFIX 1
	}
	fw_set_ovpnmss "tun0" "zone_wan_ovpnc_MSSFIX"
}

openvpn_delete_mssfix() {
	local mss_rule=$(fw list 4 m FORWARD | grep -i "zone_wan_ovpnc_MSSFIX")
	[ -n "${mss_rule}" ] && {
		fw del 4 m FORWARD zone_wan_ovpnc_MSSFIX
		fw del 4 m zone_wan_ovpnc_MSSFIX
	}
}

openvpn_configfile_check() {
	echo "checking configfile" > /dev/console
	local risk_characters="up .|tls-verify .|ipchange .|client-connect .|route-up .|route-pre-down .|client-disconnect .|down .|learn-address .|auth-user-pass-verify .|client-crresponse .|script-security ."

	local CONFIG_FILE="$1"

	if [ ! -f "$CONFIG_FILE" ]; then
		echo "OpenVPN: Config file not found" > /dev/console
		exit 1
	fi

	sed -E -i "/$risk_characters/d" "$CONFIG_FILE"
}

find_enabled_server() {
    local section="$1"
    local enable
    local type

    config_get enable "$section" "enable"
    config_get type "$section" "type"

    if [ "$enable" == "on" -a "$type" == "openvpn" ]; then
        config_get server_value "$section" "server"
        if [ -n "$server_value" ]; then
            server="$server_value"
            return 1
        fi
    fi
    return 0
}

proto_openvpn_setup() {
	local config="$1"
	local iface="$2"
	local parent=""
	local server_addr=""
	local server=""
	local ip=""
	local username=""
	local password=""
	local mtu=""

	config_load vpn
	config_get enabled client enabled
	config_get vpntype client vpntype
	if [ $enabled == "off" -o $vpntype == "none" ]; then
		echo "vpn client is off, exit" > /dev/console
	fi

	grep -wq "tun" /proc/modules || /sbin/insmod tun 2>&- >&-

	config_load network
	config_get parent $config parent
	config_get iface $parent ifname
	config_get username $config username
	config_get password $config password
	config_get des $config des

	config_get server "$config" "server" && vpnc_check_parent "$parent" && {
        if  [ -z "$server" ]; then
            config_load vpn
            config_foreach find_enabled_server "server"
            config_load network
            if [ -n "$server" ]; then
                uci set network.vpn.server="$server"
                uci commit
                uci_commit_flash
            fi
        fi

        for ip in $(resolveip -4 -t 10 "$server"); do
            ( proto_add_host_dependency "$config" "$ip" "$parent" )
            server_addr=1
        done
    }

    [ -n "$server_addr" ] || {
        echo "OpenVPN could not resolve server address" > /dev/console
        sleep 5
        proto_setup_failed "$config"
        exit 1
    }

	service_stop /usr/sbin/openvpn

	local count=3
	local ca_exists=`cat /etc/openvpn/$des.ovpn | grep ca`
	while [ $count -ne 0 ] && [ -z "$ca_exists" ]; do
		sleep 1
		ca_exists=`cat /etc/openvpn/$des.ovpn | grep ca`
		let "count=count - 1"
	done

	openvpn_configfile_check /etc/openvpn/$des.ovpn

	if [ "$username" != ""  -a "$password" != "" ]; then
		rm -f $authfile
		echo $username >> $authfile
		echo $password >> $authfile
#temporarily remove --route-table option, cause openvpn doesn't recognize it
		service_start /usr/sbin/openvpn --ignore-unknown-option block-outside-dns register-dns --config "/etc/openvpn/$des.ovpn" --writepid $SERVICE_PID_FILE --script-security 2 --up "/lib/netifd/openvpn-up.sh" --down "/lib/netifd/openvpn-down.sh" --auth-nocache --auth-user-pass "$authfile"
	else
		service_start /usr/sbin/openvpn --ignore-unknown-option block-outside-dns register-dns --config "/etc/openvpn/$des.ovpn" --writepid $SERVICE_PID_FILE --script-security 2 --up "/lib/netifd/openvpn-up.sh" --down "/lib/netifd/openvpn-down.sh"
	fi

	openvpn_add_mssfix
}

proto_openvpn_teardown() {
	local interface="$1"
	local openvpn_server_enabled="off"
	echo "openvpn_teardown: $@" > /dev/console

	service_stop /usr/sbin/openvpn

	openvpn_delete_mssfix

	case "$ERROR" in
		11|19)
			proto_notify_error "$interface" AUTH_FAILED
			json_get_var authfail authfail
			if [ "${authfail:-0}" -gt 0 ]; then
				proto_block_restart "$interface"
			fi
			echo "auth_failed" > /tmp/connecterror
		;;
		2)
			proto_notify_error "$interface" INVALID_OPTIONS
			proto_block_restart "$interface"
		;;
	esac
#proto_kill_command "$interface" 15

	config_load openvpn
	config_get openvpn_server_enabled "server" "enabled" "off"
	if [ $openvpn_server_enabled == "on" ]; then
		echo "openvpn server is running ,do not rmmode tun" > /dev/console
	else
		echo "rmmod openvpn tun in client" > /dev/console
		/sbin/rmmod tun 2>&- >&-
	fi

	local kill_switch_support=`uci get profile.@vpn_client[0].kill_switch_support -c "/etc/profile.d"`
	if [ "$kill_switch_support" == "yes" ]; then
		local vpn_enabled=`uci get vpn.client.enabled -q`
		if [ "$vpn_enabled" == "on" ]; then
			local kill_switch=`uci get network.vpn.kill_switch -q`
			if [ "$kill_switch" == "on" ]; then
				ip route add blackhole default table vpn metric "$BLACKHOLE_METRIC"
				ip -6 route add blackhole default table vpn metric "$BLACKHOLE_METRIC"
			fi
		fi
	fi

}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol openvpn
}

