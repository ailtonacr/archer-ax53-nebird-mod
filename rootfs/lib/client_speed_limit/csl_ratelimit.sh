# Copyright (C) 2014-2015 TP-link
. /lib/config/uci.sh
. /lib/client_speed_limit/csl_config.sh

ifaces="wan"
lanDev="br-lan"
[ -e /proc/ppa/ ] && {
	lanDev="ifb1"
	
	accel_handler_load
}

csl_remove_guest_mark="-m mark ! --mark 0x60/0xfff0 -m mark ! --mark 0x80/0xfff0 -m mark ! --mark 0xa0/0xfff0 -m mark ! --mark 0xc0/0xfff0"

CSL_DEBUG_TEST=1
csl_debug()
{
	[ ${CSL_DEBUG_TEST} -gt 0 ] && {
		echo "[client_speed_limit] $1"
	}
}

nqos_support=$(uci get profile.@qos_v2[0].support_qca_nss_qos -c /etc/profile.d/ -q)
nqos_fqcodel_support=$(uci get profile.@qos_v2[0].support_qca_nss_qos_fqcodel -c /etc/profile.d/ -q)

wireless_qos_support=$(uci get profile.wireless_qosmanager.support -c /etc/profile.d/ -q)

tcq_d(){
    echo "tcq $@" > /dev/console
	tcq $@
}
local nqos_csl_up_rate=
local nqos_csl_down_rate=
local nqos_csl_up_crate=
local nqos_csl_down_crate=
local max_wan_speed=

is_del_tc_root_client_speed_limit() {
	csl_debug "is_del_tc_root_client_speed_limit start"
	local used_mark=$(uci get client_speed_limit.used_mark.used_mark)
	if [ -z "${used_mark}" -o "${used_mark}" == "${used_mark_default}" ] ; then
		csl_debug "is_del_tc_root_client_speed_limit return 1" 
		return 1
	else
		csl_debug "is_del_tc_root_client_speed_limit return 0" 
		return 0
	fi
	csl_debug "is_del_tc_root_client_speed_limit end"
}

csl_tc_get_wan_ifname()
{
	local wanname
	local iface=$1
	if [ "$nqos_support" != "yes" ]; then
		wanname=$(uci get profile.@wan[0].wan_ifname -c "/etc/profile.d" -q)
		[ -z $wanname ] && wanname=$(uci get network.$iface.ifname)
	else
		wanname=$(uci get network.$iface.ifname)
		local iptv_enable=$(uci get iptv.iptv.enable)
		local iptv_mode=$(uci get iptv.iptv.mode)
		if [ "$iptv_enable" = "on" -a "$iptv_mode" = "Bridge" ]; then
			wanname=$(uci get profile.@wan[0].wan_ifname -c "/etc/profile.d" -q)
		fi
	fi
	echo $wanname
}

csl_tc_get_up_rate(){
	local up_band=
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rUpband" ]]; then
		    up_band=$((qos_rUpband))
		elif [[ "$qos_up_unit" == "mbps" ]]; then
		    up_band=$((qos_up_band*1000))
		fi
		#if qos is enabled, we use 8%*80% upband as nqos_csl_up_rate
		nqos_csl_up_rate=$((${up_band}*(100-${qos_percent})*8/1000))
		[ $nqos_csl_up_rate -lt 10240 ] && nqos_csl_up_rate=10240

		nqos_csl_up_crate=$((${qos_percent}*${up_band}/100))
	else
		up_band=${max_wan_speed}
		#if qos is disabled, we use 50% upbind as nqos_csl_up_rate
		nqos_csl_up_rate=$((up_band/2))
		nqos_csl_up_crate=$up_band
	fi
	echo "...................A$nqos_csl_up_rate B$nqos_csl_up_crate" > /dev/console
}

csl_tc_get_down_rate(){
	local down_band=
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rDownband" ]]; then
		    down_band=$((qos_rDownband))
		elif [[ "$qos_down_unit" == "mbps" ]]; then
		    down_band=$((qos_down_band*1000))
		fi
		#if qos is enabled, we use 8%*80% downband as nqos_csl_down_rate
		nqos_csl_down_rate=$((${down_band}*(100-${qos_percent})*8/1000))
		[ $nqos_csl_down_rate -lt 10240 ] && nqos_csl_down_rate=10240
		nqos_csl_down_crate=$((${qos_percent}*${down_band}/100))
	else
		down_band=${max_wan_speed}
		nqos_csl_down_rate=$(($down_band/2))
		nqos_csl_down_crate=$down_band
	fi
	echo "...................A$nqos_csl_down_rate B$nqos_csl_down_crate" > /dev/console

}

#add qdisc to leadnode qdisc which is htb-classfull
csl_tc_add_nqos_ln_qdisc()
{
	dev=$1
	parent=$2
	handle=$3
	default=$4
	if [ "$nqos_fqcodel_support" = "yes" ]; then
		limit=100
		target=100ms
		interval=10ms
		flows=1024
		quantum=1514	
		tcq_d qdisc add dev $dev parent $parent handle $handle nssfq_codel limit $limit target $target \
			interval $interval flows $flows quantum $quantum $default
	else
		limit=1000
		tcq_d qdisc add dev $dev parent $parent handle $handle nsspfifo limit $limit $default

	fi
}

csl_tc_get_nqos_burst()
{
    # Calculate the burst and cburst parameters for HTB 
    # Added by Jason Guo<guodongxian@tp-link.net>, 20140729 
    local hz=$(cat /proc/net/psched|awk -F ' ' '{print $4}')
	local rate=$1
	local crate=$2
    [ "$hz" = "3b9aca00" ] && {
        burst__calc() {
            local b=$((${1} * 1000 / 8 / 100))
            b=$((${b} + 1600))
            echo "$b"
        }
        # Uplink, unit bit
        cburst=$(burst__calc $crate)
        burst=$(burst__calc $rate)

        param__convert() {
            local p=
            [ -n "$1" -a -n "$2" ] && {
				if [ "$nqos_support" = "yes" ]; then
					p="burst ${1}b cburst ${2}b"
				else
					p="burst $1 cburst $2"
				fi
            }
            echo "$p"        
        }
        
        lo_burst=$(param__convert $burst $cburst)
		echo $lo_burst
    }
}

#major number 1101/2101, we use bit[2:7] as to distinguish every gbc qdisc/class.
csl_get_nqos_handle() {
	local major=0x$1
	local mark=$2
	local seat=

	if [ "$major" = "0x1101" ]; then
		seat=$(((0x$mark-256)/32))
	elif [ "$major" = "0x2101" ]; then
		seat=$(((0x$mark-16-256)/32))
	else
		echo "!!unknow major number in cls, check it." > /dev/console
	fi

	if [ $seat -eq 0 ]; then
		#added by 0x8000 
		if [ "$major" = "0x1101" ]; then
			major=0x9101
		else
			major=0xa101
		fi
		echo $(printf %x $major):$mark
	else
		#seat is between 1~63, we use bit[2:7] as to distinguish every csl qdisc/class.
		major=$(($major|($seat<<2)))
		echo $(printf %x $major):$mark
	fi
}

csl_get_mark() {
	#convert decimal mark to hex, for nss qos design.
	[ "$nqos_support" = "yes" ] && echo $(printf %x $1) && return
	#return decimal for linux qos.
	echo $1
}

csl_tc_add_down_rule() {
	csl_debug "csl_tc_add_down_rule start"
	if [ -z "$1" -o -z "$2" ]; then
		return 0
	fi
	local up_mark=$1
	local down_mark=`expr ${up_mark} + 16`
	local down_band=$2
	local guarantee_down_band=`expr ${down_band} / 10`
	local downlink=$(uci_get_state client_speed_limit core downlink)
	local down_low=$(uci_get_state client_speed_limit core down_low)

	if [ "$nqos_support" = "yes" ]; then
		csl_tc_get_down_rate

		local nqos_limitrate=$(expr ${nqos_csl_down_rate} / 64)
		local nqos_ceil_limitrate=$down_band
	fi

	if [ ${down_band} -eq -1 -o "${down_band}" == "-1" ]; then
		csl_debug "down speed no limit"
		return 0
	fi
	
	if [ ${guarantee_down_band} -gt 1024 ]; then
		guarantee_down_band=1024
	fi
	if [ ${guarantee_down_band} -le 0 ]; then
		guarantee_down_band=1
	fi
	if [ ${down_low} -gt 0 -a ${guarantee_down_band} -gt ${down_low} ]; then
		guarantee_down_band=${down_low}
	fi
	if [ ${downlink} -gt 0 -a ${down_band} -gt ${downlink} ]; then
		down_band=${downlink}
	fi

	guarantee_down_band="${guarantee_down_band}""kbit"
	down_band="${down_band}""kbit"
	
	if [ "$nqos_support" != "yes" ]; then
		tc class add dev $lanDev parent 2:3 classid 2:"${down_mark}" htb rate "${guarantee_down_band}" ceil "${down_band}" prio 3
		tc qdisc add dev $lanDev parent 2:"${down_mark}" handle "${down_mark}": sfq perturb 10

		tc filter add dev $lanDev parent 2:0 protocol all prio 3 handle "${down_mark}"/0xfff0 fw classid 2:"${down_mark}"
	else
		local limit=1000
		local down_burst=$(csl_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
		down_mark=$(csl_get_mark ${down_mark})
		tcq_d class add dev $lanDev parent 2:3 classid 2:"${down_mark}" nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $down_burst quantum 1500b priority 3
#		tcq_d qdisc add dev $lanDev parent 2:"${down_mark}" handle $(csl_get_nqos_handle 2101 "${down_mark}") nsspfifo limit $limit
		csl_tc_add_nqos_ln_qdisc $lanDev 2:"${down_mark}" $(csl_get_nqos_handle 2101 "${down_mark}")
	fi

	csl_debug "csl_tc_add_down_rule end"
}

csl_tc_del_down_rule() {
	csl_debug "csl_tc_del_down_rule start"
	if [ -z "$1" ]; then
		return 0
	fi
	local up_mark=$1
	local down_mark=`expr ${up_mark} + 16`
	
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:3 classid 2:"$(csl_get_mark ${down_mark})"
	else
		tc filter del dev $lanDev parent 2:0 protocol all prio 3 handle "${down_mark}"/0xfff0 fw classid 2:"${down_mark}"
		tc class del dev $lanDev parent 2:3 classid 2:"$(csl_get_mark ${down_mark})"
	fi
	
	csl_debug "csl_tc_del_down_rule end"
}

csl_tc_add_up_rule() {
	csl_debug "csl_tc_add_up_rule start"
	if [ -z "$1" -o -z "$2" ]; then
		return 0
	fi
	local up_mark=$1
	local up_band=$2
	local guarantee_up_band=`expr ${up_band} / 10`
	local uplink=$(uci_get_state client_speed_limit core uplink)
	local up_low=$(uci_get_state client_speed_limit core up_low)

	if [ "$nqos_support" = "yes" ]; then
		csl_tc_get_up_rate 

		local nqos_limitrate=$(expr ${nqos_csl_up_rate} / 64)
		local nqos_ceil_limitrate=$up_band
	fi
	
	if [ ${up_band} -eq -1 -o "${up_band}" == "-1" ]; then
		csl_debug "up speed no limit"
		return 0
	fi
	
	if [ ${guarantee_up_band} -gt 1024 ]; then
		guarantee_up_band=1024
	fi
	if [ ${guarantee_up_band} -le 0 ]; then
		guarantee_up_band=1
	fi
	if [ ${up_low} -gt 0 -a ${guarantee_up_band} -gt ${up_low} ]; then
		guarantee_up_band=${up_low}
	fi
	if [ ${uplink} -gt 0 -a ${up_band} -gt ${uplink} ]; then
		up_band=${uplink}
	fi

	guarantee_up_band="${guarantee_up_band}""kbit"
	up_band="${up_band}""kbit"

	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(csl_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		if [ "$nqos_support" != "yes" ]; then
			tc class add dev $wan_ifname parent 1:3 classid 1:"${up_mark}" htb rate "${guarantee_up_band}" ceil "${up_band}" prio 3
			tc qdisc add dev $wan_ifname parent 1:"${up_mark}" handle "${up_mark}": sfq perturb 10

			tc filter add dev $wan_ifname parent 1:0 protocol all prio 3 handle "${up_mark}"/0xfff0 fw classid 1:"${up_mark}"
		else
			local limit=1000
			local up_burst=$(csl_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
			up_mark=$(csl_get_mark ${up_mark})
			tcq_d class add dev $wan_ifname parent 1:3 classid 1:"${up_mark}" nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $up_burst quantum 1500b priority 3
#			tcq_d qdisc add dev $wan_ifname parent 1:"${up_mark}" handle $(csl_get_nqos_handle 1101 "${up_mark}") nsspfifo limit $limit
			csl_tc_add_nqos_ln_qdisc $wan_ifname 1:"${up_mark}" $(csl_get_nqos_handle 1101 "${up_mark}")
		fi
	done
	
	csl_debug "csl_tc_add_up_rule end"
}

csl_tc_del_up_rule() {
	csl_debug "csl_tc_del_up_rule start"
	if [ -z "$1" ]; then
		return 0
	fi
	local up_mark=$1
	
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(csl_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:3 classid 1:"$(csl_get_mark ${up_mark})"
		else
			tc filter del dev $wan_ifname parent 1:0 protocol all prio 3 handle "${up_mark}"/0xfff0 fw classid 1:"${up_mark}"
			tc class del dev $wan_ifname parent 1:3 classid 1:"$(csl_get_mark ${up_mark})"
		fi
	done
	csl_debug "csl_tc_del_up_rule end"
}		

csl_tc_add_parent_rule() {
	local action="add"
	if [ "$nqos_support" = "yes" ]; then
		[ "$1" = "update" ] && action="replace"
	fi
	# get qos settings info
	fw_config_append qos_v2
	csl_config_get_qos qos

	# create /var/state/
	#uci_revert_state "client_speed_limit"
	uci_toggle_state "client_speed_limit" "core" "" "client_speed_limit"

	# add tc root
	. /lib/qos/core_qos.sh
	fw_add_tc_root

	max_wan_speed=$(get_max_wan_speed)
	
	# add uplink tc
	local up_band
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rUpband" ]]; then
		    up_band=$((qos_rUpband))
		elif [[ "$qos_up_unit" == "mbps" ]]; then
		    up_band=$((qos_up_band*1000))
		fi
	else
		up_band=${max_wan_speed}
	fi
	local uplink=$((${qos_percent}*${up_band}/100))
	local up_low=$((${qos_low}*${uplink}/100))
	if [ ${uplink} -le 0 ]; then
		uplink=1
	fi
	if [ ${up_low} -le 0 ]; then
		up_low=1
	fi

	# set state
	uci_toggle_state "client_speed_limit" "core" "uplink" "${uplink}"
	uci_toggle_state "client_speed_limit" "core" "up_low" "${up_low}"
	
	uplink="${uplink}""kbit"
	up_low="${up_low}""kbit"


	
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(csl_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		csl_debug "csl_tc_add_parent_rule uplink up_low:${up_low}, uplink:${uplink}"
		if [ "$nqos_support" != "yes" ]; then
			tc class add dev $wan_ifname parent 1:1 classid 1:3 htb rate ${up_low} ceil ${uplink} prio 3
		else
			csl_tc_get_up_rate
			local up_burst=$(csl_tc_get_nqos_burst $nqos_csl_up_rate $nqos_csl_up_crate)
			tcq_d class $action dev $wan_ifname parent 1:1 classid 1:3 nsshtb rate "$nqos_csl_up_rate""kbit" crate "$nqos_csl_up_crate""kbit" $up_burst quantum 1500b priority 3
		fi
	done

	# add downlink tc
	local down_band
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rDownband" ]]; then
		    down_band=$((qos_rDownband))
		elif [[ "$qos_down_unit" == "mbps" ]]; then
		    down_band=$((qos_down_band*1000))
		fi
	else
		down_band=${max_wan_speed}
	fi
	local downlink=$((${qos_percent}*${down_band}/100))
	local down_low=$((${qos_low}*${downlink}/100))
	if [ ${downlink} -le 0 ]; then
		downlink=1
	fi
	if [ ${down_low} -le 0 ]; then
		down_low=1
	fi

	# set state
	uci_toggle_state "client_speed_limit" "core" "downlink" "${downlink}"
	uci_toggle_state "client_speed_limit" "core" "down_low" "${down_low}"
	
	downlink="${downlink}""kbit"
	down_low="${down_low}""kbit"
	
	csl_debug "csl_tc_add_parent_rule downlink down_low:${down_low}, downlink:${downlink}"
	if [ "$nqos_support" != "yes" ]; then
		tc class add dev $lanDev parent 2:1 classid 2:3 htb rate ${down_low} ceil ${downlink} prio 3
	else
		csl_tc_get_down_rate
		local down_burst=$(csl_tc_get_nqos_burst $nqos_csl_down_rate $nqos_csl_down_crate)
		tcq_d class $action dev $lanDev parent 2:1 classid 2:3 nsshtb rate "$nqos_csl_down_rate""kbit" crate "$nqos_csl_down_crate""kbit" $down_burst quantum 1500b priority 3
	fi
}

csl_tc_del_parent_rule() {
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(csl_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:1 classid 1:3
		else
			tc class del dev $wan_ifname parent 1:1 classid 1:3
		fi
	done
	
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:1 classid 2:3
	else
		tc class del dev $lanDev parent 2:1 classid 2:3
	fi
	
	# del tc root
	. /lib/qos/core_qos.sh
	fw_del_tc_root

	# revert state
	#uci_revert_state "client_speed_limit"
}

csl_fw_add_rule() {
	csl_debug "csl_fw_add_rule start"
	if [ -z "$1" -o -z "$2" ]; then
		return 0
	fi
	local client_mac=$1
	local mac=${client_mac//-/}
	mac=$(echo ${mac} | tr [a-z] [A-Z])

	client_mac=${client_mac//-/:}
	client_mac=$(echo ${client_mac} | tr [a-z] [A-Z])
	csl_debug "client_mac=${client_mac} mac=${mac}"
	
	local up_mark=$2
	local down_mark=`expr ${up_mark} + 16`

	# add lan fw rules,��������
	local mac_limit="lan_limit_""${mac}"
	local client_lan_rule="lan_rule_""${mac}"
	
	local mac_rule=$(fw list 4 m | grep "${mac}")
	[ -z "${mac_rule}" ] && {
		# set mark
		fw add 4 m ${client_lan_rule}
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# set tc flags
			iptables -t mangle -I ${client_lan_rule} -j BLOGTG --set-tcflag 1
		}
		#QCA, nss qos need classify netfilter target.
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				[ ! -d /sys/module/xt_CLASSIFYMASK ] && insmod /lib/modules/iplatform/xt_CLASSIFYMASK.ko
			else
				[ ! -d /sys/module/xt_CLASSIFY ] && insmod /lib/modules/$(uname -r)/xt_CLASSIFY.ko
			fi
		fi

		fw add 4 m ${client_lan_rule} "MARK --set-xmark ${up_mark}/0xfff0"
		fw add 4 m ${client_lan_rule} "CONNMARK --set-xmark ${up_mark}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m ${client_lan_rule} "CLASSIFYMASK --set-class $(csl_get_nqos_handle 1101 $(printf %x ${up_mark}))/0xfffffff0"
			else
				fw add 4 m ${client_lan_rule} "CLASSIFY --set-class $(csl_get_nqos_handle 1101 $(printf %x ${up_mark}))"
			fi
		fi
		fw add 4 m ${client_lan_rule} ACCEPT
		fw add 4 m client_speed_limit_lan_rule ${client_lan_rule} { "-m connmark --mark ${up_mark}/0xfff0" }
		# match mac
		fw add 4 m ${mac_limit}
		fw add 4 m client_speed_limit_lan_rule ${mac_limit}
		fw add 4 m ${mac_limit} ${client_lan_rule} { "-m mac --mac-source ${client_mac} ${csl_remove_guest_mark}" }

		# add wan fw rules,��������
		local client_wan_rule="wan_rule_""${mac}"
		fw add 4 m ${client_wan_rule}
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# set tc flags
			iptables -t mangle -I ${client_wan_rule} -j BLOGTG --set-tcflag 1
		}
		fw add 4 m ${client_wan_rule} "MARK --set-xmark ${down_mark}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m ${client_wan_rule} "CLASSIFYMASK --set-class $(csl_get_nqos_handle 2101 $(printf %x ${down_mark}))/0xfffffff0"
			else
				fw add 4 m ${client_wan_rule} "CLASSIFY --set-class $(csl_get_nqos_handle 2101 $(printf %x ${down_mark}))"
			fi
		fi
		fw add 4 m ${client_wan_rule} ACCEPT
		fw add 4 m client_speed_limit_wan_rule ${client_wan_rule} { "-m connmark --mark ${up_mark}/0xfff0" }

		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# clear acceleration entry
			fc flush --mac "${client_mac}"
		}
		
		# RTK
		[ -e /proc/fc/ctrl/skip_ct ] && {
			echo "add:0x$(printf %x ${up_mark}) 0xfff0" > /proc/fc/ctrl/skip_ct
		}
	}
	csl_debug "csl_fw_add_rule end"
}

csl_fw_del_rule() {
	csl_debug "csl_fw_del_rule start"
	if [ -z "$1" -o -z "$2" ]; then
		return 0
	fi

	local client_mac=$1
	local mac=${client_mac//-/}
	mac=$(echo ${mac} | tr [a-z] [A-Z])

	client_mac=${client_mac//-/:}
	client_mac=$(echo ${client_mac} | tr [a-z] [A-Z])
	csl_debug "client_mac=${client_mac} mac=${mac}"
	
	local up_mark=$2
	local down_mark=`expr ${up_mark} + 16`

	local mac_limit="lan_limit_""${mac}"
	local client_lan_rule="lan_rule_""${mac}"
	local client_wan_rule="wan_rule_""${mac}"
	
	local mac_rule=$(fw list 4 m | grep "${mac}")
	[ -n "${mac_rule}" ] && {
		fw flush 4 m ${client_lan_rule}
		fw flush 4 m ${mac_limit}
		fw del 4 m client_speed_limit_lan_rule ${client_lan_rule} { "-m connmark --mark ${up_mark}/0xfff0" }
		fw del 4 m client_speed_limit_lan_rule ${mac_limit}
		fw del 4 m ${client_lan_rule}
		fw del 4 m ${mac_limit}
		
		fw flush 4 m ${client_wan_rule}
		fw del 4 m client_speed_limit_wan_rule ${client_wan_rule} { "-m connmark --mark ${up_mark}/0xfff0" }
		fw del 4 m ${client_wan_rule}

		# RTK8198
		[ -e /proc/fc/ctrl/skip_ct ] && {
			echo "del:0x$(printf %x ${up_mark}) 0xfff0" > /proc/fc/ctrl/skip_ct
		}
	}
	csl_debug "csl_fw_del_rule end"
}

csl_fw_add_parent_rule() {
	# add lan fw rules,��������
	local lan_rule=$(fw list 4 m | grep "client_speed_limit_lan_rule")
	[ -z "${lan_rule}" ] && {
		fw add 4 m client_speed_limit_lan_rule
		fw add 4 m zone_lan_qos client_speed_limit_lan_rule 1
	}
	
	# add wan fw rules,��������
	local wan_rule=$(fw list 4 m | grep "client_speed_limit_wan_rule")
	[ -z "${wan_rule}" ] && {
		fw add 4 m client_speed_limit_wan_rule
		fw add 4 m zone_wan_qos client_speed_limit_wan_rule 1
	}
}
csl_fw_del_parent_rule() {
	is_del_tc_root_client_speed_limit
	if [ $? == 1 ] ; then
		fw flush 4 m client_speed_limit_lan_rule
		fw del 4 m zone_lan_qos client_speed_limit_lan_rule 
		fw del 4 m client_speed_limit_lan_rule

		fw flush 4 m client_speed_limit_wan_rule
		fw del 4 m zone_wan_qos client_speed_limit_wan_rule
		fw del 4 m client_speed_limit_wan_rule

		# MTK
		[ -e /proc/fc/ctrl/skip_ct ] && {
			echo "clear:0" > /proc/fc/ctrl/skip_ct
		}
	fi
}
