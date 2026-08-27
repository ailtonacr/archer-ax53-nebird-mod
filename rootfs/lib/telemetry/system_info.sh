# Copyright (C) 2009-2010 OpenWrt.org
. /lib/config/uci.sh

collect_system_info() {
	local timestamp
	local old_restart_num
	local old_restart_time_list
	local restart_num
	local restart_time_list
	local ntp_flag=$(uci_get_state systime core sync)

	while [ "$ntp_flag" != "1" ];do
		sleep 10
		ntp_flag=$(uci_get_state systime core sync)
	done

	echo "ntp is syncd! ntp_flag:$ntp_flag" > /dev/console
	
	timestamp=$(date +%s)
	
	if [ ! -f /etc/config/telemetry ];then
			touch /etc/config/telemetry
			uci commit
	fi

	old_restart_num=`uci -q get telemetry.system_info.restart_num`
	if [ -n "${old_restart_num}" ]; then
		restart_num=`expr ${old_restart_num} + 1`
		uci set telemetry.system_info.restart_num="${restart_num}"
	else
		uci set telemetry.system_info="global"
		uci set telemetry.system_info.restart_num=1
	fi

	old_restart_time_list=`uci -q get telemetry.system_info.restart_time_list`
	if [ -n "${old_restart_time_list}" ]; then
		restart_time_list="${old_restart_time_list} ${timestamp}"
		uci set telemetry.system_info.restart_time_list="${restart_time_list}"
	else
		uci set telemetry.system_info="global"
		restart_time_list="${timestamp}"
		uci set telemetry.system_info.restart_time_list="${restart_time_list}"
	fi
	uci set telemetry.system_info.collect_flag=1
	uci commit telemetry
}

