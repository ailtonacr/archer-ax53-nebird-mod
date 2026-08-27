# Copyright (C) 2009-2010 OpenWrt.org

. /lib/functions.sh
. /lib/config/uci.sh
. /lib/wifi/wireless_schedule_func.sh



wireless_schedule_start() {
	local enable_all enable_2g   enable_5g   
	local calendar_2g calendar_5g 
	local need_commit
	local need="no"

	local support_triband=$(uci get profile.@wireless[0].support_triband -c "/etc/profile.d") or "no"
	local support_fourband=$(uci get profile.@wireless[0].support_fourband -c "/etc/profile.d") or "no"
	local support_6g=$(uci get profile.@wireless[0].support_6g -c "/etc/profile.d" -q) or "no"

	config_load wireless_schedule
    
	config_get enable_all set enable
	if [ "$enable_all" = "off" ]; then
		echo "wireless schedule's main switch is off" >/dev/console
		return
	fi

	config_get enable_2g 2g enable
	if [ "$enable_2g" = "on" ]; then
		config_get calendar_2g 2g calendar
		if [ -n "$calendar_2g" ]; then
			tsched_conf -a wireless_schedule "2g" "$calendar_2g" "1"
			need="yes"
		else
			uci -q set wireless_schedule.2g.enable="off"
			need_commit="yes"
			wireless_schedule_handle_dorm "2g"
		fi
	fi

	config_get enable_5g 5g enable
	if [ "$enable_5g" = "on" ]; then
		config_get calendar_5g 5g calendar
		if [ -n "$calendar_5g" ]; then
			tsched_conf -a wireless_schedule "5g" "$calendar_5g" "1"
			need="yes"
		else
			uci -q set wireless_schedule.5g.enable="off"
			need_commit="yes"
			wireless_schedule_handle_dorm "5g"
		fi
	fi

	if [ $support_fourband = "yes" ] || [ $support_triband = "yes" -a $support_6g != "yes" ]; then
		config_get enable_5g_2 5g_2 enable
		if [ "$enable_5g_2" = "on" ]; then
			config_get calendar_5g_2 5g_2 calendar
			if [ -n "$calendar_5g_2" ]; then
				tsched_conf -a wireless_schedule "5g_2" "$calendar_5g_2" "1"
				need="yes"
			else
				uci -q set wireless_schedule.5g_2.enable="off"
				need_commit="yes"
				wireless_schedule_handle_dorm "5g_2"
			fi
		fi
	fi

	if [ $support_6g = "yes" ]; then
		config_get enable_6g 6g enable
		if [ "$enable_6g" = "on" ]; then
			config_get calendar_6g 6g calendar
			if [ -n "$calendar_6g" ]; then
				tsched_conf -a wireless_schedule "6g" "$calendar_6g" "1"
				need="yes"
			else
				uci -q set wireless_schedule.6g.enable="off"
				need_commit="yes"
				wireless_schedule_handle_dorm "6g"
			fi
		fi
	fi

	[ "$need" = "yes" ] || [ "$1" == "yes" ] && tsched_conf -u wireless_schedule
	[ "$need_commit" = "yes" ] && uci commmit
}

wireless_schedule_stop() {
	tsched_conf -D wireless_schedule
	tsched_conf -u wireless_schedule
	wireless_schedule_handle_dorm "stop"
}

wireless_schedule_restart() {
	tsched_conf -D wireless_schedule
	wireless_schedule_start "yes"
}

wireless_schedule_skip() {
	wireless_schedule_handle_dorm "skip"
}

if [ "$1" = "skip" ]; then
	wireless_schedule_skip
fi