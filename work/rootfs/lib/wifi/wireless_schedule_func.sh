#!/bin/sh

. /lib/config/uci.sh
. /lib/functions.sh

WS_DEBUG=0
if [ "$WS_DEBUG" -eq 1 ]; then
	WS_CONSOLE="/dev/console"
else
	WS_CONSOLE="/dev/null"
fi

need_reload=""

local support_triband=$(uci get profile.@wireless[0].support_triband -c "/etc/profile.d") or "no"
local support_fourband=$(uci get profile.@wireless[0].support_fourband -c "/etc/profile.d") or "no"
local support_6g=$(uci get profile.@wireless[0].support_6g -c "/etc/profile.d" -q) or "no"

wireless_schedule_set_enable(){
	local section=$1
	local mode=$(uci -q get wireless.$section.mode)
	local guest=$(uci -q get wireless.$section.guest)
	local iot=$(uci -q get wireless.$section.iot)
	local backhaul=$(uci -q get wireless.$section.backhaul)
	local onemesh_config=$(uci -q get wireless.$section.onemesh_config)
	local mlo_host=$(uci -q get wireless.$section.mlo_host)
	local multi_ssid_1=$(uci -q get wireless.$section.multi_ssid_1)
	local multi_ssid_2=$(uci -q get wireless.$section.multi_ssid_2)
	local multi_ssid_3=$(uci -q get wireless.$section.multi_ssid_3)
	
	if [ "$#" -eq "3" ]; then
		if [ "$(uci get wireless.$section.device)" = "$3" ]; then
			if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$backhaul" -a -z "$onemesh_config" -a -z "$mlo_host" ]; then
				if [ "$2" = "on" ] && [ "$multi_ssid_1" -o "$multi_ssid_2" -o "$multi_ssid_3" ]; then
					if [ "$(uci get wireless.$section.lastenable)" = "off" ]; then
						uci set wireless.$section.enable="off"
					elif [ "$(uci get wireless.$section.lastenable)" = "on" ];then
						uci set wireless.$section.enable="on"
					fi
				else
					local lastenable="$(uci get wireless.$section.enable)"
					uci set wireless.$section.enable=$2
					uci set wireless.$section.lastenable="$lastenable"
				fi
			fi
		fi
	else
		if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$backhaul" -a -z "$onemesh_config" -a -z "$mlo_host" ]; then
			if [ "$2" = "on" ] && [ "$multi_ssid_1" -o "$multi_ssid_2" -o "$multi_ssid_3" ]; then
				if [ "$(uci get wireless.$section.lastenable)" = "off" ]; then
					uci set wireless.$section.enable="off"
				elif [ "$(uci get wireless.$section.lastenable)" = "on" ];then
					uci set wireless.$section.enable="on"
				fi
			else
				local lastenable="$(uci get wireless.$section.enable)"
				uci set wireless.$section.enable=$2
				uci set wireless.$section.lastenable="$lastenable"
			fi
		fi
	fi
}

wireless_schedule_get_enable(){
	local section=$1
	local mode=$(uci -q get wireless.$section.mode)
	local guest=$(uci -q get wireless.$section.guest)
	local iot=$(uci -q get wireless.$section.iot)
	local backhaul=$(uci -q get wireless.$section.backhaul)
	local onemesh_config=$(uci -q get wireless.$section.onemesh_config)
	local mlo_host=$(uci -q get wireless.$section.mlo_host)
	local multi_ssid_1=$(uci -q get wireless.$section.multi_ssid_1)
	local multi_ssid_2=$(uci -q get wireless.$section.multi_ssid_2)
	local multi_ssid_3=$(uci -q get wireless.$section.multi_ssid_3)
	
	if [ "$#" -eq "3" ]; then
		if [ "$(uci get wireless.$section.device)" = "$3" ]; then
			if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$backhaul" -a -z "$onemesh_config" -a -z "$mlo_host" ]; then
				if [ "$(uci get wireless.$section.enable)" != "$2" ]; then
					if [ "$2" = "on" ] && [ "$multi_ssid_1" -o "$multi_ssid_2" -o "$multi_ssid_3" ]; then
						if [ "$(uci get wireless.$section.lastenable)" = "on" ]; then
							need_reload="yes"
						fi
					else
						need_reload="yes"
					fi
				fi
			fi
		fi
	else
		if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$backhaul" -a -z "$onemesh_config" -a -z "$mlo_host" ]; then
			if [ "$(uci get wireless.$section.enable)" != "$2" ]; then
					if [ "$2" = "on" ] && [ "$multi_ssid_1" -o "$multi_ssid_2" -o "$multi_ssid_3" ]; then
						if [ "$(uci get wireless.$section.lastenable)" = "on" ]; then
							need_reload="yes"
						fi
					else
						need_reload="yes"
					fi
				fi
		fi
	fi
}

wireless_schedule_set_config_by_band(){
	local section=$1
	local wifi_status=$2
	if [ $wifi_status = "off" ]; then
		local disabled_all="on"
		local enable="off"
		local active="yes"
	else
		local disabled_all="off"
		local enable="on"
		local disabled="off"
		local active="no"
	fi
	config_load wireless
	
	if [ -n "$disabled" ]; then
		uci set wireless.$section.disabled="$disabled"
	fi

	if [ "$#" -eq "3" ]; then
		if [ "$(uci get wireless.$section.band)" = "$3" ]; then
			echo "turn band "$3" to "$wifi_status" now " > $WS_CONSOLE
			uci set wireless_schedule.$3.active="$active"
			uci set wireless.$section.disabled_all="$disabled_all"
			config_foreach wireless_schedule_set_enable wifi-iface $enable $section
			uci commit wireless_schedule
			uci commit wireless
			uci_commit_flash
		fi
	else
		# only stop or skip will goto this condition
		local band=$(uci get wireless.$section.band)
		if [ "$wifi_status" = "on" ] && [ "$(uci get wireless_schedule.$band.active)" = "no" ]; then
			echo "this band "$band" is not disable by wireless schedule, no need to open it" > $WS_CONSOLE
			return
		fi
		echo "turn band "$band" to "$wifi_status" now " > $WS_CONSOLE
		uci set wireless_schedule.$band.active="$active"
		uci set wireless.$section.disabled_all="$disabled_all"
		config_foreach wireless_schedule_set_enable wifi-iface $enable
		uci commit wireless_schedule
		uci commit wireless
		uci_commit_flash
	fi
}

wireless_schedule_get_config_by_band(){
	local section=$1
	local wifi_status=$2
	if [ $wifi_status = "off" ]; then
		local disabled_all="on"
		local enable="off"
	else
		local disabled_all="off"
		local enable="on"
	fi
	config_load wireless
	if [ "$#" -eq "3" ]; then
		if [ "$(uci get wireless.$section.band)" = "$3" ]; then
			config_foreach wireless_schedule_get_enable wifi-iface $enable $section
		fi
	else
		config_foreach wireless_schedule_get_enable wifi-iface $enable
	fi
}

wireless_schedule_reload_wifi() {
	local band=$1
	local time=

	case $band in
		2g)  time=2 ;;
		5g)  time=3 ;;
		5g_2) time=4 ;;
		6g)  time=5 ;;
		*)   time=1 ;;
	esac
	sleep $time
	
	uci_toggle_state wireless_schedule changed "" "yes"

	local changed=$(uci_get_state wireless_schedule changed)
	if [ "$changed" = "yes" ]; then
		uci_toggle_state wireless_schedule changed "" "no"
		echo "Reload wifi" > $WS_CONSOLE

		local support_easymesh=$(uci get profile.@onemesh[0].easymesh_support -c "/etc/profile.d" -q)
		local support_onemesh=$(uci get profile.@onemesh[0].onemesh_support -c "/etc/profile.d" -q)
		if [ "$support_easymesh" = "yes" ]; then
			lua -e 'require("luci.controller.admin.easymesh").sync_wifi_all()'
		elif [ "$support_onemesh" = "yes" ]; then
			lua -e 'require("luci.controller.admin.onemesh").sync_wifi_all()'
		fi

		/sbin/wifi reload &
	fi
}

#When the set time is reached, turn off the WiFi by calling this function
#input:band information such as: 2g 5g
wireless_schedule_handle_active() {
	local band="$1"
	config_load wireless_schedule
	config_get next_time "$band" next_time
	if [ "$next_time" = "on" ]; then
		echo "wireless_schedule_handle_active: next_time = on do nothing " > $WS_CONSOLE
		return 
	else
		echo "wireless_schedule_handle_active: active !!!!!!!!!!!!!!!!!" > $WS_CONSOLE
	fi
	
	local support_triband=$(uci get profile.@wireless[0].support_triband -c "/etc/profile.d") or "no"
	local support_fourband=$(uci get profile.@wireless[0].support_fourband -c "/etc/profile.d" -q)
	local support_6g=$(uci get profile.@wireless[0].support_6g -c "/etc/profile.d" -q)

	local active_2g=$(uci -q get wireless_schedule.2g.active)
	local active_5g=$(uci -q get wireless_schedule.5g.active)
	local active_5g_2="no"
	local active_6g="no"
	if [ $support_fourband = "yes" ] || [ $support_triband = "yes" -a $support_6g != "yes" ]; then
		active_5g_2=$(uci -q get wireless_schedule.5g_2.active)
	fi
	if [ $support_6g = "yes" ]; then
		active_6g=$(uci -q get wireless_schedule.6g.active)
	fi

	if [ -e "/etc/config/eco_mode" ]; then
		if [ "$active_2g" = "no" ] && [ "$active_5g" = "no" ] && [ "$active_5g_2" = "no" ] && [ "$active_6g" = "no" ]; then
			local cur_time=$(cat /proc/uptime | awk  '{printf "%.0f\n", $1}')
			uci_toggle_state wireless_schedule stat active_start_time "$cur_time"
		fi
	fi
	
	config_load wireless
	config_foreach wireless_schedule_get_config_by_band wifi-device "off" "$band"
	if [ "$need_reload" = "yes" ]; then
		config_foreach wireless_schedule_set_config_by_band wifi-device "off" "$band"
		wireless_schedule_reload_wifi "$band"
	else
		uci set wireless_schedule.$band.active="yes"
		uci commit wireless_schedule
		echo "The WiFi "$1" is off, nothing need to do" > $WS_CONSOLE
		return
	fi
}

#When exiting the set time, turn on the WiFi by calling this function
#input:band information such as: 2g 5g or stop
wireless_schedule_handle_dorm() {	
	local support_triband=$(uci get profile.@wireless[0].support_triband -c "/etc/profile.d") or "no"
	local support_fourband=$(uci get profile.@wireless[0].support_fourband -c "/etc/profile.d" -q)
	local support_6g=$(uci get profile.@wireless[0].support_6g -c "/etc/profile.d" -q)
	
	if [ "$1" = "stop" ] || [ "$1" = "skip" ]; then
		echo "Stop/Skip wireless schedule,turn on all wifi disable by wireless schedule" > $WS_CONSOLE

		uci set wireless_schedule.2g.next_time="off"
		uci set wireless_schedule.5g.next_time="off"
		uci -q set wireless_schedule.52g.next_time="off"
		uci -q set wireless_schedule.6g.next_time="off"
		
		config_load wireless_schedule
		config_get wifi_schedule_duration stat wifi_schedule_duration
		local active_start_time=$(uci -P /tmp/state get wireless_schedule.stat.active_start_time)
		if [ -e "/etc/config/eco_mode" ]; then
			if [ $active_start_time != "0" ] && [ -n "$active_start_time" ]; then
				local cur_time=$(cat /proc/uptime | awk  '{printf "%.0f\n", $1}')
				if [ $((cur_time-active_start_time)) -gt 0 ]; then
					uci -q set wireless_schedule.stat.wifi_schedule_duration=$(((cur_time-active_start_time)/60+wifi_schedule_duration))
				fi
				uci_toggle_state wireless_schedule stat active_start_time 0
			fi
		fi
		uci commit wireless_schedule

		config_load wireless
		config_foreach wireless_schedule_get_config_by_band wifi-device "on"
		if [ "$need_reload" = "yes" ]; then
			config_foreach wireless_schedule_set_config_by_band wifi-device "on"
			wireless_schedule_reload_wifi
			return
		else
			echo "all WiFi is on, nothing need to do" > $WS_CONSOLE
			return
		fi
	fi
	
	local band=$1
	config_load wireless_schedule
	config_get next_time "$band" next_time
	if [ "$next_time" = "on" ]; then
		echo "wireless_schedule_handle_dorm: next_time = on, next_time from on to off" > $WS_CONSOLE
		uci set wireless_schedule."$band".next_time="off"
	fi
	if [ "$band" = "2g" ]; then
		local active_2g="no"
		local active_5g=$(uci -q get wireless_schedule.5g.active)
		local active_5g_2="no"
		local active_6g="no"
		if [ $support_fourband = "yes" ] || [ $support_triband = "yes" -a $support_6g != "yes" ]; then
			active_5g_2=$(uci -q get wireless_schedule.5g_2.active)
		fi
		if [ $support_6g = "yes" ]; then
			active_6g=$(uci -q get wireless_schedule.6g.active)
		fi
	elif [ "$band" = "5g" ]; then
		local active_2g=$(uci -q get wireless_schedule.2g.active)
		local active_5g="no"
		local active_5g_2="no"
		local active_6g="no"
		if [ $support_fourband = "yes" ] || [ $support_triband = "yes" -a $support_6g != "yes" ]; then
			active_5g_2=$(uci -q get wireless_schedule.5g_2.active)
		fi
		if [ $support_6g = "yes" ]; then
			active_6g=$(uci -q get wireless_schedule.6g.active)
		fi
	elif [ "$band" = "5g_2" ]; then
		local active_2g=$(uci -q get wireless_schedule.2g.active)
		local active_5g=$(uci -q get wireless_schedule.5g.active)
		local active_5g_2="no"
		local active_6g="no"
		if [ $support_6g = "yes" ]; then
			active_6g=$(uci -q get wireless_schedule.6g.active)
		fi
	elif [ "$band" = "6g" ]; then
		local active_2g=$(uci -q get wireless_schedule.2g.active)
		local active_5g=$(uci -q get wireless_schedule.5g.active)
		local active_5g_2="no"
		local active_6g="no"
		if [ $support_fourband = "yes" ] || [ $support_triband = "yes" -a $support_6g != "yes" ]; then
			active_5g_2=$(uci -q get wireless_schedule.5g_2.active)
		fi
	else
		echo "not support other band" >/dev/console
		return
	fi
	local active_start_time=$(uci -P /tmp/state get wireless_schedule.stat.active_start_time)
	local wifi_schedule_duration=$(uci -q get wireless_schedule.stat.wifi_schedule_duration)
	if [ -e "/etc/config/eco_mode" ]; then
		if [ "$active_2g" = "no" ] && [ "$active_5g" = "no" ] && [ "$active_5g_2" = "no" ] && [ "$active_6g" = "no" ] && [ "$active_start_time" != "0" ] && [ -n "$active_start_time" ]; then
			local cur_time="$(cat /proc/uptime | awk  '{printf "%.0f\n", $1}')"
			if [ $((cur_time-active_start_time)) -gt 0 ]; then
				uci -q set wireless_schedule.stat.wifi_schedule_duration=$(((cur_time-active_start_time)/60+wifi_schedule_duration))
			fi
			uci_toggle_state wireless_schedule stat active_start_time 0
		fi
	fi
	uci commit wireless_schedule
	
	config_load wireless
	config_foreach wireless_schedule_get_config_by_band wifi-device "on" $band
	if [ "$need_reload" = "yes" ]; then
		config_foreach wireless_schedule_set_config_by_band wifi-device "on" $band
		wireless_schedule_reload_wifi $band
	else
		uci set wireless_schedule.$band.active="no"
		echo "The WiFi "$1" is on, nothing need to do" > $WS_CONSOLE
		return
	fi
}
