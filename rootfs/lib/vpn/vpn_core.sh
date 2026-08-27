# Copyright(c) 2012-2019 Shenzhen TP-LINK Technologies Co.Ltd.
# file     vpn.init
# brief    
# author   Zhu Haiming
# version  1.0.0
# date     8Apr19
# histry   arg 1.0.0, 8Apr19, Zhu Haiming, Create the file. 

. /lib/functions.sh
. /lib/functions/network.sh

VPN_CLIENT_MARK=262144
VPN_CLIENT_MASK=262144
VPN_CLIENT_PREF=500
BLACKHOLE_METRIC=65535
BRIDGE_NAME="br-lan"


add_vpn_client()
{
	local access="on"
	local mac
	config_get access "$1" "access"
	config_get mac "$1" "mac"
	if [ "$access" = "on" ]; then
		vpn_mgmt "client" add "$mac"
	fi
}

vpn_main() {
	local enabled="off"
	local vpntype="none"
	local ipsec="0"
	
	config_load vpn
	config_get enabled "client" "enabled"
	config_get vpntype "client" "vpntype"
	config_get ipsec "client" "ipsec"
    
	if [ "$enabled" = "off" -o "$vpntype" = "none" ]; then
		echo "vpn client if off, exit" > /dev/console
		return;
	fi
	
	#init iptables rules
	fw add 4 m prerouting_rule_vpn_client
	fw add 4 m PREROUTING prerouting_rule_vpn_client 1
	fw add 4 n prerouting_rule_vpn_client
	fw add 4 n PREROUTING prerouting_rule_vpn_client 1
	fw add 4 m output_rule_vpn_client
	fw add 4 m OUTPUT output_rule_vpn_client 1
	fw add 4 f zone_wan_vpnc_access
	fw add 4 f zone_wan zone_wan_vpnc_access 1
	
	fw add 6 m prerouting_rule_vpn_client
	fw add 6 m PREROUTING prerouting_rule_vpn_client 1
	#prepare client mark
	fw flush 4 m prerouting_rule_vpn_client
	fw flush 6 m prerouting_rule_vpn_client
	config_foreach add_vpn_client user

	#init accelskip rule
	fw vpnc_access_accel_handle $vpntype
	
	#init accelskip rule
	fw vpnc_accelskip_add $vpntype

	#save skb mark to ct, to jump hnat
	fw add 4 m "prerouting_rule_vpn_client -m mark --mark $VPN_CLIENT_MARK/$VPN_CLIENT_MASK" "CONNMARK --save-mark"
	
	local interface="vpn"
	config_load network
    #if vpn kill switch is supported
    local kill_switch_support=`uci get profile.@vpn_client[0].kill_switch_support -c "/etc/profile.d"`
    if [ "$kill_switch_support" == "yes" ]; then
        local kill_switch
        config_get kill_switch "$interface" "kill_switch"
        # if vpn kill switch is opened
        if [ "$kill_switch" == "on" ]; then
            #add ip route rules, this part is in 90-vpn initially
            ip rule add pref "$VPN_CLIENT_PREF" fwmark $VPN_CLIENT_MARK/$VPN_CLIENT_MASK iif "$BRIDGE_NAME" table vpn
            ip -6 rule add pref "$VPN_CLIENT_PREF" fwmark $VPN_CLIENT_MARK/$VPN_CLIENT_MASK iif "$BRIDGE_NAME" table vpn
            ip route add blackhole default table vpn metric "$BLACKHOLE_METRIC"
            ip -6 route add blackhole default table vpn metric "$BLACKHOLE_METRIC"
        fi
    fi

	#connect
	ubus call network.interface.vpn disconnect
	ubus call network reload
	ubus call network.interface.vpn connect

    return
}

vpn_event() {
    vpn_main "$@"
}

vpn_start() {
	vpn_main "$1"
}

vpn_del_rules() {
	ip rule del table vpn
	ip route flush table vpn
	ip route flush cache

	ip -6 rule del table vpn
	ip -6 route flush table vpn
	ip -6 route flush cache
	
	killall vpnDnsproxy
	fw del 4 m PREROUTING prerouting_rule_vpn_client
	fw del 4 m prerouting_rule_vpn_client
	fw del 4 n PREROUTING prerouting_rule_vpn_client
	fw del 4 n prerouting_rule_vpn_client
	fw del 4 m OUTPUT output_rule_vpn_client
	fw del 4 m output_rule_vpn_client
	fw del 4 f zone_wan zone_wan_vpnc_access
	fw del 4 f zone_wan_vpnc_access

        fw del 6 m PREROUTING prerouting_rule_vpn_client
	fw del 6 m prerouting_rule_vpn_client

	fw vpnc_block_accel_handle pptp
	fw vpnc_block_accel_handle l2tp
	fw vpnc_block_accel_handle wireguard

	# for brcm fcache bug: openvpn can not access the internet
	local enabled="off"
	config_load openvpn
	config_get enabled "server" "enabled"
	if [ "$enabled" = "off" ]; then
		fw vpnc_block_accel_handle openvpn
	fi

}

vpn_stop() {
	vpn_del_rules
	ubus call network.interface.vpn disconnect
	ubus call network reload
}

vpn_check_add_rules() {
	local enabled="off"
	local vpntype="none"
	local ipsec="0"
	
	config_load vpn
	config_get enabled "client" "enabled"
	config_get vpntype "client" "vpntype"
	config_get ipsec "client" "ipsec"
    
	if [ "$enabled" = "off" -o "$vpntype" = "none" ]; then
		echo "vpn client if off, exit" > /dev/console
		return;
	fi
	
	#init iptables rules
	exist=$(iptables -w -nvL -t mangle | grep prerouting_rule_vpn_client)
	if [ -z "$exist" ]; then
		echo "===========$0 suplement vpnc mark rule in mangle==========" > /dev/console
		fw add 4 m prerouting_rule_vpn_client
		fw add 4 m PREROUTING prerouting_rule_vpn_client 1

		fw add 6 m prerouting_rule_vpn_client
		fw add 6 m PREROUTING prerouting_rule_vpn_client 1

		#prepare client mark
		fw flush 4 m prerouting_rule_vpn_client
		fw flush 6 m prerouting_rule_vpn_client
		config_foreach add_vpn_client user
	fi

	if [ "$vpntype" = "pptp" -o "$vpntype" = "pptpvpn" ];then
		fw vpnc_access_accel_handle pptp
	elif [ "$vpntype" = "l2tp" -o "$vpntype" = "l2tpvpn" ];then
		fw vpnc_access_accel_handle l2tp
	elif [ "$vpntype" = "wireguard" -o "$vpntype" = "wireguardvpn" ];then
		fw vpnc_access_accel_handle wireguard add
	# for brcm fcache bug: openvpn can not access the internet
	elif [ "$vpntype" = "openvpn" ];then	
		exist=$(iptables -nvL| grep -i BLOGSKIP | grep "tun")
		if [ -z "$exist" ]; then
			fw vpnc_access_accel_handle openvpn 
		fi
	fi
}

vpn_restart() {
	vpn_del_rules
	vpn_main
}

vpn_reload() {
	vpn_restart $1
}

