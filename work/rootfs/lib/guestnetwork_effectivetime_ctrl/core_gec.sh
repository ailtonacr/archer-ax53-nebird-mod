# Copyright (C) 2014-2015 TP-link
. /lib/config/uci.sh

crontab_cmd="* * * * * /sbin/gec_check"

GEC_DEBUG_TEST=0

gec_debug()
{
	[ ${GEC_DEBUG_TEST} -gt 0 ] && {
		echo "[ guest network effective time ctrl core_gbc.sh ] $1"	> /dev/console
	}
}

gec_load() {
	gec_debug "gec_load "
	local finish_time=$(uci get guestnetwork_effectivetime_ctrl.settings.finish_time)
	
	local now=`date '+%s'`

	echo "finish_time:${finish_time}"
	echo "now:${now}"
	
	local CRON_FILE="/etc/crontabs/root"
	local TMP_CRONTAB="/tmp/gec_cron"
	local GEC_SBIN="/sbin/gec_check"
	local cron_item=`grep "${GEC_SBIN}" ${CRON_FILE}`
	[ "${cron_item}" != "${crontab_cmd}" ] && {
					echo "${crontab_cmd}" > ${TMP_CRONTAB}
					crontab -l | grep -v "${GEC_SBIN}" | cat - "${TMP_CRONTAB}" | crontab -
					rm -f ${TMP_CRONTAB}
	}
}

gec_check_time() {
	local finish_time=$(uci get guestnetwork_effectivetime_ctrl.settings.finish_time)
	local now=`date '+%s'`
	local new_remain_time=`expr $finish_time - $now`
	local sys_model=$(uci get profile.@global[0].model -c "/etc/profile.d" -q)
	local ntp_flag=$(uci_get_state systime.core.sync)

	if [ "${ntp_flag}" != "1" ]; then
		gec_debug "ntp not sync"
		return
	fi

	if [ "${new_remain_time}" -gt 0 ]; then
		uci set guestnetwork_effectivetime_ctrl.settings.remain_time="${new_remain_time}"
	fi
	
	if [ "${finish_time}" -ge 0 -a "${now}" -ge "${finish_time}" ]; then
		gec_debug "will turn off guest network"
		# set config
		uci set guestnetwork_effectivetime_ctrl.settings.finish_time="-1"
		uci set guestnetwork_effectivetime_ctrl.settings.remain_time="-1"
		uci set guestnetwork_effectivetime_ctrl.settings.type="none"
		
		# get guest network ifname
		local guest_ifname_2g=$(uci get profile.@wireless[0].wireless_guest_ifname_2g -c "/etc/profile.d" -q)
		local guest_ifname_5g=$(uci get profile.@wireless[0].wireless_guest_ifname_5g -c "/etc/profile.d" -q)
		local guest_ifname_5g_2=$(uci get profile.@wireless[0].wireless_guest_ifname_5g_2 -c "/etc/profile.d" -q)
		local guest_ifname_6g=$(uci get profile.@wireless[0].wireless_guest_ifname_6g -c "/etc/profile.d" -q)

		if [ -n "${guest_ifname_2g}" ];then
			local tmp=$(uci show | grep ${guest_ifname_2g} | grep ifname)
			local gst_2g_section=$(echo ${tmp}|awk -F '.' '{print $2}')
			# set guest config
			uci set wireless.${gst_2g_section}.enable="off"
			
			# turn down guest
			if [ "${sys_model}" == "QCA_IPQ50XX" -o "${sys_model}" == "QCA_IPQ95XX" ]; then
				# QCA
				wifi vap "$guest_ifname_2g"
			elif [ "${sys_model}" == "MTK_798x" -o "${sys_model}" == "MTK_762x" ]; then
				# MTK
				wifi vap "$guest_ifname_2g"
			elif [ "${sys_model}" == "RTL_8197" -o "${sys_model}" == "RTL_8198" ]; then
				# RTK
				wifi vap "$guest_ifname_2g"
			else
				# BCM
				wl -i "$guest_ifname_2g" bss down
			fi
		fi
		
		if [ -n "${guest_ifname_5g}" ];then
			local tmp=$(uci show | grep ${guest_ifname_5g} | grep ifname)
			local gst_5g_section=$(echo ${tmp}|awk -F '.' '{print $2}')
			# set guest config
			uci set wireless.${gst_5g_section}.enable="off"
			
			# turn down guest
			if [ "${sys_model}" == "QCA_IPQ50XX" -o "${sys_model}" == "QCA_IPQ95XX" ]; then
				# QCA
				wifi vap "$guest_ifname_5g"
			elif [ "${sys_model}" == "MTK_798x" -o "${sys_model}" == "MTK_762x" ]; then
				# MTK
				wifi vap "$guest_ifname_5g"
			elif [ "${sys_model}" == "RTL_8197" -o "${sys_model}" == "RTL_8198" ]; then
				# RTK
				wifi vap "$guest_ifname_5g"
			else
				# BCM
				wl -i "$guest_ifname_5g" bss down
			fi
		fi
		
		if [ -n "${guest_ifname_5g_2}" ];then
			local tmp=$(uci show | grep ${guest_ifname_5g_2} | grep ifname)
			local gst_5g2_section=$(echo ${tmp}|awk -F '.' '{print $2}')
			# set guest config
			uci set wireless.${gst_5g2_section}.enable="off"
			
			# turn down guest
			if [ "${sys_model}" == "QCA_IPQ50XX" -o "${sys_model}" == "QCA_IPQ95XX" ]; then
				# QCA
				wifi vap "$guest_ifname_5g_2"
			elif [ "${sys_model}" == "MTK_798x" -o "${sys_model}" == "MTK_762x" ]; then
				# MTK
				wifi vap "$guest_ifname_5g_2"
			elif [ "${sys_model}" == "RTL_8197" -o "${sys_model}" == "RTL_8198" ]; then
				# RTK
				wifi vap "$guest_ifname_5g_2"
			else
				# BCM
				wl -i "$guest_ifname_5g_2" bss down
			fi
		fi
		
		if [ -n "${guest_ifname_6g}" ];then
			local tmp=$(uci show | grep ${guest_ifname_6g} | grep ifname)
			local gst_6g_section=$(echo ${tmp}|awk -F '.' '{print $2}')
			# set guest config
			uci set wireless.${gst_6g_section}.enable="off"
			
			# turn down guest
			if [ "${sys_model}" == "QCA_IPQ50XX" -o "${sys_model}" == "QCA_IPQ95XX" ]; then
				# QCA
				wifi vap "$guest_ifname_6g"
			elif [ "${sys_model}" == "MTK_798x" -o "${sys_model}" == "MTK_762x" ]; then
				# MTK
				wifi vap "$guest_ifname_6g"
			elif [ "${sys_model}" == "RTL_8197" -o "${sys_model}" == "RTL_8198" ]; then
				# RTK
				wifi vap "$guest_ifname_6g"
			else
				# BCM
				wl -i "$guest_ifname_6g" bss down
			fi
		fi
		
		# delete the gbc_check
		crontab -l | grep -v "$crontab_cmd" | crontab -
		
	fi

	uci commit
}

gec_exit() {
	gec_debug "gec_exit "
	crontab -l | grep -v "$crontab_cmd" | crontab -
}
