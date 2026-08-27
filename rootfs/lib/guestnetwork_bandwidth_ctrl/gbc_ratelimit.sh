# Copyright (C) 2014-2015 TP-link
. /lib/config/uci.sh
. /lib/guestnetwork_bandwidth_ctrl/gbc_config.sh

support_triband=$(uci get profile.@wireless[0].support_triband -c "/etc/profile.d" -q)
support_fourband=$(uci get profile.@wireless[0].support_fourband -c "/etc/profile.d" -q)
support_6g=$(uci get profile.@wireless[0].support_6g -c "/etc/profile.d" -q)
release=$(uname -r)
nqos_support=$(uci get profile.@qos_v2[0].support_qca_nss_qos -c /etc/profile.d/ -q)
nqos_fqcodel_support=$(uci get profile.@qos_v2[0].support_qca_nss_qos_fqcodel -c /etc/profile.d/ -q)
wireless_qos_support=$(uci get profile.wireless_qosmanager.support -c /etc/profile.d/ -q)
tcq_d(){
    echo "tcq $@" > /dev/console
	tcq $@
}
local nqos_gbc_up_rate=
local nqos_gbc_down_rate=
local nqos_gbc_up_crate=
local nqos_gbc_down_crate=
local max_wan_speed=


local    up_mark_2g=$((0x0060))
local  down_mark_2g=$((0x0070))
local    up_mark_5g=$((0x0080))
local  down_mark_5g=$((0x0090))
local   up_mark_5g2=$((0x00a0))
local down_mark_5g2=$((0x00b0))
local    up_mark_6g=$((0x00c0))
local  down_mark_6g=$((0x00d0))

fw_config_append guestnetwork_bandwidth_ctrl
fw_config_append qos_v2
gbc_config_get_global global
gbc_config_get_qos qos

ifaces="wan"
lanDev="br-lan"
[ -e /proc/ppa/ ] && {
	lanDev="ifb1"
	accel_handler_load
}

GBC_DEBUG_TEST=1
gbc_debug()
{
	[ ${GBC_DEBUG_TEST} -gt 0 ] && {
		echo "[guest_bandwidth] $1"
	}
}

is_del_tc_root_guestnetwork_bandwidth() {
	gbc_debug "is_del_tc_root_guestnetwork_bandwidth start"
	
	if [ "${global_enable_2g}" == "on" -o "${global_enable_5g1}" == "on" ]; then
		gbc_debug "is_del_tc_root_guestnetwork_bandwidth return 0" 
		return 0
	fi
	if [ "${support_triband}" == "yes" -a "${support_6g}" != "yes" -o "${support_fourband}" == "yes" ]; then
		if [ "${global_enable_5g2}" == "on" ]; then
			gbc_debug "is_del_tc_root_guestnetwork_bandwidth 5g2 return 0" 
			return 0
		fi
	fi
	if [ "${support_6g}" == "yes" ]; then
		if [ "${global_enable_6g}" == "on" ]; then
			gbc_debug "is_del_tc_root_guestnetwork_bandwidth 6g return 0" 
			return 0
		fi
	fi
	
	gbc_debug "is_del_tc_root_guestnetwork_bandwidth return 1" 
	return 1

	gbc_debug "is_del_tc_root_guestnetwork_bandwidth end"
}

gbc_tc_get_wan_ifname()
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

gbc_tc_get_up_rate(){
	local up_band=
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rUpband" ]]; then
		    up_band=${qos_rUpband}
		elif [[ "$qos_up_unit" == "mbps" ]]; then
		    up_band=$((qos_up_band*1000))
		fi
		#if qos is enabled, we use 8%*20% upband as nqos_gbc_up_rate
		nqos_gbc_up_rate=$((${up_band}*(100-${qos_percent})*2/1000))
		[ $nqos_gbc_up_rate -lt 2048 ] && nqos_gbc_up_rate=2048

		nqos_gbc_up_crate=$((${qos_percent}*${up_band}/100))
	else
		up_band=${max_wan_speed}
		#if qos is disabled, we use 50% upbind as nqos_gbc_up_rate
		nqos_gbc_up_rate=$((up_band/2))
		nqos_gbc_up_crate=$up_band
	fi
	echo "...................A$nqos_gbc_up_rate B$nqos_gbc_up_crate" > /dev/console
}

gbc_tc_get_down_rate(){
	local down_band=
	if [ "${qos_enable}" == "on" ]; then
		if [[ -n "$qos_rDownband" ]]; then
		    down_band=${qos_rDownband}
		elif [[ "$qos_down_unit" == "mbps" ]]; then
		    down_band=$((qos_down_band*1000))
		fi
		#if qos is enabled, we use 8%*20% downband as nqos_gbc_down_rate
		nqos_gbc_down_rate=$((${down_band}*(100-${qos_percent})*2/1000))
		[ $nqos_gbc_down_rate -lt 2048 ] && nqos_gbc_down_rate=2048
		nqos_gbc_down_crate=$((${qos_percent}*${down_band}/100))
	else
		down_band=${max_wan_speed}
		nqos_gbc_down_rate=$(($down_band/2))
		nqos_gbc_down_crate=$down_band
	fi

	echo "...................A$nqos_gbc_down_rate B$nqos_gbc_down_crate" > /dev/console
}

#add qdisc to leadnode qdisc which is htb-classfull
gbc_tc_add_nqos_ln_qdisc()
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

#del qdisc to leadnode qdisc which is htb-classfull
gbc_tc_del_nqos_ln_qdisc()
{
	dev=$1
	parent=$2
	handle=$3
	if [ "$nqos_fqcodel_support" = "yes" ]; then
		limit=100
		target=100ms
		interval=10ms
		flows=1024
		quantum=1514	
		tcq_d qdisc del dev $dev parent $parent handle $handle nssfq_codel limit $limit target $target \
			interval $interval flows $flows quantum $quantum
	else
		limit=1000
		tcq_d qdisc del dev $dev parent $parent handle $handle nsspfifo limit $limit

	fi
}
gbc_tc_get_nqos_burst()
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

#major number 1101/2101, we use bit[9:11] as to distinguish every gbc qdisc/class.
#each band use one count between 1-7 expressed by [9:11]
gbc_get_nqos_handle(){
	major=0x$1
	
	#cause we use bit[12:13] to distinguish direction, it's unnecessary to use two count for one band 
	if [ $(($2%2)) -eq 0 ];then
		minor=$(((0x$2-6)/2<<9))
	else
		minor=$(((0x$2-6-1)/2<<9))
	fi

	if [ $minor -eq 0 ];then 
		#added by 0x4000
		if [ "$major" = "0x1101" ]; then
			major=0x5101
		elif [ "$major" = "0x2101" ]; then 
			major=0x6101
		else
			echo "!!unknow major number in cls, check it." > /dev/console
	 	fi
		echo $(printf %x $major):00"$2"0
	else
		echo $(printf %x $(($major+$minor))):00"$2"0
	fi
}

gbc_get_classid() {
	#convert decimal classid to hex, for nss qos design.
	[ "$nqos_support" = "yes" ] && echo $(printf %x $1) && return
	#return decimal for linux qos.
	echo $1
}

gbc_tc_add_down_rule() {
	gbc_debug "gbc_tc_add_down_rule start"
	local down_band=
	if [[ -n "$qos_rDownband" ]]; then
	    down_band=${qos_rDownband}
	elif [[ "$qos_down_unit" == "mbps" ]]; then
	    down_band=$((qos_down_band*1000))
	fi

	local limitrate
	local ceil_limitrate
	
	local downlink=$((${qos_percent}*${down_band}/100))
	local down_low=$((${qos_low}*${downlink}/100))
	if [ ${downlink} -le 0 ]; then
		downlink=1
	fi
	if [ ${down_low} -le 0 ]; then
		down_low=1
	fi
	
	if [ "$nqos_support" = "yes" ]; then
		gbc_tc_get_down_rate
		
		local nqos_limitrate=$(expr ${nqos_gbc_down_rate} / 4)
		local nqos_ceil_limitrate=
	fi
	# 2.4G
	if [ "${global_enable_2g}" == "on" ]; then
		# wan --> guest_ifname_2g
		ceil_limitrate=${global_down_band_2g}
		if [ "$nqos_support" = "yes" ]; then
			nqos_ceil_limitrate=${global_down_band_2g}
		fi
		limitrate=`expr ${ceil_limitrate} / 10`
		if [ "${qos_enable}" == "on" ]; then if [ ${down_low} -lt ${limitrate} ]; then
				limitrate=${down_low}
			fi
			if [ ${downlink} -lt ${ceil_limitrate} ]; then
				ceil_limitrate=${downlink}
			fi
		fi
		if [ ${limitrate} -le 0 ]; then
			limitrate=1
		fi
		limitrate="${limitrate}""kbit"
		ceil_limitrate="${ceil_limitrate}""kbit"
		
		if [ "$nqos_support" != "yes" ]; then
			gbc_debug "2.4G wan-->guest_ifname_2g limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
		else
			gbc_debug "2.4G wan-->guest_ifname_2g limitrate:${nqos_limitrate}, ceil_limitrate:${nqos_ceil_limitrate}"
		fi
		
		if [ "$nqos_support" != "yes" ]; then
			tc class add dev $lanDev parent 2:4 classid 2:${down_mark_2g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
			tc qdisc add dev $lanDev parent 2:${down_mark_2g} handle ${down_mark_2g}: sfq perturb 10

			tc filter add dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_2g}/0xfff0 fw classid 2:${down_mark_2g}
		else
			local limit=1000
			local down_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
			tcq_d class add dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_2g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $down_burst quantum 1500b priority 3
#			tcq_d qdisc add dev $lanDev parent 2:$(gbc_get_classid ${down_mark_2g}) handle $(gbc_get_nqos_handle 2101 7) nsspfifo limit $limit
			gbc_tc_add_nqos_ln_qdisc $lanDev 2:$(gbc_get_classid ${down_mark_2g}) $(gbc_get_nqos_handle 2101 7) 
		fi
	fi

	# 5G
	if [ "${global_enable_5g1}" == "on" ]; then
		# wan --> guest_ifname_5g
		ceil_limitrate=${global_down_band_5g1}
		if [ "$nqos_support" = "yes" ]; then
			nqos_ceil_limitrate=${global_down_band_5g1}
		fi
		limitrate=`expr ${ceil_limitrate} / 10`
		if [ "${qos_enable}" == "on" ]; then
			if [ ${down_low} -lt ${limitrate} ]; then
				limitrate=${down_low}
			fi
			if [ ${downlink} -lt ${ceil_limitrate} ]; then
				ceil_limitrate=${downlink}
			fi
		fi
		if [ ${limitrate} -le 0 ]; then
			limitrate=1
		fi
		limitrate="${limitrate}""kbit"
		ceil_limitrate="${ceil_limitrate}""kbit"
		
		gbc_debug "5G wan-->guest_ifname_5g limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
		
		if [ "$nqos_support" != "yes" ]; then
			tc class add dev $lanDev parent 2:4 classid 2:${down_mark_5g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
			tc qdisc add dev $lanDev parent 2:${down_mark_5g} handle ${down_mark_5g}: sfq perturb 10

			tc filter add dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_5g}/0xfff0 fw classid 2:${down_mark_5g}
		else
			local limit=1000
			local down_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
			tcq_d class add dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $down_burst quantum 1500b priority 3
#			tcq_d qdisc add dev $lanDev parent 2:$(gbc_get_classid ${down_mark_5g}) handle $(gbc_get_nqos_handle 2101 9) nsspfifo limit $limit
			gbc_tc_add_nqos_ln_qdisc $lanDev 2:$(gbc_get_classid ${down_mark_5g}) $(gbc_get_nqos_handle 2101 9)
		fi
	fi

	# 5G2
	if [ "${support_triband}" == "yes" -a "${support_6g}" != "yes" -o "${support_fourband}" == "yes" ]; then
		if [ "${global_enable_5g2}" == "on" ]; then
			# wan --> guest_ifname_5g2
			ceil_limitrate=${global_down_band_5g2}
			if [ "$nqos_support" = "yes" ]; then
				nqos_ceil_limitrate=${global_down_band_5g2}
			fi
			limitrate=`expr ${ceil_limitrate} / 10`
			if [ "${qos_enable}" == "on" ]; then
				if [ ${down_low} -lt ${limitrate} ]; then
					limitrate=${down_low}
				fi
				if [ ${downlink} -lt ${ceil_limitrate} ]; then
					ceil_limitrate=${downlink}
				fi
			fi
			if [ ${limitrate} -le 0 ]; then
				limitrate=1
			fi
			limitrate="${limitrate}""kbit"
			ceil_limitrate="${ceil_limitrate}""kbit"
			
			gbc_debug "5G2 wan-->guest_ifname_5g2 limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
			
			if [ "$nqos_support" != "yes" ]; then
				tc class add dev $lanDev parent 2:4 classid 2:${down_mark_5g2} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
				tc qdisc add dev $lanDev parent 2:${down_mark_5g2} handle ${down_mark_5g2}: sfq perturb 10

				tc filter add dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_5g2}/0xfff0 fw classid 2:${down_mark_5g2}
			else
				local limit=1000
				local down_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
				tcq_d class add dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g2}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $down_burst quantum 1500b priority 3
#				tcq_d qdisc add dev $lanDev parent 2:$(gbc_get_classid ${down_mark_5g2}) handle $(gbc_get_nqos_handle 2101 b) nsspfifo limit $limit
				gbc_tc_add_nqos_ln_qdisc $lanDev 2:$(gbc_get_classid ${down_mark_5g2}) $(gbc_get_nqos_handle 2101 b) 
			fi
		fi
	fi

	# 6G
	if [ "${support_6g}" == "yes" ]; then
		if [ "${global_enable_6g}" == "on" ]; then
			# wan --> guest_ifname_6g
			ceil_limitrate=${global_down_band_6g}
			if [ "$nqos_support" = "yes" ]; then
				nqos_ceil_limitrate=${global_down_band_6g}
			fi
			limitrate=`expr ${ceil_limitrate} / 10`
			if [ "${qos_enable}" == "on" ]; then
				if [ ${down_low} -lt ${limitrate} ]; then
					limitrate=${down_low}
				fi
				if [ ${downlink} -lt ${ceil_limitrate} ]; then
					ceil_limitrate=${downlink}
				fi
			fi
			if [ ${limitrate} -le 0 ]; then
				limitrate=1
			fi
			limitrate="${limitrate}""kbit"
			ceil_limitrate="${ceil_limitrate}""kbit"
			
			gbc_debug "6G wan-->guest_ifname_6g limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
			if [ "$nqos_support" != "yes" ]; then
				tc class add dev $lanDev parent 2:4 classid 2:${down_mark_6g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
				tc qdisc add dev $lanDev parent 2:${down_mark_6g} handle ${down_mark_6g}: sfq perturb 10

				tc filter add dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_6g}/0xfff0 fw classid 2:${down_mark_6g}
			else
				local limit=1000
				local down_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
				tcq_d class add dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_6g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $down_burst quantum 1500b priority 3
#				tcq_d qdisc add dev $lanDev parent 2:$(gbc_get_classid ${down_mark_6g}) handle $(gbc_get_nqos_handle 2101 d) nsspfifo limit $limit 
				gbc_tc_add_nqos_ln_qdisc $lanDev 2:$(gbc_get_classid ${down_mark_6g}) $(gbc_get_nqos_handle 2101 d)
			fi
		fi
	fi
	
	gbc_debug "gbc_tc_add_down_rule end"
}

gbc_tc_del_down_rule() {
	gbc_debug "guestnetwork bandwidth del tc down rules"
	# 2.4G, wan --> guest_ifname_2g	 0x0070,112
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_2g})
	else
		tc filter del dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_2g}/0xfff0 fw classid 2:${down_mark_2g}
		tc class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_2g})
	fi

	# 5G,wan --> guest_ifname_5g	 0x0090,144
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g})
	else
		tc filter del dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_5g}/0xfff0 fw classid 2:${down_mark_5g}
		tc class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g})
	fi

	# 5G2, wan --> guest_ifname_5g2	 0x00b0,176
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g2})
	else
		tc filter del dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_5g2}/0xfff0 fw classid 2:${down_mark_5g2}
		tc class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_5g2})
	fi

	# 6G, wan --> guest_ifname_6g	 0x00d0,208
	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_6g})
	else
		tc filter del dev $lanDev parent 2:0 protocol all prio 3 handle ${down_mark_6g}/0xfff0 fw classid 2:${down_mark_6g}
		tc class del dev $lanDev parent 2:4 classid 2:$(gbc_get_classid ${down_mark_6g})
	fi
}

gbc_tc_add_up_rule() {
	gbc_debug "gbc_tc_add_up_rule start"
	local up_band=
	if [[ -n "$qos_rUpband" ]]; then
	    up_band=$((qos_rUpband))
	elif [[ "$qos_up_unit" == "mbps" ]]; then
	    up_band=$((qos_up_band*1000))
	fi

	local limitrate
	local ceil_limitrate
	
	local uplink=$((${qos_percent}*${up_band}/100))
	local up_low=$((${qos_low}*${uplink}/100))
	if [ ${uplink} -le 0 ]; then
		uplink=1
	fi
	if [ ${up_low} -le 0 ]; then
		up_low=1
	fi
	
	if [ "$nqos_support" = "yes" ]; then
		gbc_tc_get_up_rate

		local nqos_limitrate=$(expr ${nqos_gbc_up_rate} / 4)
		local nqos_ceil_limitrate=
	fi
	# 2.4G
	if [ "${global_enable_2g}" == "on" ]; then
		# guest_ifname_2g --> wan
		ceil_limitrate=${global_up_band_2g}
		if [ "$nqos_support" = "yes" ]; then
			nqos_ceil_limitrate=${global_up_band_2g}
		fi
		limitrate=`expr ${ceil_limitrate} / 10`
		if [ "${qos_enable}" == "on" ]; then
			if [ ${up_low} -lt ${limitrate} ]; then
				limitrate=${up_low}
			fi
			if [ ${uplink} -lt ${ceil_limitrate} ]; then
				ceil_limitrate=${uplink}
			fi
		fi
		if [ ${limitrate} -le 0 ]; then
			limitrate=1
		fi
		limitrate="${limitrate}""kbit"
		ceil_limitrate="${ceil_limitrate}""kbit"
		
		gbc_debug "2.4G guest_ifname_2g-->wan limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"

		for i in $ifaces; do
			#local wan_ifname=$(uci get network.$i.ifname)
			local wan_ifname=$(gbc_tc_get_wan_ifname $i)
			[ -z $wan_ifname ] && {
				continue
			}
			if [ "$nqos_support" != "yes" ]; then
				tc class add dev $wan_ifname parent 1:4 classid 1:${up_mark_2g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
				tc qdisc add dev $wan_ifname parent 1:${up_mark_2g} handle ${up_mark_2g}: sfq perturb 10

				tc filter add dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_2g}/0xfff0 fw classid 1:${up_mark_2g}
			else
				local limit=1000
				local up_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
				tcq_d class add dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_2g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $up_burst quantum 1500b priority 3
#				tcq_d qdisc add dev $wan_ifname parent 1:$(gbc_get_classid ${up_mark_2g}) handle $(gbc_get_nqos_handle 1101 6) nsspfifo limit $limit
				gbc_tc_add_nqos_ln_qdisc $wan_ifname 1:$(gbc_get_classid ${up_mark_2g}) $(gbc_get_nqos_handle 1101 6)
			fi
		done
	fi

	# 5G
	if [ "${global_enable_5g1}" == "on" ]; then
		# guest_ifname_5g --> wan
		ceil_limitrate=${global_up_band_5g1}
		if [ "$nqos_support" = "yes" ]; then
			nqos_ceil_limitrate=${global_up_band_5g1}
		fi
		limitrate=`expr ${ceil_limitrate} / 10`
		if [ "${qos_enable}" == "on" ]; then
			if [ ${up_low} -lt ${limitrate} ]; then
				limitrate=${up_low}
			fi
			if [ ${uplink} -lt ${ceil_limitrate} ]; then
				ceil_limitrate=${uplink}
			fi
		fi
		if [ ${limitrate} -le 0 ]; then
			limitrate=1
		fi
		limitrate="${limitrate}""kbit"
		ceil_limitrate="${ceil_limitrate}""kbit"
		
		gbc_debug "5G guest_ifname_5g --> wan limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
		
		for i in $ifaces; do
			#local wan_ifname=$(uci get network.$i.ifname)
			local wan_ifname=$(gbc_tc_get_wan_ifname $i)
			[ -z $wan_ifname ] && {
				continue
			}
			if [ "$nqos_support" != "yes" ]; then
				tc class add dev $wan_ifname parent 1:4 classid 1:${up_mark_5g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
				tc qdisc add dev $wan_ifname parent 1:${up_mark_5g} handle ${up_mark_5g}: sfq perturb 10

				tc filter add dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_5g}/0xfff0 fw classid 1:${up_mark_5g}
			else
				local limit=1000
				local up_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
				tcq_d class add dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $up_burst quantum 1500b priority 3
#				tcq_d qdisc add dev $wan_ifname parent 1:$(gbc_get_classid ${up_mark_5g}) handle $(gbc_get_nqos_handle 1101 8) nsspfifo limit $limit
				gbc_tc_add_nqos_ln_qdisc $wan_ifname 1:$(gbc_get_classid ${up_mark_5g}) $(gbc_get_nqos_handle 1101 8)
			fi
		done
	fi

	# 5G2
	if [ "${support_triband}" == "yes" -a "${support_6g}" != "yes" -o "${support_fourband}" == "yes" ]; then
		if [ "${global_enable_5g2}" == "on" ]; then
			# guest_ifname_5g2 --> wan
			ceil_limitrate=${global_up_band_5g2}
			if [ "$nqos_support" = "yes" ]; then
				nqos_ceil_limitrate=${global_up_band_5g2}
			fi
			limitrate=`expr ${ceil_limitrate} / 10`
			if [ "${qos_enable}" == "on" ]; then
				if [ ${up_low} -lt ${limitrate} ]; then
					limitrate=${up_low}
				fi
				if [ ${uplink} -lt ${ceil_limitrate} ]; then
					ceil_limitrate=${uplink}
				fi
			fi
			if [ ${limitrate} -le 0 ]; then
				limitrate=1
			fi
			limitrate="${limitrate}""kbit"
			ceil_limitrate="${ceil_limitrate}""kbit"
			
			gbc_debug "5G2 guest_ifname_5g2 --> wan limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
			
			for i in $ifaces; do
				#local wan_ifname=$(uci get network.$i.ifname)
				local wan_ifname=$(gbc_tc_get_wan_ifname $i)
				[ -z $wan_ifname ] && {
					continue
				}
				if [ "$nqos_support" != "yes" ]; then
					tc class add dev $wan_ifname parent 1:4 classid 1:${up_mark_5g2} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
					tc qdisc add dev $wan_ifname parent 1:${up_mark_5g2} handle ${up_mark_5g2}: sfq perturb 10
					tc filter add dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_5g2}/0xfff0 fw classid 1:${up_mark_5g2}
				else
					local limit=1000
					local up_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
					tcq_d class add dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g2}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $up_burst quantum 1500b priority 3
#					tcq_d qdisc add dev $wan_ifname parent 1:$(gbc_get_classid ${up_mark_5g2}) handle $(gbc_get_nqos_handle 1101 a)  nsspfifo limit $limit
					 gbc_tc_add_nqos_ln_qdisc $wan_ifname 1:$(gbc_get_classid ${up_mark_5g2}) $(gbc_get_nqos_handle 1101 a)

				fi
			done
		fi
	fi

	# 6G
	if [ "${support_6g}" == "yes" ]; then
		if [ "${global_enable_6g}" == "on" ]; then
			# guest_ifname_6g --> wan
			ceil_limitrate=${global_up_band_6g}
			if [ "$nqos_support" = "yes" ]; then
				nqos_ceil_limitrate=${global_up_band_6g}
			fi
			limitrate=`expr ${ceil_limitrate} / 10`
			if [ "${qos_enable}" == "on" ]; then
				if [ ${up_low} -lt ${limitrate} ]; then
					limitrate=${up_low}
				fi
				if [ ${uplink} -lt ${ceil_limitrate} ]; then
					ceil_limitrate=${uplink}
				fi
			fi
			if [ ${limitrate} -le 0 ]; then
				limitrate=1
			fi
			limitrate="${limitrate}""kbit"
			ceil_limitrate="${ceil_limitrate}""kbit"
			
			gbc_debug "6G guest_ifname_6g --> wan limitrate:${limitrate}, ceil_limitrate:${ceil_limitrate}"
			
			for i in $ifaces; do
				#local wan_ifname=$(uci get network.$i.ifname)
				local wan_ifname=$(gbc_tc_get_wan_ifname $i)
				[ -z $wan_ifname ] && {
					continue
				}
				if [ "$nqos_support" != "yes" ]; then
					tc class add dev $wan_ifname parent 1:4 classid 1:${up_mark_6g} htb rate "${limitrate}" ceil "${ceil_limitrate}" prio 3
					tc qdisc add dev $wan_ifname parent 1:${up_mark_6g} handle ${up_mark_6g}: sfq perturb 10

					tc filter add dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_6g}/0xfff0 fw classid 1:${up_mark_6g}
				else
					local limit=1000
					local up_burst=$(gbc_tc_get_nqos_burst $nqos_limitrate $nqos_ceil_limitrate)
					tcq_d class add dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_6g}) nsshtb rate "${nqos_limitrate}""kbit" crate "${nqos_ceil_limitrate}""kbit" $up_burst quantum 1500b priority 3
#					tcq_d qdisc add dev $wan_ifname parent 1:$(gbc_get_classid ${up_mark_6g}) handle $(gbc_get_nqos_handle 1101 c) nsspfifo limit $limit
					gbc_tc_add_nqos_ln_qdisc $wan_ifname 1:$(gbc_get_classid ${up_mark_6g}) $(gbc_get_nqos_handle 1101 c)
				fi
			done
		fi
	fi
        
	gbc_debug "gbc_tc_add_up_rule end"
}

gbc_tc_del_up_rule() {
	gbc_debug "guestnetwork bandwidth del tc up rules"
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(gbc_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		# 2.4G guest_ifname_2g --> wan	 0x0060,96
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_2g})
		else
			tc filter del dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_2g}/0xfff0 fw classid 1:${up_mark_2g}
			tc class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_2g})
		fi

		# 5G guest_ifname_5g --> wan	 0x0080,128
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g})
		else
			tc filter del dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_5g}/0xfff0 fw classid 1:${up_mark_5g}
			tc class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g})
		fi

		# 5G2 guest_ifname_5g2 --> wan	 0x00a0,160
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g2})
		else
			tc filter del dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_5g2}/0xfff0 fw classid 1:${up_mark_5g2}
			tc class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_5g2})
		fi

		# 6G guest_ifname_6g --> wan	 0x00c0,192
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_6g})
		else
			tc filter del dev $wan_ifname parent 1:0 protocol all prio 3 handle ${up_mark_6g}/0xfff0 fw classid 1:${up_mark_6g}
			tc class del dev $wan_ifname parent 1:4 classid 1:$(gbc_get_classid ${up_mark_6g})
		fi
	done
}		

gbc_tc_add_parent_rule() {
	local action="add"
	if [ "$nqos_support" = "yes" ]; then
		[ "$1" = "update" ] && action="replace"
	fi
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
	local up_high=$((${qos_high}*${uplink}/100))

	if [ ${uplink} -le 0 ]; then
		uplink=1
	fi
	if [ ${up_low} -le 0 ]; then
		up_low=1
	fi
	
	uplink="${uplink}""kbit"
	up_low="${up_low}""kbit"
	
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(gbc_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		gbc_debug "guest uplink up_low:${up_low}, uplink:${uplink}"
		if [ "$nqos_support" != "yes" ]; then
		tc class add dev $wan_ifname parent 1:1 classid 1:4 htb rate ${up_low} ceil ${uplink} prio 3
		else
			gbc_tc_get_up_rate
			local up_burst=$(gbc_tc_get_nqos_burst $nqos_gbc_up_rate $nqos_gbc_up_crate)
			tcq_d class $action dev $wan_ifname parent 1:1 classid 1:4 nsshtb rate "$nqos_gbc_up_rate""kbit" crate "$nqos_gbc_up_crate""kbit" $up_burst quantum 1500b priority 3
		fi
	done

	# add downlink tc
	local down_band
	local nqos_gbc_down_rate
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
	
	downlink="${downlink}""kbit"
	down_low="${down_low}""kbit"
	
	gbc_debug "guest downlink down_low:${down_low}, downlink:${downlink}"
	if [ "$nqos_support" != "yes" ]; then
		tc class add dev $lanDev parent 2:1 classid 2:4 htb rate ${down_low} ceil ${downlink} prio 3
	else
		gbc_tc_get_down_rate
		local down_burst=$(gbc_tc_get_nqos_burst $nqos_gbc_down_rate $nqos_gbc_down_crate)
		tcq_d class $action dev $lanDev parent 2:1 classid 2:4 nsshtb rate "$nqos_gbc_down_rate""kbit" crate "$nqos_gbc_down_crate""kbit" $down_burst quantum 1500b priority 3
	fi
}

gbc_tc_del_parent_rule() {
	for i in $ifaces; do
		#local wan_ifname=$(uci get network.$i.ifname)
		local wan_ifname=$(gbc_tc_get_wan_ifname $i)
		[ -z $wan_ifname ] && {
			continue
		}
		if [ "$nqos_support" = "yes" ]; then
			tcq_d class del dev $wan_ifname parent 1:1 classid 1:4
		else
			tc class del dev $wan_ifname parent 1:1 classid 1:4
		fi
	done

	if [ "$nqos_support" = "yes" ]; then
		tcq_d class del dev $lanDev parent 2:1 classid 2:4
	else
		tc class del dev $lanDev parent 2:1 classid 2:4
	fi
	
	# del tc root
	. /lib/qos/core_qos.sh
	fw_del_tc_root
}

gbc_fw_add_rule() {
	gbc_debug "gbc_fw_add_rule start"

	#QCA, nss qos need classify netfilter target.
	if [ "$nqos_support" = "yes" ]; then
		if [ "$wireless_qos_support" = "yes" ]; then
			[ ! -d /sys/module/xt_CLASSIFYMASK ] && insmod /lib/modules/iplatform/xt_CLASSIFYMASK.ko
		else
			[ ! -d /sys/module/xt_CLASSIFY ] && insmod /lib/modules/$(uname -r)/xt_CLASSIFY.ko
		fi
	fi

	# guest_ifname --> wan
	if [ "${global_enable_2g}" == "on" -o "${global_enable_5g1}" == "on" -o "${global_enable_5g2}" == "on" -o "${global_enable_6g}" == "on" ]; then
		local lan_rule=$(fw list 4 m | grep "limit_guest_wan_rule")
		[ -z "${lan_rule}" ] && {
			fw add 4 m limit_guest_wan_rule
			fw add 4 m zone_lan_qos limit_guest_wan_rule 1
		}
	fi
	# 2.4G guest_ifname_2g --> wan
	if [ "${global_enable_2g}" == "on" ]; then
		fw add 4 m limit_guest_2g_wan_rule
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# set tc flags
			iptables -t mangle -I limit_guest_2g_wan_rule -j BLOGTG --set-tcflag 1
		}
		#fw add 4 m limit_guest_2g_wan_rule "MARK --set-xmark ${up_mark_2g}/0xfff0"
		fw add 4 m limit_guest_2g_wan_rule "CONNMARK --set-xmark ${up_mark_2g}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m limit_guest_2g_wan_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 1101 6)/0xfffffff0"
			else
				fw add 4 m limit_guest_2g_wan_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 1101 6)"
			fi
		fi
		fw add 4 m limit_guest_2g_wan_rule ACCEPT
		fw add 4 m limit_guest_wan_rule limit_guest_2g_wan_rule { "-m mark --mark ${up_mark_2g}/0xfff0" }
		#fw add 4 m limit_guest_wan_rule limit_guest_2g_wan_rule { "-i br-lan" }
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# clear acceleration entry
			local guest_ifname_2g=$(uci get profile.@wireless[0].wireless_guest_ifname_2g -c "/etc/profile.d" -q)
			fc flush --if "${guest_ifname_2g}"
		}
		# MT798x
		[ -e /sys/kernel/debug/hnat/skip_ct ] && {
			echo "add:0x60 0xfff0 1" > /sys/kernel/debug/hnat/skip_ct
		}

		# RTK8198
		[ -e /proc/fc/ctrl/skip_ct ] && {
			echo "add:0x60 0xfff0 1" > /proc/fc/ctrl/skip_ct
		}
	fi
	
	# 5G guest_ifname_5g --> wan
	if [ "${global_enable_5g1}" == "on" ]; then
		fw add 4 m limit_guest_5g_wan_rule
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# set tc flags
			iptables -t mangle -I limit_guest_5g_wan_rule -j BLOGTG --set-tcflag 1
		}
		fw add 4 m limit_guest_5g_wan_rule "CONNMARK --set-xmark ${up_mark_5g}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m limit_guest_5g_wan_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 1101 8)/0xfffffff0"
			else
				fw add 4 m limit_guest_5g_wan_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 1101 8)"
			fi
		fi
		fw add 4 m limit_guest_5g_wan_rule ACCEPT
		fw add 4 m limit_guest_wan_rule limit_guest_5g_wan_rule { "-m mark --mark ${up_mark_5g}/0xfff0" }
		# BCM, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			# clear acceleration entry
			local guest_ifname_5g=$(uci get profile.@wireless[0].wireless_guest_ifname_5g -c "/etc/profile.d" -q)
			fc flush --if "${guest_ifname_5g}"
		}
		# MT798x
		[ -e /sys/kernel/debug/hnat/skip_ct ] && {
			echo "add:0x80 0xfff0 1" > /sys/kernel/debug/hnat/skip_ct
		}

		# RTK8198
		[ -e /proc/fc/ctrl/skip_ct ] && {
			echo "add:0x80 0xfff0 1" > /proc/fc/ctrl/skip_ct
		}
	fi

	# 5G2 guest_ifname_5g_2 --> wan
	if [ "${support_triband}" == "yes" -a "${support_6g}" != "yes" -o "${support_fourband}" == "yes" ]; then
		if [ "${global_enable_5g2}" == "on" ]; then
			fw add 4 m limit_guest_5g2_wan_rule
			# BCM, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				#  set tc flags
				iptables -t mangle -I limit_guest_5g2_wan_rule -j BLOGTG --set-tcflag 1
			}
			fw add 4 m limit_guest_5g2_wan_rule "CONNMARK --set-xmark ${up_mark_5g2}/0xfff0"
			if [ "$nqos_support" = "yes" ]; then
				if [ "$wireless_qos_support" = "yes" ]; then
					fw add 4 m limit_guest_5g2_wan_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 1101 a)/0xfffffff0"
				else
					fw add 4 m limit_guest_5g2_wan_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 1101 a)"
				fi
			fi
			fw add 4 m limit_guest_5g2_wan_rule ACCEPT
			fw add 4 m limit_guest_wan_rule limit_guest_5g2_wan_rule { "-m mark --mark ${up_mark_5g2}/0xfff0" }
			# BCM, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				# clear acceleration entry
				local guest_ifname_5g_2=$(uci get profile.@wireless[0].wireless_guest_ifname_5g_2 -c "/etc/profile.d" -q)
				fc flush --if "${guest_ifname_5g_2}"
			}
			# MT798x
			[ -e /sys/kernel/debug/hnat/skip_ct ] && {
				echo "add:0xa0 0xfff0 1" > /sys/kernel/debug/hnat/skip_ct
			}

			# RTK8198
			[ -e /proc/fc/ctrl/skip_ct ] && {
				echo "add:0xa0 0xfff0 1" > /proc/fc/ctrl/skip_ct
			}

		fi
	fi

	# 6G guest_ifname_6g --> wan
	if [ "${support_6g}" == "yes" ]; then
		if [ "${global_enable_6g}" == "on" ]; then
			fw add 4 m limit_guest_6g_wan_rule
			# BCM, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				#  set tc flags
				iptables -t mangle -I limit_guest_6g_wan_rule -j BLOGTG --set-tcflag 1
			}
			fw add 4 m limit_guest_6g_wan_rule "CONNMARK --set-xmark ${up_mark_6g}/0xfff0"
			if [ "$nqos_support" = "yes" ]; then
				if [ "$wireless_qos_support" = "yes" ]; then
					fw add 4 m limit_guest_6g_wan_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 1101 c)/0xfffffff0"
				else
					fw add 4 m limit_guest_6g_wan_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 1101 c)"
				fi
			fi
			fw add 4 m limit_guest_6g_wan_rule ACCEPT
			fw add 4 m limit_guest_wan_rule limit_guest_6g_wan_rule { "-m mark --mark ${up_mark_6g}/0xfff0" }
			# BCM, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				# clear acceleration entry
				local guest_ifname_6g=$(uci get profile.@wireless[0].wireless_guest_ifname_6g -c "/etc/profile.d" -q)
				fc flush --if "${guest_ifname_6g}"
			}

			# RTK8198
			[ -e /proc/fc/ctrl/skip_ct ] && {
				echo "add:0xc0 0xfff0 1" > /proc/fc/ctrl/skip_ct
			}
		fi
	fi
	
	# wan --> guest_ifname
	if [ "${global_enable_2g}" == "on" -o "${global_enable_5g1}" == "on" -o "${global_enable_5g2}" == "on" -o "${global_enable_6g}" == "on" ]; then
		local wan_rule=$(fw list 4 m | grep "limit_wan_guest_rule")
		[ -z "${wan_rule}" ] && {
			fw add 4 m limit_wan_guest_rule
			fw add 4 m zone_wan_qos limit_wan_guest_rule 1
		}
	fi
	# wan --> 2.4G guest_ifname_2g 0x0070
	if [ "${global_enable_2g}" == "on" ]; then
		fw add 4 m limit_wan_guest_2g_rule
		# BCM, set tc flags, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			iptables -t mangle -I limit_wan_guest_2g_rule -j BLOGTG --set-tcflag 1
		}
		fw add 4 m limit_wan_guest_2g_rule "MARK --set-xmark ${down_mark_2g}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m limit_wan_guest_2g_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 2101 7)/0xfffffff0"
			else
				fw add 4 m limit_wan_guest_2g_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 2101 7)"
			fi
		fi
		fw add 4 m limit_wan_guest_2g_rule ACCEPT
		fw add 4 m limit_wan_guest_rule limit_wan_guest_2g_rule { "-m connmark --mark ${up_mark_2g}/0xfff0" }
		# BCM, set tc flags, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			fc flush --if "${guest_ifname_2g}"
		}
	fi
	
	# wan --> 5G guest_ifname_5g 0x0090
	if [ "${global_enable_5g1}" == "on" ]; then
		fw add 4 m limit_wan_guest_5g_rule
		# BCM, set tc flags, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			iptables -t mangle -I limit_wan_guest_5g_rule -j BLOGTG --set-tcflag 1
		}
		fw add 4 m limit_wan_guest_5g_rule "MARK --set-xmark ${down_mark_5g}/0xfff0"
		if [ "$nqos_support" = "yes" ]; then
			if [ "$wireless_qos_support" = "yes" ]; then
				fw add 4 m limit_wan_guest_5g_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 2101 9)/0xfffffff0"
			else
				fw add 4 m limit_wan_guest_5g_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 2101 9)"
			fi
		fi
		fw add 4 m limit_wan_guest_5g_rule ACCEPT
		fw add 4 m limit_wan_guest_rule limit_wan_guest_5g_rule { "-m connmark --mark ${up_mark_5g}/0xfff0" }
		# BCM, set tc flags, only for bcm fcache now
		[ -e /proc/fcache/ ] && {
			fc flush --if "${guest_ifname_5g1}"
		}
	fi

	# wan --> 5G2 guest_ifname_5g_2 0x00b0
	if [ "${support_triband}" == "yes" -a "${support_6g}" != "yes" -o "${support_fourband}" == "yes" ]; then
		if [ "${global_enable_5g2}" == "on" ]; then
			fw add 4 m limit_wan_guest_5g2_rule
			# BCM, set tc flags, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				iptables -t mangle -I limit_wan_guest_5g2_rule -j BLOGTG --set-tcflag 1
			}
			fw add 4 m limit_wan_guest_5g2_rule "MARK --set-xmark ${down_mark_5g2}/0xfff0"
			if [ "$nqos_support" = "yes" ]; then
				if [ "$wireless_qos_support" = "yes" ]; then
					fw add 4 m limit_wan_guest_5g2_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 2101 b)/0xfffffff0"
				else
					fw add 4 m limit_wan_guest_5g2_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 2101 b)"
				fi
			fi
			fw add 4 m limit_wan_guest_5g2_rule ACCEPT
			fw add 4 m limit_wan_guest_rule limit_wan_guest_5g2_rule { "-m connmark --mark ${up_mark_5g2}/0xfff0" }
			# BCM, set tc flags, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				fc flush --if "${guest_ifname_5g2}"
			}
		fi
	fi

	# wan --> 6G guest_ifname_6g 0x00d0
	if [ "${support_6g}" == "yes" ]; then
		if [ "${global_enable_6g}" == "on" ]; then
			fw add 4 m limit_wan_guest_6g_rule
			# BCM, set tc flags, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				iptables -t mangle -I limit_wan_guest_6g_rule -j BLOGTG --set-tcflag 1
			}
			fw add 4 m limit_wan_guest_6g_rule "MARK --set-xmark ${down_mark_6g}/0xfff0"
			if [ "$nqos_support" = "yes" ]; then
				if [ "$wireless_qos_support" = "yes" ]; then
					fw add 4 m limit_wan_guest_6g_rule "CLASSIFYMASK --set-class $(gbc_get_nqos_handle 2101 d)/0xfffffff0"
				else
					fw add 4 m limit_wan_guest_6g_rule "CLASSIFY --set-class $(gbc_get_nqos_handle 2101 d)"
				fi
			fi
			fw add 4 m limit_wan_guest_6g_rule ACCEPT
			fw add 4 m limit_wan_guest_rule limit_wan_guest_6g_rule { "-m connmark --mark ${up_mark_6g}/0xfff0" }
			# BCM, set tc flags, only for bcm fcache now
			[ -e /proc/fcache/ ] && {
				fc flush --if "${guest_ifname_6g}"
			}
		fi
	fi
	gbc_debug "gbc_fw_add_rule end"
}

gbc_fw_del_rule() {
	gbc_debug "gbc_fw_del_rule start"
	# guest_ifname --> wan
	fw flush 4 m limit_guest_wan_rule
	fw flush 4 m limit_guest_2g_wan_rule
	fw flush 4 m limit_guest_5g_wan_rule
	fw flush 4 m limit_guest_5g2_wan_rule
	fw flush 4 m limit_guest_6g_wan_rule
	
	fw del 4 m limit_guest_2g_wan_rule
	fw del 4 m limit_guest_5g_wan_rule
	fw del 4 m limit_guest_5g2_wan_rule
	fw del 4 m limit_guest_6g_wan_rule
	fw del 4 m zone_lan_qos limit_guest_wan_rule
	fw del 4 m limit_guest_wan_rule

	# wan --> guest_ifname
	fw flush 4 m limit_wan_guest_rule
	fw flush 4 m limit_wan_guest_2g_rule
	fw flush 4 m limit_wan_guest_5g_rule
	fw flush 4 m limit_wan_guest_5g2_rule
	fw flush 4 m limit_wan_guest_6g_rule

	fw del 4 m limit_wan_guest_2g_rule
	fw del 4 m limit_wan_guest_5g_rule
	fw del 4 m limit_wan_guest_5g2_rule
	fw del 4 m limit_wan_guest_6g_rule
	fw del 4 m zone_wan_qos limit_wan_guest_rule
	fw del 4 m limit_wan_guest_rule

	# MT798x
	[ -e /sys/kernel/debug/hnat/skip_ct ] && {
		echo "clear:1" > /sys/kernel/debug/hnat/skip_ct
	}

	# RTK8198
	[ -e /proc/fc/ctrl/skip_ct ] && {
		echo "clear:1" > /proc/fc/ctrl/skip_ct
	}
	
	gbc_debug "gbc_fw_del_rule end"
}

