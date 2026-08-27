#!/bin/sh

. /lib/functions/network.sh
. /usr/share/libubox/jshn.sh

local wan_dial_status
local ip_list lan_addr lan_mask wan_addr dns_addr

network_get_ipaddr lan_addr lan
network_get_subnet lan_mask lan
lan_mask="${lan_mask#*/}"

# wait for the default dial success/fail
for i in $(seq 10); do
    sleep 3
    json_init
    json_load "$(ubus call network.interface.wan status)"
    json_get_var wan_dial_status state
    if [ "$wan_dial_status" = "connected" ]; then
        network_get_ipaddr wan_addr wan
        network_get_dnsserver dns_addr wan

        for ip in $wan_addr $dns_addr; do
            if [ -n "$ip_list" ] ; then
                ip_list="$ip"",""$ip_list"
            else
                ip_list="$ip"
            fi
        done

        # lan conflict, netifd will restart later
        [ "$(lua /lib/domain_login/domain_login_tools.lua checklist $lan_addr $ip_list $lan_mask)" = "true" ] && exit 0

        sleep 10 # wait for the online-test result
        break
    fi
done

echo autodial begin !!!! > /dev/console
lua /lib/autodial/auto_dial.lua auto_dial
