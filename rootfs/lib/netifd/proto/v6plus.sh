#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . /lib/functions/network.sh
    . ../netifd-proto.sh
    config_load /etc/config/sysmode
    config_get mode sysmode mode "router"
    [ "$mode" = "ap" ] && exit 0
	#init_proto functions 
    init_proto "$@"
}

DHCP_PIDFILE="/var/run/udhcpc-v6plus.pid"

proto_v6plus_init_config() {
	available=1
	
	proto_config_add_int "state"
	#proto_config_add_string "rule"
	proto_config_add_int "remoteIPv6Address"
	proto_config_add_string "localIPv6Address"
	proto_config_add_int "pdIPv6Address"
	proto_config_add_string "ipaddr"

	proto_config_add_string "tunlink"
	proto_config_add_int "mtu"
	proto_config_add_int "ttl"
	proto_config_add_string "zone"
	proto_config_add_string "type"
	proto_config_add_string "encaplimit"
	
}

v6plus_fw_teardown_fun()
{
	#nat_chain_flush v6plus_output
	#fw s_del 4 f  {"-i v6plus-$gcfg -j"} v6plus_output
	#fw del 4 f  nat v6plus_output
	fw flush 4 n v6plus_output
	fw del 4 n zone_wan_nat v6plus_output "-o v6plus-wan"
	fw del 4 n v6plus_output

	fw flush 4 n v6plus_checkports
	fw del 4 n zone_lan_prerouting v6plus_checkports
	fw del 4 n v6plus_checkports
}


proto_v6plus_setup() {
	local cfg="$1"
	local iface="$2"
	local tunlink="wanv6"
	local link="v6plus-$cfg"
	local carrier
	
	local zone type 
	
	local ipaddr pdlen pd 
	export LEGACY=1
	
	echo "proto_v6plus_setup ...... " > /dev/console
	# [ -z "$zone" ] && zone="wan"
	# [ -z "$type" ] && type="map-e"
	local mtu ttl peeraddr ip6addr
	json_get_vars ttl  peeraddr ip6addr
	
	# [ -z "$zone" ] && zone="wan"
	# [ -z "$type" ] && type="map-e"
	
	mtu=65000
	tunlink=${tunlink:-wanv6}
	
	config_load /etc/config/network
	config_get carrier $cfg carrier
	case $carrier in
		[1-3])
			echo carrier is JPNE or BIGLOBE > /dev/console
			;;
		4)
			echo carrier is OCN > /dev/console
			;;
	esac
	
	proto_export "INTERFACE=$cfg"
	proto_export "IFNAME=$iface"
	
	mkdir -p /tmp/v6plus/
	# proto_send_update "$cfg"
	# shell trigger v6plus 
	echo  "####   link  $link " > /dev/console
	echo  "####   mtu $mtu " > /dev/console
	echo  "####   tunlink $tunlink " > /dev/console
	
	proto_run_command "$cfg" /usr/sbin/v6plus \
			-i "$link" \
			-m "$mtu" \
			-6 "$tunlink" \
			-f "$iface" \
			-c "$carrier" \
			"$cfg"
	
	[ -e "/proc/mape_fast_forward" ] && echo 1 0 > /proc/mape_fast_forward
}

proto_v6plus_teardown() {
	
	echo "proto_v6plus_teardown Start" > /dev/console
	
	local cfg="$1"
	local ifname="$2"
	local link="v6plus-$cfg"
	local count=0
	config_load /etc/config/dsliteV6plus
	config_get local_addr $cfg localIPv6Address
	config_get l3_device $cfg device6
	
	ubus call network.interface.hgw disconnect
	[ -f "$DHCP_PIDFILE" ] && {
		pid=$(cat "$DHCP_PIDFILE")
		time=6
		kill $pid
		while [ $time -ne 0 -a -d "/proc/$pid" ]; do
			echo killing udhcpd > /dev/console
			let "time=time - 1"
			sleep 1
		done
		[ -d "/proc/$pid" ] && {
			kill -9 $pid
			sed -i '/\./d' /tmp/resolv.conf.auto
		}
	}
	[ -n "$local_addr" ] && [ -n "$l3_device" ] && ifconfig $l3_device del "$local_addr/64"
	killall v6plus-dial.sh

	#disable v6plus hwnat
	#MT762x
	[ -x "/usr/bin/hw_nat" ] && hw_nat -W 0
	#MT7986
	[ -w "/sys/kernel/debug/hnat/mape_toggle" ] && echo '0'>/sys/kernel/debug/hnat/mape_toggle
	
	[ -e "/proc/mape_fast_forward" ] && echo 0 0 > /proc/mape_fast_forward
	
	echo "proto_v6plus_teardown Middle 1 " > /dev/console
	
	json_get_var type type
	
	echo "proto_v6plus_teardown Middle 2 " > /dev/console
	
	[ -z "$type" ] && type="map-e"
	
	proto_kill_command $cfg
	
	echo "proto_v6plus_teardown Middle 3 " > /dev/console
	
	v6plus_fw_teardown_fun 
	#rm -f /tmp/map-$cfg.rules
	rm -rf /tmp/v6plus/

	rm -rf /tmp/v6plus-fmrs-old
	/etc/init.d/parental_control restart

        while true; do
                let count+=1
                echo "[v6plus]teardown count:$count" >/dev/console
                if [ $count -gt 8 ];then
                        break
                fi
                if [ $(iptables -t nat -S |grep -c v6plus) -gt 0 ];then
                        echo "[v6plus] iptables not cleaned fully!!!---------------->" >/dev/console
                        v6plus_fw_teardown_fun
                else
                        break
                fi
                sleep 1
        done
	
	# delete v6plus config in dsliteV6plus
	uci delete dsliteV6plus.wan.localIPv6Address
	uci delete dsliteV6plus.wan.remoteIPv6Address
	uci delete dsliteV6plus.wan.pdIPv6Address
	uci delete dsliteV6plus.wan.localIPAddress
	uci delete dsliteV6plus.wan.device6
	uci delete dsliteV6plus.wan.state 
	uci delete dsliteV6plus.wan.openvpnServerPort 
	uci delete dsliteV6plus.wan.wireguardServerPort 
	uci commit
	
	echo "proto_v6plus_teardown End " > /dev/console
}





[ -n "$INCLUDE_ONLY" ] || {
	add_protocol v6plus
}
