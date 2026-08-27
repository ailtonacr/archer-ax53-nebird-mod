#!/bin/sh
#
# Copyright (c) 2014 TP-LINK Technologies Co., Ltd.
#
# All Rights Reserved.
#
. /lib/debug/dbg

#
#include file
#
. /lib/wifi/qca_wlan_var.sh
. /lib/wifi/qca_wlan_extend.sh

PORTALSET="0"
PORTAL_IFNAMES=0

##
## Called by /sbin/wifi
##
init_all_vif_name() {
	echo "init_all_vif_name" >$STDOUT
	echo "DEVICES=${DEVICES}" >$STDOUT
	local temp_band=""
	for dev in ${DEVICES}; do
		echo "dev=${dev}" >$STDOUT
			config_get band "${dev}" band
			config_get vifs "${dev}" vifs
			for vif in $vifs; do
				config_get mode $vif mode
				config_get guest $vif guest
				config_get iot $vif iot
				config_get backhaul $vif backhaul
				config_get multi_ssid_1 $vif multi_ssid_1
				config_get ifname $vif ifname
				config_get onemesh_config $vif onemesh_config
				if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$backhaul" -a -z "$onemesh_config" -a -z "$multi_ssid_1" ]; then
					VIF_HOME=${vif}
					NAME_HOME=${ifname}
				elif [ "$mode" = "ap" -a "$guest" != "" ]; then
					VIF_GUEST=${vif}
					NAME_GUEST=${ifname}
				elif [ "$mode" = "ap" -a "$iot" != "" ]; then
					VIF_IOT=${vif}
					NAME_IOT=${ifname}
				elif [ "$mode" = "ap" -a "$backhaul" != "" ]; then
					VIF_BACKHAUL=${vif}
					NAME_BACKHAUL=${ifname}
				elif [ "$mode" = "sta" ]; then
					VIF_WDS=${vif}
					NAME_WDS=${ifname}
				elif [ "$mode" = "ap" -a "$onemesh_config" != "" ]; then
					VIF_RTORCFG=${vif}
					NAME_RTORCFG=${ifname}
				else
					echo "=====>>>>> $dev: vif $vif skipped" >$STDOUT
				fi
			done
			case "$band" in
				2g)
					temp_band="2G"
				;;
				5g)
					temp_band="5G"
				;;
				5g_2)
					temp_band="5G2"
				;;
			esac
			
			eval VIF_HOME_${temp_band}=${VIF_HOME}
			eval VIF_GUEST_${temp_band}=${VIF_GUEST}
			eval VIF_IOT_${temp_band}=${VIF_IOT}
			eval VIF_BACKHAUL_${temp_band}=${VIF_BACKHAUL}
			eval VIF_WDS_${temp_band}=${VIF_WDS}
			eval VIF_RTORCFG_${temp_band}=${VIF_RTORCFG}
			
			eval NAME_HOME_${temp_band}=${NAME_HOME}
			eval NAME_GUEST_${temp_band}=${NAME_GUEST}
			eval NAME_IOT_${temp_band}=${NAME_IOT}
			eval NAME_BACKHAUL_${temp_band}=${NAME_BACKHAUL}
			eval NAME_WDS_${temp_band}=${NAME_WDS}
			eval NAME_RTORCFG_${temp_band}=${NAME_RTORCFG}

			eval DEVICE_${temp_band}=${dev}
	done
}

sysctl_cmd() {
	tpdbg "sysctl -w $1=$2"

	sysctl -w $1=$2 >/dev/null 2>/dev/null
}

wifi_fixup_encryption() {
	case "$(config_get "$1" encryption)" in
		none)
			config_set "$1" encryption none
			;;
		psk|psk2)
			local psk="mixed-psk" enc="tkip+ccmp"
			local psk_key psk_version psk_cipher
			config_get psk_key "$1" psk_key
			config_get psk_version "$1" psk_version
			config_get psk_cipher "$1" psk_cipher
			[ "$psk_version" = "wpa" ] && psk="psk"
			[ "$psk_version" = "wpa2" -o "$psk_version" = "rsn" ] && psk="psk2"
			[ "$psk_cipher" = "aes" -o "$psk_cipher" = "ccmp" ] && enc="ccmp"
			[ "$psk_cipher" = "tkip" ] && enc="tkip" && config_set "$1" puren 0
			[ "$enc" = "tkip" -o "$psk" = "psk" ] && config_set "$1" wps 0
			config_set "$1" encryption "$psk"+"$enc"
			config_set "$1" key "$psk_key"
			config_set "$1" wps_state 2
			;;
		#[lixiangkui start] For WPA3 support
		psk_sae)
			local psk_key psk_version
			config_get psk_key "$1" psk_key
			config_get psk_version "$1" psk_version

			config_set "$1" sae on
			if [ "$psk_version" = "sae_only" ]; then
				config_set "$1" encryption "ccmp"
				config_set "$1" wps 0
			else
				config_set "$1" encryption "psk2+ccmp"
			fi
			config_set "$1" key "$psk_key"
			config_set "$1" sae_password "$psk_key"
			config_set "$1" sae_groups 19
			config_set "$1" wps_state 2
			;;
		#[lixiangkui end]
		wpa)
			local wpa="mixed-wpa" enc="tkip+ccmp"
			local wpa_key wpa_version wpa_cipher
			config_get wpa_key "$1" wpa_key
			config_get wpa_version "$1" wpa_version
			config_get wpa_cipher "$1" wpa_cipher
			[ "$wpa_version" = "wpa" ] && wpa="wpa"
			[ "$wpa_version" = "wpa2" -o "$wpa_version" = "rsn" ] && wpa="wpa2"
			[ "$wpa_cipher" = "aes" -o "$wpa_cipher" = "ccmp" ] && enc="ccmp"
			[ "$wpa_cipher" = "tkip" ] && enc="tkip" && config_set "$1" puren 0
			#[ "$enc" = "tkip" -o "$wpa" = "wpa" ] && config_set "$1" wps 0
			config_set "$1" wps 0
			config_set "$1" encryption "$wpa"+"$enc"
			config_set "$1" key "$wpa_key"
			;;
		wep)
			local enc="wep-mixed" wep_key wep_mode wep_select
			config_get wep_mode "$1" wep_mode
			config_get wep_select "$1" wep_select 1
			config_get wep_key "$1" wep_key"$wep_select"
			[ "$wep_mode" = "1" -o "$wep_mode" = "open" ] && enc="wep-open"
			[ "$wep_mode" = "2" -o "$wep_mode" = "shared" ] && enc="wep-shared"
			for i in 1 2 3 4; do config_set "$1" key$i ""; done
			config_set "$1" key$wep_select $(prepare_key_wep "$wep_key")
			config_set "$1" encryption "$enc"
			config_set "$1" key "$wep_select"
			config_set "$1" puren 0
			config_set "$1" wps 0
			;;
	esac
}

wifi_fixup_mode() {
	local dev="$1" hwmode htmode channel chwidth=0 tpscale=0
	local pureg=0 puren=0 pure11ac=0 pure11ax=0 deny11ab=0 disablecoext=0
	local devcfg="hwmode txpower tpscale htmode channel"
	local dyncfg="pureg puren pure11ac pure11ax deny11ab chwidth disablecoext"
	local vapcfg="rts frag dtim_period wpa_group_rekey wmm shortgi isolate bintval"
	local countrycode=""

	for cfg in $devcfg $vapcfg; do	config_get "$cfg" "$dev" "$cfg";	done;
	[ "$rts" -lt "2346" ] || rts="off"

	case $hwmode in
		b)  hwmode=11b;  htmode="";;
		g)  hwmode=11g;  htmode=""; pureg=1;;
		n)  hwmode=11ng; puren=1;;
		bg) hwmode=11bg; htmode="";;
		gn) hwmode=11ng; deny11ab=1;;
		bgn) hwmode=11ng;;
		ax) hwmode=11axg; pure11ax=1;;
		bgnax) hwmode=11axg;;
		a_5) hwmode=11a; htmode="";;
		n_5) hwmode=11na; puren=1;;
		an_5) hwmode=11na;;
		ac_5) hwmode=11ac; [ "$htmode" = "auto" ] && chwidth=2 && htmode=""; pure11ac=1;;
		nac_5) hwmode=11ac; [ "$htmode" = "auto" ] && chwidth=2 && htmode=""; deny11ab=1;;
		anac_5) hwmode=11ac; [ "$htmode" = "auto" ] && chwidth=2 && htmode="";;
		ax_5) hwmode=11axa; [ "$htmode" = "auto" ] && chwidth=2 && htmode=""; pure11ax=1;;
		anacax_5) hwmode=11axa; [ "$htmode" = "auto" ] && chwidth=2 && htmode="";;
		
	esac

	case $txpower in
		low)  txpower=""; tpscale=2;;
		mid*) txpower=""; tpscale=1;;
		high) txpower=""; tpscale=0;;
	esac

	case $channel in
		auto)channel=0;;
		116)
			countrycode=`getfirm COUNTRY`
			if [ "$countrycode" = "CA" ]; then
				if [ "$htmode" = "" ]; then
					#for AX55CA, donot support ch 120-128
					#so ch116 donot support 80M, 40M
					htmode=20
				fi
			fi
		;;
		132|136)
			countrycode=`getfirm COUNTRY`
			if [ "$countrycode" = "DE" ]; then
				if [ "$htmode" = "" ]; then
					#for AX55EU, donot support ch 144
					#so ch132-140 donot support 80M
					#ch140 donnot support 40M
					htmode=40
				fi
			fi
		;;
		140)
			countrycode=`getfirm COUNTRY`
			if [ "$countrycode" = "DE" ]; then
				if [ "$htmode" = "" ]; then
					#for AX55EU, donot support ch 144
					#so ch132-140 donot support 80M
					#ch140 donnot support 40M
					htmode=20
				fi
			fi
		;;
		165)
			if [ "$htmode" = "" ]; then
				htmode=20
			fi
		;;
	esac

	# if uci set Channel Width=Auto, here htmode=auto in 2G, htmode="" in 5G
	case $htmode in
		auto)chwidth=1; htmode=HT40;;
		20)  chwidth=0; htmode=HT20;;
		40)  chwidth=1; htmode=HT40; disablecoext=1;;
		80)  chwidth=2; htmode=HT80; disablecoext=1;;
		160) chwidth=3; htmode=HT160; disablecoext=1;;
		*)   chwidth=2; htmode=HT80; disablecoext=1;; # htmode="", 80M default in 5G
	esac

	for cfg in $devcfg; do eval config_set "$dev" "$cfg" $"$cfg";	done
		
	config_get bintval "$dev" beacon_int 100
	config_get_bool mu_mimo "$dev" mu_mimo 1
	for vif in $(config_get "$dev" vifs); do 
		config_get isolate "$vif" isolate "$isolate"
		config_set "$vif" vhtmubfer $mu_mimo
		config_set "$vif" vhtmubfee $mu_mimo
		#[ "$hwmode" = "11ng" ] && config_set "$vif" vht_11ng 1
		for cfg in $dyncfg $vapcfg; do eval config_set "$vif" "$cfg" $"$cfg";	done
	done
}

config_access_ctl()
{
	type ac &>/dev/null || return

	local tmp_enable tmp_mode   
	tmp_enable=$(ac get_enable) 
	[ "$tmp_enable" = "on" ] && {
		local tmp_action
		tmp_mode=$(ac get_mode)
		case $tmp_mode in
			white) tmp_action="allow" ;;
			*)     tmp_action="deny" ;;
		esac

		config_set filter enable $tmp_enable
		config_set filter action $tmp_action
		MACLIST=$(ac get_maclist)
	}
}

wifi_fixup_config() {
	local enable macfilter="deny" wps brname="br-lan"
	local countrycode=`getfirm COUNTRY`

	# MAC Filter from Access Control modules
	config_access_ctl

	config_get_bool enable filter enable 1

	for brname in $(cd /sys/class/net && ls -d br-lan* 2>$STDOUT); do break; done
	
	if [ "$enable" = "1" ]; then 
		MACLIST=${MACLIST//-/:};
		config_get macfilter filter action "deny"
	else
		unset MACLIST
	fi

	config_set qcawifi fw_dump_options 5 # FW crash ram dump

	#temporarily added for atf
	atf_support=0
	for dev in ${1:-DEVICES}; do
		wifi_fixup_mode "$dev"
		
		config_set "$dev" enable_ol_stats 1 # Enable ol stats

		config_get band "$dev" band
		config_get_bool airtime_fairness "$dev" airtime_fairness 0
		# block dfs channel will prevent radio from 160Mhz
		#[ "$band" = "5g" ] && config_set "$dev" blockdfslist 1 # Disable DFS channels

		for vif in $(config_get "$dev" vifs); do 
			config_get mode "$vif" mode
			config_get_bool hidden "$vif" hidden 0
			config_get_bool enable "$vif" enable 0
			#config_set "$vif" vhtmubfer 1
			#config_set "$vif" vhtmubfee 1

			# fixup encryption
			wifi_fixup_encryption "$vif"

			config_get_bool wps "$vif" wps 0
			config_get_bool wps_label "$vif" wps_label 0
			[ "$wps" = "1" ] && {
				local c v wpscfg="wps_uuid wps_device_type wps_device_name wps_manufacturer wps_manufacturer_url \
													model_name model_number model_url serial_number os_version"
				for c in $wpscfg; do
					config_get v wps "$c"
					config_set "$vif" "$c" "$v"
				done
				[ "$band" = "2g" ] && config_set "$vif" wps_rf_bands g
				[ "$band" = "5g" -o "$band" = "5g_2" ] && config_set "$vif" wps_rf_bands a
			}
			if [ "$wps" = "0" -o "$hidden" = "1" ]; then
				config_set "$vif" wps_pbc ""
			elif [ "$wps_label" = "1" ]; then
				config_set "$vif" wps_config "label"
			else
				config_set "$vif" wps_config ""
				config_set "$vif" wps_pin ""
			fi

			config_set "$vif" disabled "$((enable^1))"
			config_set "$vif" disabled_all "$((enable^1))"
			config_set "$vif" network lan
			config_set "$vif" bridge "${brname:-br-lan}"
			config_set "$vif" mcastenhance 2
			#[ "$band" = "5g" ] && config_set "$vif" amsdu 2

			if [ "$mode" = "ap" ]; then
				config_set "$vif" macfilter "$macfilter"
				config_set "$vif" maclist "$MACLIST"
				config_set "$vif" countryie 1

				if [ "$band" = "2g" ]; then
					config_set "$vif" ignore11d 1
				else
					config_set "$vif" ldpc 1
				fi
			else
				config_get bssid "$vif" bssid
				local easymesh_support=`uci get profile.@onemesh[0].easymesh_support -c /etc/profile.d/ -q`
				if [ "yes" = "$easymesh_support" ]; then
					config_get extap "$vif" wds_mode 2
					config_set "$vif" extap "$extap"
				fi
				config_set "$vif" bssid "${bssid//-/:}"
				config_set "$vif" bintval ""
				config_set "$vif" dtim_period ""
				config_set "$vif" macfilter ""
				config_set "$vif" maclist ""
			fi
			
			#atf support
			if [ "$airtime_fairness" = "1" ]; then
				config_set "$vif" atf "on"
				atf_support=1
			else
				config_set "$vif" atf "off"
			fi

		done
	done
	config_get_bool atf_mode qcawifi atf_mode
        if [ "$atf_mode" != "$atf_support" ]; then
		config_set qcawifi atf_mode ${atf_support}
		uci set wireless.qcawifi.atf_mode=${atf_support}
		wifi_commit
	fi
}

config_country() {
	local country blockdfs
	config_get country "$1" country US
	config_get band "$1" band
	config_get_bool blockdfs "$1" blockdfslist 0
	
	if [ "$blockdfs" = "1" ];then
		local dfs_countrylist="JP 4057"
		local dfs_enable=0
		local c

		for c in $dfs_countrylist
		do
			if [ "$c" = "$country" ];then
				dfs_enable=1
				break
			fi
		done
		if [ "$dfs_enable" = "0" ];then
			cfg80211tool "$1" blockdfslist "$blockdfs"
		fi
	fi

	if [ "$country" = "RU" -o "$country" = "643" ];then
		if [ "$band" = "2g" ];then
			country="DE"
		else
			country="US"
		fi
	fi

	if [ "$country" = "UN" ];then
		country="UG"
	fi

	if [ "$country" = "SG" -o "$country" = "702" ];then
		country="US"
	fi

	if [ "$(getfirm MODEL)" = "Archer GE800" -a "$(getfirm HARDVERSION)" = "1.0.0" ] || \
	   [ "$(getfirm MODEL)" = "Archer AX53" -a "$(getfirm HARDVERSION)" = "2.0.0" ] || \
	   [ "$(getfirm MODEL)" = "Archer Air R5" -a "$(getfirm HARDVERSION)" = "1.0.0" ] || \
	   [ "$(getfirm MODEL)" = "Archer AX72 Pro" -a "$(getfirm HARDVERSION)" = "1.0.0" ] || \
	   [ "$(getfirm MODEL)" = "Archer AX72" -a "$(getfirm HARDVERSION)" = "1.0.0" ] && \
	   [ "$country" = "KR" -o "$country" = "410" ];then
			country="US"
	fi

	if [ `expr "$country" : '[0-9].*'` -ne 0 ]; then
		cfg80211tool "$1" setCountryID "$country"
	elif [ -n "$country" ]; then
		cfg80211tool "$1" setCountry "$country"
	fi
	rm -f /var/state/wireless
}

config_olcfg() {
	local board_name
	[ -f /tmp/sysinfo/board_name ] && {
		board_name=ap$(cat /tmp/sysinfo/board_name | awk -F 'ap' '{print$2}')
	}

	config_get nss_wifi_olcfg qcawifi nss_wifi_olcfg

	if [ -z "$nss_wifi_olcfg" ]; then
		if [ -f /lib/wifi/wifi_nss_olcfg ]; then
			nss_wifi_olcfg="$(cat /lib/wifi/wifi_nss_olcfg)"
		fi
	fi

	if [ -n "$nss_wifi_olcfg" ] && [ "$nss_wifi_olcfg" != "0" ]; then
		local mp_256="$(ls /proc/device-tree/ | grep -rw "MP_256")"
		local mp_512="$(ls /proc/device-tree/ | grep -rw "MP_512")"
		config_get hwmode "$1" hwmode auto
		hk_ol_num="$(cat /lib/wifi/wifi_nss_hk_olnum)"
		#For 256 memory profile the range is preset in fw
		if [ "$mp_256" == "MP_256" ]; then
			:
		elif [ "$mp_512" == "MP_512" ]; then
			if [ $hk_ol_num -eq 3 ]; then
				if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
					touch /tmp/wifi_nss_up_one_radio
					sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 31648
					sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 0
				fi
				case "$hwmode" in
				*axa | *ac)
					cfg80211tool "$1" fc_buf0_max 4096
					cfg80211tool "$1" fc_buf1_max 4096
					cfg80211tool "$1" fc_buf2_max 4096
					cfg80211tool "$1" fc_buf3_max 4096
					;;
				*)
					cfg80211tool "$1" fc_buf0_max 4096
					cfg80211tool "$1" fc_buf1_max 4096
					cfg80211tool "$1" fc_buf2_max 4096
					cfg80211tool "$1" fc_buf3_max 4096
					;;
				esac
			else
				if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
					touch /tmp/wifi_nss_up_one_radio
					sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 30624
					sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 8192
				fi
				case "$hwmode" in
				*axa | *ac)
					cfg80211tool "$1" fc_buf0_max 8192
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 8192
					cfg80211tool "$1" fc_buf3_max 8192
					;;
				*)
					cfg80211tool "$1" fc_buf0_max 8192
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 8192
					cfg80211tool "$1" fc_buf3_max 8192
					;;
				esac
			fi
		else
			case "$board_name" in
			ap-ac01)
				;;
			ap-ac02)
				case "$hwmode" in
				*axa | *ac)
					cfg80211tool "$1" fc_buf0_max 4096
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 8192
					cfg80211tool "$1" fc_buf3_max 8192
					;;
				*)
					cfg80211tool "$1" fc_buf0_max 4096
					cfg80211tool "$1" fc_buf1_max 4096
					cfg80211tool "$1" fc_buf2_max 4096
					cfg80211tool "$1" fc_buf3_max 4096
					;;
				esac
				;;
			ap-cp*|ap-mp*)
				if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
					touch /tmp/wifi_nss_up_one_radio
					#reset the high water mark for NSS if range 0 value > 4096
					sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 30528
					#initially after init 4k buf for 5G and 4k for 2G will be allocated, later range will be configured
					sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 4096
				fi
				case "$hwmode" in
				*axa | *ac)
					cfg80211tool "$1" fc_buf0_max 8192
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 8192
					cfg80211tool "$1" fc_buf3_max 8192
				;;
				*)
					cfg80211tool "$1" fc_buf0_max 4096
					cfg80211tool "$1" fc_buf1_max 4096
					cfg80211tool "$1" fc_buf2_max 4096
					cfg80211tool "$1" fc_buf3_max 4096
				;;
				esac
				;;
		        ap-hk09*)
				local soc_version_major
				[ -f /sys/firmware/devicetree/base/soc_version_major ] && {
					soc_version_major="$(hexdump -n 1 -e '"%1d"' /sys/firmware/devicetree/base/soc_version_major)"
				}

				if [ $soc_version_major = 2 ];then
					if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
						touch /tmp/wifi_nss_up_one_radio
						#reset the high water mark for NSS if range 0 value > 4096
						sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 67392
						#initially after init 4k buf for 5G and 4k for 2G will be allocated, later range will be configured
						sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 40960
					fi
					case "$hwmode" in
					*axa | *ac)
						cfg80211tool "$1" fc_buf0_max 32768
						cfg80211tool "$1" fc_buf1_max 32768
						cfg80211tool "$1" fc_buf2_max 32768
						cfg80211tool "$1" fc_buf3_max 32768
					;;
					*)
						cfg80211tool "$1" fc_buf0_max 16384
						cfg80211tool "$1" fc_buf1_max 16384
						cfg80211tool "$1" fc_buf2_max 16384
						cfg80211tool "$1" fc_buf3_max 32768
					;;
					esac
				else
					case "$hwmode" in
					*ac)
						#we distinguish the legacy chipset based on the hwcaps
						hwcaps=$(cat /sys/class/net/${phy}/hwcaps)
						if [ "$hwcaps" == "802.11an/ac" ]; then
							cfg80211tool "$1" fc_buf0_max 8192
							cfg80211tool "$1" fc_buf1_max 12288
							cfg80211tool "$1" fc_buf2_max 16384
						else
							cfg80211tool "$1" fc_buf0_max 4096
							cfg80211tool "$1" fc_buf1_max 8192
							cfg80211tool "$1" fc_buf2_max 12288
						fi
						cfg80211tool "$1" fc_buf3_max 16384
						;;
					*)
						cfg80211tool "$1" fc_buf0_max 4096
						cfg80211tool "$1" fc_buf1_max 8192
						cfg80211tool "$1" fc_buf2_max 12288
						cfg80211tool "$1" fc_buf3_max 16384
						;;
					esac
				fi
				;;
			ap-hk* | ap-oak*)
				if [ $hk_ol_num -eq 3 ]; then
					if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
						touch /tmp/wifi_nss_up_one_radio
						sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 72512
						sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 36864
						update_ini_for_hk_sbs QCA8074V2_i.ini
					fi
					case "$hwmode" in
					*axa | *ac)
						cfg80211tool "$1" fc_buf0_max 24576
						cfg80211tool "$1" fc_buf1_max 24576
						cfg80211tool "$1" fc_buf2_max 24576
						cfg80211tool "$1" fc_buf3_max 32768
						;;
					*)
						cfg80211tool "$1" fc_buf0_max 16384
						cfg80211tool "$1" fc_buf1_max 16384
						cfg80211tool "$1" fc_buf2_max 16384
						cfg80211tool "$1" fc_buf3_max 24576
						;;
					esac
				else
					local soc_version_major
					[ -f /sys/firmware/devicetree/base/soc_version_major ] && {
						soc_version_major="$(hexdump -n 1 -e '"%1d"' /sys/firmware/devicetree/base/soc_version_major)"
					}

					if [ ! -f /tmp/wifi_nss_up_one_radio ]; then
						touch /tmp/wifi_nss_up_one_radio
						#reset the high water mark for NSS if range 0 value > 4096
						sysctl_cmd dev.nss.n2hcfg.n2h_high_water_core0 67392
						#initially after init 4k buf for 5G and 4k for 2G will be allocated, later range will be configured
						sysctl_cmd dev.nss.n2hcfg.n2h_wifi_pool_buf 40960
						update_ini_for_hk_dbs QCA8074V2_i.ini
					fi
					case "$hwmode" in
					*axa | *ac)
						if [ $soc_version_major = 2 ];then
							cfg80211tool "$1" fc_buf0_max 32768
							cfg80211tool "$1" fc_buf1_max 32768
							cfg80211tool "$1" fc_buf2_max 32768
							cfg80211tool "$1" fc_buf3_max 32768
						else
							cfg80211tool "$1" fc_buf0_max 8192
							cfg80211tool "$1" fc_buf1_max 8192
							cfg80211tool "$1" fc_buf2_max 12288
							cfg80211tool "$1" fc_buf3_max 32768
						fi
					;;
					*)
						if [ $soc_version_major = 2 ];then
							cfg80211tool "$1" fc_buf0_max 16384
							cfg80211tool "$1" fc_buf1_max 16384
							cfg80211tool "$1" fc_buf2_max 16384
							cfg80211tool "$1" fc_buf3_max 32768
						else
							cfg80211tool "$1" fc_buf0_max 4096
							cfg80211tool "$1" fc_buf1_max 8192
							cfg80211tool "$1" fc_buf2_max 12288
							cfg80211tool "$1" fc_buf3_max 16384
						fi
					;;
					esac
				fi
				;;
			*)
				case "$hwmode" in
				*ng)
					cfg80211tool "$1" fc_buf0_max 5120
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 12288
					cfg80211tool "$1" fc_buf3_max 16384
					;;
				*ac)
					cfg80211tool "$1" fc_buf0_max 8192
					cfg80211tool "$1" fc_buf1_max 16384
					cfg80211tool "$1" fc_buf2_max 24576
					cfg80211tool "$1" fc_buf3_max 32768
					;;
				*)
					cfg80211tool "$1" fc_buf0_max 5120
					cfg80211tool "$1" fc_buf1_max 8192
					cfg80211tool "$1" fc_buf2_max 12288
					cfg80211tool "$1" fc_buf3_max 16384
					;;
				esac
				;;
			esac
		fi
	else
		local mp_512="$(ls /proc/device-tree/ | grep -rw "MP_512")"
		config_get hwmode "$device" hwmode auto
		if [ "$mp_512" == "MP_512" ]; then
			case "$hwmode" in
				*axa | *ac)
					# For 128 clients
					cfg80211tool "$1" fc_buf_max 8192
					;;
				esac
		fi
	fi

	if [ $nss_wifi_olcfg == 0 ]; then
		sysctl_cmd dev.nss.n2hcfg.n2h_queue_limit_core0 2048
		sysctl_cmd dev.nss.n2hcfg.n2h_queue_limit_core1 2048
	else
		sysctl_cmd dev.nss.n2hcfg.n2h_queue_limit_core0 256
		sysctl_cmd dev.nss.n2hcfg.n2h_queue_limit_core1 256
	fi

#	config_tx_fc_buf "$phy"
}

config_acs_block_chan() {
	local vif="$1" phy_dev band countrycode acs_block_chan


	config_get phy_dev "$vif" device
	config_get band "$phy_dev" band

	if [ "$band" = "2g" ]; then
		# Enable overlap channel selection in 2.4GHz band with ACS.
		cfg80211tool "$phy_dev" acs_2g_allch 1 
	fi

	countrycode=`getfirm COUNTRY`
	get_wlan_ini BLOCK_CHAN_${band}_${countrycode}
	acs_block_chan=$(eval echo \${BLOCK_CHAN_${band}_${countrycode}})

	wifitool "$vif" block_acs_channel "${acs_block_chan}"
}

config_cfg80211tool() {
	local b c n v
	for c in $2; do
		b="${c:0:1}" &&	c="${c#\!}" && n="${c%:*}" && c="${c#*:}"
		[ -z "${b#\!}" ] && b="_bool" || b=""
		eval config_get"$b" v "$1" "${n/=/ }"
		[ -n "$v" ] && cfg80211tool "$1" "${c%=*}" $v
	done
}

config_vap_mode() {
	local cfg cfgs="rts frag pureg puren pure11ac pure11ax deny11ab disablecoext vht_11ng"
	local mode="$2" chan="$3" txpower="$4" mode2=""
	for cfg in $cfgs; do config_get "$cfg" "$1" "$cfg";	done
	config_get device "$1" device
        config_get apmode "$1" mode
	case "$mode" in
		11ng:HT20) mode=11NGHT20;;
		11ng:HT40-) mode=11NGHT40MINUS; mode2="11NGHT20";;
		11ng:HT40+) mode=11NGHT40PLUS; mode2="11NGHT20";;
		11ng:*)	mode=11NGHT40; mode2="11NGHT20";;
		11na:HT20) mode=11NAHT20;;
		11na:*) mode=11NAHT40; mode2="11NGHT20";;
		11ac:HT20) mode=11ACVHT20;;
		11ac:HT40*) mode=11ACVHT40; mode2="11ACVHT20";;
		11ac:HT80) mode=11ACVHT80; mode2="11ACVHT40 11ACVHT20";;
		11ac:HT160) mode=11ACVHT160; mode2="11ACVHT80 11ACVHT40 11ACVHT20";;
		11ac:HT80_80) mode=11ACVHT80_80; mode2="11ACVHT80 11ACVHT40 11ACVHT20";;
		11ac:*) mode=""
				#if [ -f /sys/class/net/$device/5g_maxchwidth ]; then
				#	maxchwidth="$(cat /sys/class/net/$device/5g_maxchwidth)"
				#	[ -n "$maxchwidth" ] && mode=11ACVHT$maxchwidth
				#fi
				if [ "$apmode" == "sta" ]; then
					cat /sys/class/net/$device/hwmodes | grep  "11AC_VHT80_80"
					if [ $? -eq 0 ]; then
						mode=11ACVHT80_80
					fi
				fi
				mode2="11ACVHT80 11ACVHT40 11ACVHT20";;
		*ac_5:*) mode=""; mode2="11ACVHT80 11ACVHT40 11ACVHT20";;
		11axg:HT20) mode=11GHE20;;
		11axg:HT40-) mode=11GHE40MINUS; mode2="11GHE20";;
		11axg:HT40+) mode=11GHE40PLUS; mode2="11GHE20";;
		11axg:HT40) mode=11GHE40; mode2="11GHE20";;
		11axg:*) mode=11GHE20;;
		11axa:HT20) mode=11AHE20;;
		11axa:HT40+) mode=11AHE40PLUS; mode2="11AHE20";;
		11axa:HT40-) mode=11AHE40MINUS; mode2="11AHE20";;
		11axa:HT40) mode=11AHE40; mode2="11AHE20";;
		11axa:HT80) mode=11AHE80; mode2="11AHE40 11AHE20";;
		11axa:HT160) mode=11AHE160; mode2="11AHE80 11AHE40 11AHE20";;
		11axa:HT80_80) mode=11AHE80_80; mode2="11AHE80 11AHE40 11AHE20";;
		11axa:*) mode=""
				#if [ -f /sys/class/net/$device/5g_maxchwidth ]; then
				#	maxchwidth="$(cat /sys/class/net/$device/5g_maxchwidth)"
				#	[ -n "$maxchwidth" ] && mode=11AHE$maxchwidth
				#fi
				if [ "$apmode" == "sta" ]; then
					cat /sys/class/net/$device/hwmodes | grep  "11AXA_HE80_80"
					if [ $? -eq 0 ]; then
						mode=11AHE80_80
					fi
				fi
				mode2="11AHE80 11AHE40 11AHE20";;
		11b:*) mode=11B;;
		11bg:*) mode=11G;;
		11g:*) mode=11G;;
		11a:*) mode=11A;;
		*) mode=AUTO;;
	esac
	#cfg80211tool "$1" channel 0 0
	if [ -n "$mode" -o "$chan" = "0" ]; then
		for m in $mode $mode2; do cfg80211tool "$1" mode "$m" && break; done
	else
		for m in $mode2; do
			cfg80211tool "$1" mode "$m" && cfg80211tool "$1" channel "$chan" 0 && break
		done
	fi
	cfg80211tool "$1" pureg "$pureg"
	cfg80211tool "$1" puren "$puren"
	cfg80211tool "$1" pure11ac "$pure11ac"
	cfg80211tool "$1" pure11ax "$pure11ax"
	cfg80211tool "$1" deny11ab "$deny11ab"
	# [ -n "$vht_11ng" ] && cfg80211tool "$1" vht_11ng "$vht_11ng"
	[ -n "$disablecoext" ] && cfg80211tool "$1" disablecoext "$disablecoext"
	[ -n "$frag" ] && iwconfig "$vif" frag "$frag"
	[ -n "$rts" ] && iwconfig "$vif" rts "$rts"
	[ -n "$chan" ] && cfg80211tool "$1" channel "$chan" 0
	# [ -n "$txpower" ] && iwconfig "$1" txpower "$txpower"
}

config_vap_acl() {
	local vif="$1" maclist macfilter stalist
	config_get maclist "$vif" maclist
	config_get macfilter "$vif" macfilter
	cfg80211tool "$vif" maccmd 3
	stalist=`wlanconfig "$vif" list | egrep ".*:.*:" | awk '{print $1}'`	

	for mac in $maclist; do cfg80211tool "$vif" addmac "$mac";	done

	for sta in $stalist;
                do
                        if [ $macfilter = "deny" ]; then
                                echo ${maclist} | grep -iq ${sta} && cfg80211tool $vif kickmac $sta

                        elif [ $macfilter = "allow" ]; then
                                echo ${maclist} | grep -iq ${sta} || cfg80211tool $vif kickmac $sta
                        else
                                echo "macfilter action is not correct!" >$CONSOLE
                        fi
                done

	case "$macfilter" in
		allow) cfg80211tool "$vif" maccmd 1;;
		deny|*)cfg80211tool "$vif" maccmd 2;;
	esac
}

config_vap_vlan() {
	local vlanid=3 gvlan=0
	local sysmode=`uci get sysmode.sysmode.mode`
	if [ "${FEATURE_TRIBAND}" = "y" ]; then
		vlanid=7
	fi

	for brname in $(cd /sys/class/net && ls -d br-lan* 2>$STDOUT); do break; done
	for port in $(brctl show "$brname" | grep eth | cut -f 6-8); do
		if [ "$sysmode" = "ap" ]; then
			brctl setifvlan "$brname" "$port" 0 1
		else
			brctl setifvlan "$brname" "$port" "$vlanid" 1
		fi
	done
	for dev in $DEVICES; do
		for vif in $(config_get "$dev" vifs); do 
			if [ -d /sys/class/net/$vif ]; then
				local fw_action="block"
				config_get brname "$vif" bridge "br-lan"
				config_get phy_dev "$vif" device
				config_get band "$phy_dev" band
				config_get_bool guest "$vif" guest 0
				config_get_bool access "$vif" access 1
				config_get_bool isolate "$vif" isolate 0
				config_get vlankey "$vif" vlanid
				vlanid=3
				[ "${FEATURE_TRIBAND}" = "y" ] && vlanid=7
				
				[ "$guest" = "1" ] && {
					if [ "$access" = "1" ]; then
						gvlan=$((0x1))
					else 
						gvlan=$((0x8))
					fi
					
					if [ "$isolate" = "0" ]; then
						vlanid=$gvlan
					else 
						case "$band" in
							2g) vlanid=$gvlan ;;
							5g) vlanid=$(($gvlan << 1)) ;;
							5g_2) vlanid=$(($gvlan << 2)) ;;
						esac
					fi
				}
				# [ "$vlankey" != "" ] && {
				[ "$vlankey" != "" && "$sysmode" != "multissid" ] && {
					if [ "$vlankey" == "1" ]; then
						vlanid=3
						[ "${FEATURE_TRIBAND}" = "y" ] && vlanid=7
					else
						vlanid=$((1 << $vlankey ))
					fi
				}
				brctl addif "$brname" "$vif"
				brctl setifvlan "$brname" "$vif" "$vlanid" 1
				#ubus call network.interface.lan add_device "{\"name\":\"$vif\"}"

				# FW Replaced by br-filter control
				#[ "$guest" = "1" ] && fw "$fw_action"_rt_access dev "$vif" &
				[ "$guest" = "1" ] && echo "$access" > /proc/bridge_filter/local_access_flag

				[ "$1" = "up" ] && ifconfig "$vif" up
			fi
		done
	done

	
	if [ "$sysmode" = "multissid" ]; then
		for dev in $DEVICES; do
			for vif in $(config_get "$dev" vifs); do 
				if [ -d /sys/class/net/$vif ]; then
					config_get vlanid "$vif" vlanid
					brctl setifvlan "$brname" "$vif" 1
					vidath="$vidath $vif=$vlanid"
					
					[ "$1" = "up" ] && ifconfig "$vif" up 
				fi
			done
		done	
		echo "$vidath"

		lsmod | grep MultiSsidVlan > /dev/null
		[ $? == 1 ] && {
			insmod /lib/modules/iplatform/br_MultiSsidVlan_InputForward.ko lan_port_names=eth1
			insmod /lib/modules/iplatform/br_MultiSsidVlan_PassUpToRouter.ko
		}
		
		ap-vlanc $vidath
		unset vidath
	else
		lsmod |grep MultiSsidVlan > /dev/null
		[ $? == 0 ] && {
			rmmod br_MultiSsidVlan_InputForward.ko
			rmmod br_MultiSsidVlan_PassUpToRouter.ko
		}
	fi
}

destroy_vap() {
	config_get brname "$1" bridge "br-lan"
	brctl setifvlan "$brname" "$1" 0 0
	/usr/sbin/wlanconfig "$1" destroy
}

create_vap() {
	local vif="$1" dev="$2" mode="$3"
	local b c v n
	local cfg="!shortgi !wds=1 TxBFCTL !countryie !uapsd=1 powersave !ant_ps_on ps_timeout \
			metimer metimeout !medropmcast me_adddeny vap_ind scanband periodicScan cwmin cwmax aifs \
			txoplimit noackpolicy !wmm !doth !ignore11d doth_chanswitch quiet mfptest noedgech ps_on_time inact !wnm ampdu amsdu maxampdu vhtmaxampdu \
			setaddbaoper addbaresp addba delba !stafwd nss vhtmcs vht_mcsmap chbwmode !ldpc rx_stbc tx_stbc cca_thresh set11NRates set11NRetries \
			chanbw maxsta sko_max_xretries:sko extprotmode extprotspac !cwmenable !protmode enablertscts txcorrection rxcorrection \
			tdls set_tdls_rmac tdls_qosnull tdls_uapsd tdls_set_rcpi:set_rcpi tdls_set_rcpi_hi:set_rcpihi tdls_set_rcpi_lo:set_rcpilo \
			tdls_set_rcpi_margin:set_rcpimargin tdls_dtoken do_tdls_dc_req tdls_auto tdls_off_timeout:off_timeout tdls_tdb_timeout:tdb_timeout \
			tdls_weak_timeout:weak_timeout tdls_margin tdls_rssi_ub tdls_rssi_lb tdls_path_sel:tdls_pathSel tdls_rssi_offset:tdls_rssi_o \
			tdls_path_sel_period:tdls_pathSel_p tdlsmacaddr1 tdlsmacaddr2 tdlsaction tdlsoffchan tdlsswitchtime tdlstimeout tdlsecchnoffst tdlsoffchnmode \
			!blockdfschan dbgLVL acsmindwell acsmaxdwell acsreport ch_hop_en ch_long_dur ch_nhop_dur ch_cntwn_dur ch_noise_th ch_cnt_th !scanchevent \
			!send_add_ies !ext_ifu_acs !rrm !rrmslwin !rrmstats rrmdbg acparams setwmmparams !qbssload !proxyarp !l2tif !dgaf_disable setibssdfsparam \
			startibssrssimon setibssrssihyst noIBSSCreate setibssrssiclass offchan_tx_test implicitbf vhtsubfee vhtmubfee vhtsubfer vhtmubfer vhtstscap vhtsounddim \
			encap_type decap_type rawsim_txagr clr_rawsim_stats rawsim_debug dtim_period"

	### Delete backhual interface when OneMesh and EasyMesh are both off
	config_get backhaul "$vif" backhaul
	local onemesh_enable=`uci get meshd.meshd.enableonemesh`
	local easymesh_enable=`uci get meshd.meshd.enableeasymesh`
	local sysmode=`uci get sysmode.sysmode.mode`

	[ -z "$onemesh_enable" ] && onemesh_enable=`uci get onemesh.onemesh.enable`
	[ -z "$onemesh_enable" ] && onemesh_enable="off"
	[ -z "$easymesh_enable" ] && easymesh_enable="off"
	[ -z "$sysmode" ] && sysmode="router"

	if [ "$backhaul" = "on" -a "$onemesh_enable" != "on" -a "$easymesh_enable" != "on" ]; then
		[ -d /sys/class/net/$vif ] && destroy_vap "$vif"
		return 0
	fi

	local wlanmode
	[ "$mode" = "ap" ] && wlanmode="__ap"
	[ "$mode" = "sta" ] && wlanmode="managed"
	[ "$mode" = "lite_monitor" ] && wlanmode="monitor"
	[ "$mode" = "ap_monitor" ] && wlanmode="__ap"
	[ "$mode" = "ap_smart_monitor" ] && wlanmode="__ap"
	[ "$mode" = "ap_lp_iot" ] && wlanmode="__ap"
	[ "$mode" = "mesh" ] && wlanmode="__ap"
	[ "$mode" = "wrap" ] && wlanmode="__ap"

	local vapid=$(echo "$vif" | tr -cd "[0-9]" | awk '{print int(substr($1, 2))}')
	local VAP_ID_MASK=15
	local VAP_MAX_PREALLOC_ID=$(expr "(" $VAP_ID_MASK + 1 ")" / 2 )
	
	vapid=$(expr "(" $vapid + $VAP_MAX_PREALLOC_ID ")" % "(" $VAP_ID_MASK + 1 ")" )

	[ -d /sys/class/net/$vif ] || [ "$vif" = "$(/usr/sbin/wlanconfig "$vif" create wlandev "$dev" wlanmode "$mode" nosbeacon vapid "$vapid" -cfg80211)" ] || return 0  
	[ -d /sys/class/net/$vif ] || iw phy "$(cat /sys/class/net/$dev/phy80211/name)" interface add $vif type $wlanmode

	config_get band "$dev" band
	[ "$sysmode" == "repeater" -o "$sysmode" == "client" ]  && {
		if [ "$band" == "5g" ];then
			iwpriv "$vif" set_ignore_cac 1
		else
			iwpriv "$vif" set_ignore_cac 0
		fi
	}

	tpdbg "create_vap $vif created."
	config_get channel "$dev" channel 0
	config_get hwmode "$dev" hwmode auto
	config_get htmode "$dev" htmode auto
	config_get txpower "$dev" txpower
	config_get band "$dev" band

	### for Onemsh
	### 1. add TPIE
	### 2. set 11k/11v status
	config_get mode "$vif" mode
	config_get guest "$vif" guest
	config_get onemesh_config "$vif" onemesh_config
	config_get onemesh_ie "$vif" onemesh_ie
	config_get iot "$vif" iot

	#  Add TPIE
	#  1. only for Host & Backhual Netork
	#  2. onemesh or easymesh should be enabled
	local tpie_level=00
	local tpie_subnet_type=01 #AP
	local backhaul_type=00
	
	if [ "$sysmode" = "repeater" ];then
		tpie_level=02
		tpie_subnet_type=02 #RE
	fi

	# Build TPIE with LAN MAC addr
	tp_ie_hw_addr=`uci show network|grep macaddr|sed -n '3p'|awk -F '=' '{print $2}'`
	tp_ie_hw_addr=${tp_ie_hw_addr//:/}
	tpie_mac=$tp_ie_hw_addr

	random_suffix="7859"
	config_get gp_id_rand onemesh group_id
	[ "$gp_id_rand" = "-1" ] && gp_id_rand=""
	gp_id_rand=${gp_id_rand:0:4}
	[ -n "$gp_id_rand" ] && random_suffix=$gp_id_rand

	# only Beacon/Probe Response need TPIE
	# BEACON        0x10
	# ASSOC_REQ     0x01
	# ASSOC_RES     0x02
	# PROBE_REQ     0x04
	# PROBE_RES     0x08
	local ftype=18

	local vendor_oui="001d0f"
	## exclude Guest Network and WDS(sta) interface, keep Host & Backhual for the following
	if [ "$mode" = "ap" -a -z "$guest" -a -z "$iot" -a -z "$onemesh_config" ]; then
		if [ "$onemesh_enable" = "on" -o "$easymesh_enable" = "on" ];then
			if [ "$backhaul" = "on" ]; then
				# Backhual Network
				wlanconfig "$vif" vendorie add len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}67${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}0000${tpie_mac:8:4}00010000 ftype_map 18
				## disable 11k/v
				cfg80211tool "$vif" rrm 0
				cfg80211tool "$vif" wnm 0

			else
				# Host Network
				wlanconfig "$vif" vendorie add len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}63${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}0000${tpie_mac:8:4}00010000 ftype_map 18
				echo "wlanconfig $vif vendorie add len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}63${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}0000${tpie_mac:8:4}00010000 ftype_map 18" > /dev/console
				## enable 11k/v
				cfg80211tool "$vif" rrm 1
				cfg80211tool "$vif" wnm 1
			fi
		else
			# disable onemesh
			local vendorie_appear=`wlanconfig "$vif" vendorie list | grep "$vendor_oui" -c`
			if [ "$vendorie_appear" -gt "0" ]; then
				wlanconfig "$vif" vendorie remove len 4 oui 001d0f pcap_data 10
			fi
			if [ "$backhaul" != "on" ];then
				## enable 11k/v for Host Network
				cfg80211tool "$vif" rrm 1
				cfg80211tool "$vif" wnm 1
			fi
		fi
	elif [ "$onemesh_ie" = "on" ]; then
		wlanconfig "$vif" vendorie add len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}67${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}0000${tpie_mac:8:4}00010000 ftype_map 18
	fi
	### Onemsh end

	config_get txqueuelen "$vif" txqueuelen 1000
	[ -n "$txqueuelen" ] && ifconfig "$vif" txqueuelen "$txqueuelen"
	config_get_bool guest "$vif" guest 0
	config_get_bool iot "$vif" iot 0
	config_get_bool onemesh_config "$vif" onemesh_config 0
	config_vap_mode "$vif" "$hwmode:$htmode" "$channel" "$txpower"
	if [ "$guest" = "0" -a "$iot" = "0" -a "$onemesh_config" = "0" ]; then
		config_get bintval "$vif" bintval 100
		[ -n "$bintval" ] && cfg80211tool "$vif" bintval "$bintval"
	fi
	config_cfg80211tool "$vif" "$cfg"	

	#dyn_bw_rts for 5g vap, originally to fix bug with PS4 Slim 5G 80Mhz
	[ "$band" = "5g" -o "$band" = "5g_2" ] && {
		cfg80211tool "$vif" dyn_bw_rts 1
	}

	config_get mcast_rate "$vif" mcast_rate
	[ -n "$mcast_rate" ] && cfg80211tool "$vif" mcast_rate "${mcast_rate%%.*}"

	#limit max sta for 2g&5g vap
	max_sta=64
	[ "$band" = "2g" -o "$band" = "5g" -o "$band" = "5g_2" ] && {
		max_sta=$(uci get profile.@wireless[0].max_sta_number_$band -c /etc/profile.d)
	}
	[ "$mode" = "ap" ] && cfg80211tool "$vif" maxsta "$max_sta" &>$STDOUT

	[ "$mode" = "ap" ] && config_vap_acl "$vif"
	[ "$mode" = "sta" ] && {
		#config_get hw_addr "$dev" macaddr
		#hw_addr=${hw_addr//-/:}

		#ifconfig "$vif" down
		#ifconfig "$vif" hw ether "$hw_addr"
		#ifconfig "$vif" up
		local wanmac=$(firm_mac wan)
		wanmac=${wanmac//-/:}
		cfg80211tool "$vif" setwanmac "$wanmac"
	}

	# NOTE: config_load will clean wifi-device
    #config_load iptv
    #config_get mcwifi_en iptv mcwifi_enable
    #case $mcwifi_en in
    #    on) cfg80211tool "$vif" mcastenhance 2 ;;
    #    off) cfg80211tool "$vif" mcastenhance 8 ;;
    #esac

	cfg80211tool "$vif" mcastenhance 5
	
	[ "$band" = "2g" ] && {
		cfg80211tool "$vif" 11ngvhtintop 1
	}

	[ "$band" = "5g" -o "$band" = "5g2" ] && [ "$(uci get factory.factorymode.enable)" = "yes" ] && {
		cfg80211tool "$vif" set_cactimeout 0
	}

	tpdbg "create_vap exit."
}

wifi_update_tpie() {
	echo "=====>>>>> wifi_update_tpie_level" >$STDOUT
	local sysmode=`uci get sysmode.sysmode.mode`
	local smart_enable=`uci get wireless.smart.smart_enable`
	config_get onemesh_enable onemesh enable "on"

	local tpie_level=00
	local product_type=0001
	local tpie_subnet_type=01 #AP
	local backhaul_type=00
	local uplink_rate=0000

	local level=`uci get onemesh.onemesh.level`
	if [ -z "$level" ];then
		level=2
	fi
	local uplink_mask=`uci get onemesh.onemesh.uplink_mask`
	if [ -z "$uplink_mask" ];then
		uplink_mask=0
	fi

	for dev in ${DEVICES}; do
		config_get band $dev band
		config_get vifs $dev vifs

		case $band in
		2g)
			HOME_WIFI="ath0"
			BACKHAUL_WIFI="ath03"
		;;
		5g)
			HOME_WIFI="ath1"
			BACKHAUL_WIFI="ath13"
		;;
		esac

		for vif in $vifs;do
			echo "=====>>>>> set tp_ie" >$STDOUT
			config_get onemesh_ie $vif onemesh_ie "on"
			config_get gp_id_rand onemesh group_id
			[ "$gp_id_rand" = "-1" ] && gp_id_rand=""

			self_hw_mac=`uci show network|grep macaddr|sed -n '3p'|awk -F '=' '{print $2}'`
			self_tpie_mac=${self_hw_mac//:/}
			if [ "$sysmode" = "router" -o "$sysmode" = "ap" ]; then
				tpie_mac=$self_tpie_mac #LAN MAC as TPIE_MAC
			elif [ "$sysmode" = "repeater" ];then
				tpie_mac=$self_tpie_mac
				config_get tpie_hw_mac onemesh macaddr #MASTER MAC as TPIE_MAC
				[ -n "$tpie_hw_mac" ] && tpie_mac=${tpie_hw_mac//[-:]/}
			fi

			random_suffix="5789"
			gp_id_rand=${gp_id_rand:0:4}
			gp_id_rand="${gp_id_rand:0:2}${gp_id_rand:2:2}"

			if [ "$sysmode" = "repeater" ];then
				if [ "$level" = "0" ];then
					tpie_level=00
				elif [ "$level" = "1" ];then
					tpie_level=01
				else
					tpie_level=02
				fi

				backhaul_type=`printf "%02x" $uplink_mask`
				#to do
				#if rootAP is not wireless router, product should be set by wpa_supplicant when connect.
				config_get product_type onemesh product_type 0001

				tpie_subnet_type=02 #RE

				#to do
				#use rssi as uplink_rate
				uplink_rate=0000
			fi
			[ -n "$gp_id_rand" ] && random_suffix=$gp_id_rand
			
			local vendor_oui="001d0f"

			if [ "$onemesh_ie" = "on" -a "$onemesh_enable" = "on" ]; then
				# HOME WIFI
				[ "$vif" = "ath0" -o "$vif" = "ath1" ] && {
					wlanconfig ${HOME_WIFI} vendorie update len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}63${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}${uplink_rate}${self_tpie_mac:8:4}${product_type}0000 ftype_map 18
					echo "=====>>>>>  wlanconfig ${HOME_WIFI} vendorie update len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}63${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}${uplink_rate}${self_tpie_mac:8:4}${product_type}0000 ftype_map 18" > /dev/console
				}
				# BACKHAUL WIFI
				[ "$vif" = "ath03" -o "$vif" = "ath13" ] && {
					wlanconfig ${BACKHAUL_WIFI} vendorie update len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}67${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}${uplink_rate}${self_tpie_mac:8:4}${product_type}0000 ftype_map 18
					echo "=====>>>>>  wlanconfig ${BACKHAUL_WIFI} vendorie update len 30 oui $vendor_oui pcap_data 10${tpie_subnet_type}67${tpie_level}${backhaul_type}${tpie_mac}${tpie_mac}${random_suffix}${uplink_rate}${self_tpie_mac:8:4}${product_type}0000 ftype_map 18" > /dev/console
				}
			else
				# disable TP IE
				local vendorie_appear=`wlanconfig "$vif" vendorie list | grep "$vendor_oui" -c`
				if [ "$vendorie_appear" -gt "0" ]; then
					wlanconfig "$vif" vendorie remove len 4 oui $vendor_oui pcap_data 10
				fi
			fi

		done
	done
}

kill_pid() {
	for f in wifi; do
		if [ ! -f /var/run/$f-$1.pid ];then
			return
		fi
		local n=${2:-0} p=$(cat "/var/run/$f-$1.pid" 2>$STDOUT)
		while [ -f "/var/run/$f-$1.pid" ]; do 
			([ -n "$p" ] && kill $p) || (rm -f "/var/run/$f-$1.pid" && break)
			[ "$n" -gt 0 ] || break
			n=$(($n - 1)) && echo "wait for pid $p $n times"
		done
	done
}

config_vap() {
	local vif="$1" action="$2" start_hostapd= hasvif=
	#[lixiangkui start] For WPA3 support
	local is_valid_owe_group=0
	local is_valid_sae_group=0
	#[lixiangkui end]
	local wireless_qos_support=$(uci -c /etc/profile.d get profile.wireless_qosmanager.support 2>/dev/null)

	[ -z "$vif" ] && return
	kill_pid $vif
	config_get mode "$vif" mode
	config_get phy "$vif" device
	config_get_bool disabled "$vif" disabled 0
	[ -z "$mode" -o -z "phy" ] && return
	[ -d /sys/class/net/$vif ] && hasvif="1"

	tpdbg "config_vap vif:$vif disabled:$disabled"
	[ "$disabled" = "1" ] && {
		[ -n "$hasvif" ] && destroy_vap "$vif"
		return
	}
	tpdbg "config_vap hasvif:$hasvif action:$action"

	[ -z "$hasvif" -o "$action" = "reload" ] && create_vap "$vif" "$phy" "$mode"
	[ -n "$hasvif" -a "$action" = "update" ] &&  {
		config_get rts "$vif" rts off
		config_get frag "$vif" frag 2346

		#mu-mimo support
                config_get vhtmubfer "$vif" vhtmubfer 1
                config_get vhtmubfee "$vif" vhtmubfee 1
                cfg80211tool "$vif" vhtmubfer "$vhtmubfer"
		#following may fail as ap may not support beamformee while in ap mode(support in sta mode)
                cfg80211tool "$vif" vhtmubfee "$vhtmubfee"

		config_get_bool wmm "$vif" wmm 1
		config_get_bool shortgi "$vif" shortgi 1
		cfg80211tool "$vif" wmm "$wmm"
		cfg80211tool "$vif" shortgi "$shortgi"
		[ "$mode" = "ap" ] && {
			config_get bintval "$vif" bintval 100
			config_get dtim_period "$vif" dtim_period 1
			cfg80211tool "$vif" dtim_period "$dtim_period"
			cfg80211tool "$vif" bintval "$bintval"
		}
		[ -n "$frag" ] && iwconfig "$vif" frag "$frag"
		[ -n "$rts" ] && iwconfig "$vif" rts "$rts"
	}

	#multi-ap support
	local enable_mesh=`uci get meshd.meshd.enable`
	if [ "$enable_mesh" = "on" ]; then
		cfg80211tool "$vif" map "2"
		if [ "$vif" = "$VIF_HOME_2G" -o "$vif" = "$VIF_HOME_5G" ]; then
			uci set wireless.${vif}.map="2" #profile 2
			uci set wireless.${vif}.MapBSSType="32" #fBSS
			cfg80211tool "$vif" MapBSSType "32"
		elif [ "$vif" = "$VIF_WDS_2G" -o "$vif" = "$VIF_WDS_5G" ]; then
			uci set wireless.${vif}.map="2" #profile 2
			uci set wireless.${vif}.MapBSSType="128" #bSTA
			cfg80211tool "$vif" MapBSSType "128"
		elif [ "$vif" = "$VIF_BACKHAUL_2G" -o "$vif" = "$VIF_BACKHAUL_5G" ]; then
			uci set onemesh.${vif}.map="2" #profile 2
			uci set onemesh.${vif}.MapBSSType="64" #bBSS
			cfg80211tool "$vif" MapBSSType "64"
		elif [ "$vif" = "$VIF_RTORCFG_2G" -o "$vif" = "$VIF_RTORCFG_5G" ]; then
			uci set onemesh.${vif}.map="2" #profile 2
			uci set onemesh.${vif}.MapBSSType="96" #bBSS(for EasyMesh) + fBSS(for OneMesh)
			cfg80211tool "$vif" MapBSSType "96"
		fi
	else
		cfg80211tool "$vif" map "0"
		cfg80211tool "$vif" MapBSSType "0"
		if [ "$vif" = "$VIF_BACKHAUL_2G" -o "$vif" = "$VIF_BACKHAUL_5G" ]; then
			uci set onemesh.${vif}.map="0"
			uci set onemesh.${vif}.MapBSSType="0"
		elif [ "$vif" = "$VIF_RTORCFG_2G" -o "$vif" = "$VIF_RTORCFG_5G" ]; then
			uci set onemesh.${vif}.map="0"
			uci set onemesh.${vif}.MapBSSType="0"
		else
			uci set wireless.${vif}.map="0"
			uci set wireless.${vif}.MapBSSType="0"
		fi
	fi
	uci commit


	#ACS block channel
	config_acs_block_chan "$vif"

	#atf support
	config_get_bool atf "$vif" atf 
	if [ "$atf" = "1" ]; then
		cfg80211tool $vif commitatf 1
	else
		cfg80211tool $vif commitatf 0
	fi

	# 2G config ANI & Dyn EDCCA
	get_wlan_ini FEATURE_ANI_ENHANCE
	if [ "${FEATURE_ANI_ENHANCE}" = "y" ]; then
		config_ani_and_dyn_edcca "$vif"
	fi

	get_wlan_ini FEATURE_ENABLE_RTSCTS
	if [ "${FEATURE_ENABLE_RTSCTS}" = "y" ];then
		config_enable_rtscts "$vif"
	fi

	config_get ssid "$vif" ssid
	if [ -n "$ssid" ]; then
		cfg80211tool "$vif" ssid "$ssid"
	fi

	config_get_bool hidden "$vif" hidden 0
	cfg80211tool "$vif" hide_ssid "$hidden"

	kill_pid $vif 100

	#clear encryption
	cfg80211tool "$vif" authmode 1
	[ "$mode" = "sta" ] && cfg80211tool "$vif" setoptie
	iwconfig "$vif" enc off
	iwconfig "$vif" key off

	#[lixiangkui start] For WPA3 support
	config_get own_ie_override "$vif" own_ie_override
	[ -n "$own_ie_override" ] && cfg80211tool "$ifname" rsn_override 1

	config_get_bool sae "$vif" sae
	config_get_bool owe "$vif" owe
	config_get_bool dpp "$vif" dpp
	config_get pkex_code "$vif" pkex_code
	config_get suite_b "$vif" suite_b 0

	if [ $suite_b -eq 192 ]
	then
		cat /sys/class/net/$device/ciphercaps | grep -i "gcmp-256"
		if [ $? -ne 0 ]
		then
			echo "enc:GCMP-256 is Not Supported on Radio" > /dev/console
			destroy_vap $ifname
			continue
		fi
	elif [ $suite_b -ne 0 ]
	then
		echo "$suite_b bit security level is not supported for SUITE-B" > /dev/console
		destroy_vap $ifname
		continue
	fi

	if [ ! -z ${dpp} ]; then
		if [ "${dpp}" -eq 1 ]
		then
			cfg80211tool "$ifname" set_dpp_mode 1
			config_get dpp_type "$vif" dpp_type "qrcode"
			if [ "$dpp_type" != "qrcode" -a "$dpp_type" != "pkex" ]
			then
				echo "Invalid DPP type" > /dev/console
				destroy_vap $ifname
				continue
			elif [ "$dpp_type" == "pkex" ]
			then
				if [ -z "$pkex_code" ]
				then
					echo "pkex_code should not be NULL" > /dev/console
					destroy_vap $ifname
				fi
			fi
		fi
	fi

	check_sae_groups() {
		local force_invalid_group sae_groups=$(echo $1 | tr "," " ")
		config_get force_invalid_group "$vif" force_invalid_group 0

		# If force_invalid_group option is set, do not check for vaid SAE groups
		# WFA Negative Testcase
		if [ "${force_invalid_group}" -eq 1 ]
		then
			echo "Allowing invalid sae_groups for WFA negative testcase" > /dev/console
			return
		fi

		for sae_group_value in $sae_groups
		do
			case "$sae_group_value" in
				0|15|16|17|18|19|20|21)
				;;
				*)
					echo "Invalid sae_group: $sae_group_value" > /dev/console
					destroy_vap $ifname
					is_valid_sae_group=1
					break
			esac
		done
	}
	#[lixiangkui end]

	config_get enc "$vif" encryption
	case "$enc" in
		none|portal)
			# We start hostapd in open mode also
			start_hostapd=1
		;;
		#[lixiangkui start] For WPA3 support
		wpa*|8021x)
			start_hostapd=2
		;;
		mixed*|wep*|psk*)
			start_hostapd=2
			config_get key "$vif" key
			config_get wpa_psk_file  "$vif" wpa_psk_file
			if [ -z "$key" ] && [ -z $wpa_psk_file ]
			then
				echo "Key is NULL" > /dev/console
				destroy_vap $ifname
				continue
			fi
			case "$enc" in
				*tkip*|wep*)
					if [ $sae -eq 1 ] || [ $owe -eq 1 ]
					then
						echo "With SAE/OWE enabled, tkip/wep enc is not supported" > /dev/console
						destroy_vap $ifname
						continue
					fi
				;;
			esac
			if [ $sae -eq 1 ]
			then
				pwid_exclusive=1
				pwid=0
				sae_password_count=0

				if [ "$mode" = "ap" ]
				then
					check_sae_pwid_capab() {
						local sae_password=$(echo $1)
						if [ -n "$sae_password" ]
						then
							sae_password_count=$((sae_password_count+1))

							case "$sae_password" in
								*"|id="*)
								pwid=1
								echo "pwid match" > /dev/console
								;;
								*)
								echo "pw only match" > /dev/console
								pwid_exclusive=0
								;;
							esac
						fi
					}
					config_list_foreach "$vif" sae_password check_sae_pwid_capab

					if [ -z "$$sae_password_count" ]
					then
						case "$key" in
							*"|id="*)
							pwid=1
							echo "pwid match" > /dev/console
							;;
							*)
							echo "pw only match" > /dev/console
							pwid_exclusive=0
							;;
						esac
					fi

					echo "sae password count:" $sae_password_count > /dev/console

					if [ $sae_password_count -eq 0 ] && [ -z "$key" ] && [ -z $wpa_psk_file ]
					then
						echo "key and sae_password are NULL" > /dev/console
						destroy_vap $ifname
						continue
					fi
					if [ $pwid -eq 1 ]
					then
						if [ $pwid_exclusive -eq 1 ]
						then
							"$device_if" "$ifname" en_sae_pwid 3
						else
							"$device_if" "$ifname" en_sae_pwid 1
						fi
					fi
					config_list_foreach "$vif" sae_groups check_sae_groups

				elif [ "$mode" = "sta" ]
				then
					config_get sae_password "$vif" sae_password
					if [ $sae_password -eq 0 ] && [ -z "$key" ] && [ -z $wpa_psk_file ]
					then
						echo "key and sae_password are NULL" > /dev/console
						destroy_vap $ifname
						continue
					fi
				fi
				[ $is_valid_sae_group = 1 ] && continue
			fi
		;;
		tkip*)
			if [ $sae -eq 1 ] || [ $owe -eq 1 ]
			then
				echo "With SAE/OWE enabled, tkip enc is not supported" >&2
				destroy_vap $ifname
				continue
			fi
		;;
		wapi*)
			start_wapid=1
			config_get key "$vif" key
		;;
		#Needed ccmp*|gcmp* check for SAE OWE auth types
		ccmp*|gcmp*)
			start_hostapd=2
			config_get key "$vif" key
			config_get wpa_psk_file  "$vif" wpa_psk_file
			pwid_exclusive=1
			pwid=0
			sae_password_count=0
			if [ $sae -eq 1 ]
			then
				if [ "$mode" = "ap" ]
				then
					check_sae_pwid_capab() {
						local sae_password=$(echo $1)
						if [ -n "$sae_password" ]
						then
							sae_password_count=$((sae_password_count+1))

							case "$sae_password" in
								*"|id="*)
								pwid=1
								echo "pwid match" > /dev/console
								;;
								*)
								echo "pw only match" > /dev/console
								pwid_exclusive=0
								;;
							esac
						fi
					}
					config_list_foreach "$vif" sae_password check_sae_pwid_capab

					if [ -z "$$sae_password_count" ]
					then
			case "$key" in
							*"|id="*)
							pwid=1
							echo "pwid match" > /dev/console
							;;
							*)
							echo "pw only match" > /dev/console
							pwid_exclusive=0
							;;
			esac
					fi

					echo "sae password count:" $sae_password_count > /dev/console

					if [ $sae_password_count -eq 0 ] && [ -z "$key" ] && [ -z $wpa_psk_file ]
					then
						echo "key and sae_password are NULL" > /dev/console
						destroy_vap $ifname
						continue
					fi
					if [ $pwid -eq 1 ]
					then
						if [ $pwid_exclusive -eq 1 ]
						then
							"$device_if" "$ifname" en_sae_pwid 3
						else
							"$device_if" "$ifname" en_sae_pwid 1
						fi
					fi
					config_list_foreach "$vif" sae_groups check_sae_groups

				elif [ "$mode" = "sta" ]
				then
					config_get sae_password "$vif" sae_password
					if [ $sae_password -eq 0 ] && [ -z "$key" ] && [ -z $wpa_psk_file ]
					then
						echo "key and sae_password are NULL" > /dev/console
						destroy_vap $ifname
						continue
					fi
				fi
				[ $is_valid_sae_group = 1 ] && continue
			fi
			if [ $owe -eq 1 ]
			then
				if [ "$mode" = "ap" ]
				then
					check_owe_groups() {
						local owe_groups=$(echo $1 | tr "," " ")
						for owe_group_value in $owe_groups
						do
							case "$owe_group_value" in
								0|19|20|21)
		;;
								*)
									echo "Invalid owe_group: $owe_group_value" > /dev/console
									destroy_vap $ifname
									is_valid_owe_group=1
									break
							esac
						done
					}
					config_list_foreach "$vif" owe_groups check_owe_groups
				elif [ "$mode" = "sta" ]
									then
											config_get owe_group "$vif" owe_group 0
					case "$owe_group" in
						0|19|20|21)
						;;
						*)
							echo "Invalid owe_group: $owe_group" > /dev/console
							destroy_vap $ifname
							is_valid_owe_group=1
							break
					esac
									fi

				[ $is_valid_owe_group = 1 ] && continue
			fi
		;;
		sae*|dpp|psk2)
			start_hostapd=2
		;;
		#[lixiangkui end]
	esac

	tpdbg "config_vap mode:$mode"
	case "$mode" in
		ap)
			config_get iot "$vif" iot
			config_get dev "$vif" device
			config_get_bool isolate "$vif" isolate 0
			if [ -n "$iot" ]; then
				local device_isolate=`uci get wireless.${dev}.isolate`
				local vif_isolate=`uci get wireless.${vif}.isolate`
				if [ $device_isolate != $vif_isolate ]; then
					if [ $device_isolate == "on" ]; then				
						isolate=1
					else
						isolate=0
					fi
				fi
			fi
			cfg80211tool "$vif" ap_bridge "$((isolate^1))"
                        cfg80211tool "$vif" athnewind "1"
			if [ -n "$start_hostapd" ]; then
				if [ "$enable_mesh" = "on" ]; then
					local bh_ssid=""
					local bh_psk=""
					if [ "$vif" = "$VIF_HOME_2G" ]; then
						config_get bh_ssid "$VIF_BACKHAUL_2G" ssid
						config_get bh_psk "$VIF_BACKHAUL_2G" psk_key
						#bh_ssid=`uci get onemesh.ath03.ssid`
						#bh_psk=`uci get onemesh.ath03.psk_key`
						hostapd_setup_vif "$vif" nl80211 no_nconfig bBSS "$bh_ssid" "$bh_psk" || {
							echo "Failed to set up hostapd for interface $vif" >&2
							destroy_vap "$vif"
						}
					elif [ "$vif" = "$VIF_HOME_5G" ]; then
						config_get bh_ssid "$VIF_BACKHAUL_5G" ssid
						config_get bh_psk "$VIF_BACKHAUL_5G" psk_key
						#bh_ssid=`uci get onemesh.ath13.ssid`
						#bh_psk=`uci get onemesh.ath13.psk_key`
						hostapd_setup_vif "$vif" nl80211 no_nconfig bBSS "$bh_ssid" "$bh_psk" || {
							echo "Failed to set up hostapd for interface $vif" >&2
							destroy_vap "$vif"
						}
					else
						hostapd_setup_vif "$vif" nl80211 no_nconfig || {
							echo "Failed to set up hostapd for interface $vif" >&2
							destroy_vap "$vif"
						}
					fi
				else
					hostapd_setup_vif "$vif" nl80211 no_nconfig || {
						echo "Failed to set up hostapd for interface $vif" >&2
						destroy_vap "$vif"
					}
				fi
			fi
			config_get_bool wps "$vif" wps 0
			cfg80211tool "$vif" wps "$wps"

			### config mscs
			if [ "$wireless_qos_support" = "yes" ]; then
				config_get mscs "$dev" mscs_enable off
				if [ "$mscs" = "on" ]; then
					cfg80211tool "$vif" mscs 1
					echo 0 > /sys/kernel/debug/ecm/ecm_classifier_dscp/enabled
					echo 1 > /sys/kernel/debug/ecm/ecm_classifier_mscs/enabled
					insmod qca-nss-mscs
				else
					cfg80211tool "$vif" mscs 0
					echo 1 > /sys/kernel/debug/ecm/ecm_classifier_dscp/enabled
					echo 0 > /sys/kernel/debug/ecm/ecm_classifier_mscs/enabled
					rmmod qca-nss-mscs
				fi
				. /lib/qos/core_qos.sh
				update_ip_use_legacy_tos
			fi

			### 11AX Feature
			config_get hwmode "$dev" hwmode
			config_get guest "$vif" guest
			config_get backhaul "$vif" backhaul
			config_get onemesh_config "$vif" onemesh_config
            if [ "$backhaul" = "on" -o "$onemesh_config" = "on" ]; then
                local brlan_mac=`ifconfig br-lan|grep 'HWaddr'|awk -F " " '{print $5}'`
                iwpriv "$vif" netmac "$brlan_mac"
            fi

			if [ -z "$guest" ] && [ -z "$iot" ] && [ "$backhaul" != "on" -a "$onemesh_config" != "on" ]; then
				local twt=`uci get wireless.twt.enable`
				if [ "$hwmode" = "11axg" -o "$hwmode" = "11axa" ]; then
					if [ "$twt" = "on" ]; then
						cfg80211tool "$vif" twt 1
					else
						cfg80211tool "$vif" twt 0
					fi
				else
					cfg80211tool "$vif" twt 0
				fi

				local ofdma=`uci get wireless.ofdma.enable`
				if [ "$hwmode" = "11axg" -o "$hwmode" = "11axa" ]; then
					if [ "$ofdma" = "on" ]; then
						cfg80211tool "$vif" he_dl_ofdma 1
						cfg80211tool "$vif" he_ul_ofdma 1
					else
						cfg80211tool "$vif" he_dl_ofdma 0
						cfg80211tool "$vif" he_ul_ofdma 0
					fi
				else
					cfg80211tool "$vif" he_dl_ofdma 0
					cfg80211tool "$vif" he_ul_ofdma 0
				fi

				config_get mu_mimo "$dev" mu_mimo
				if [ "$hwmode" = "11axg" -o "$hwmode" = "11axa" -o "$hwmode" = "11ac" ]; then
					if [ "$mu_mimo" = "on" ]; then
						cfg80211tool "$vif" he_mubfer 1
						cfg80211tool "$vif" he_mubfee 1
						cfg80211tool "$vif" vhtmubfer 1
					else
						cfg80211tool "$vif" he_mubfer 0
						cfg80211tool "$vif" he_mubfee 0
						cfg80211tool "$vif" vhtmubfer 0
					fi
				else
					cfg80211tool "$vif" he_mubfer 0
					cfg80211tool "$vif" he_mubfee 0
					cfg80211tool "$vif" vhtmubfer 0
				fi
			fi
			### 11AX Feature end
		;;
		sta)
			local easymesh_support=`uci get profile.@onemesh[0].easymesh_support -c /etc/profile.d/ -q`
			config_get addr "$vif" bssid "any"
			addr=${addr//-/:}
			
			if [ "yes" = "$easymesh_support" ]; then
				config_get extap "$vif" wds_mode 2
			else
				config_get_bool extap "$vif" extap 1
			fi
			cfg80211tool "$vif" setparam 12 1 #enable roaming
			cfg80211tool "$vif" extap "$extap"
			cfg80211tool "$vif" allmulti 1
			# enable to fellow rootap and keep local wlan alive.
			# TODO:disable it in "CLIENT MODE" to reduce scan time.
			cfg80211tool "$vif" athnewind "1"
			config_get wds "$vif" wds
			config_get rept_spl  "$vif" rept_spl 0
			[ -n "$rept_spl" ] && cfg80211tool "$vif" rept_spl "$rept_spl"
			case "$wds" in
				1|on|enabled)
					wds=1
					iw "$vif" set 4addr on >/dev/null 2>&1
					;;
				*)	wds=0
					;;
			esac
			cfg80211tool "$vif" wds "$wds" 
			iwconfig "$vif" ap "$addr"
			echo "=====>>>>>vif=$vif start_hostapd=$start_hostapd" > $STDOUT
			local sysmode=`uci get sysmode.sysmode.mode`
			local role=`uci get meshd.meshd.role`
			if [ "$sysmode" = "repeater" -o "$role" = "agent" ]; then
				wpa_supplicant_setup_vif "$vif" nl80211 || {
					echo "Failed to set up wpa_supplicant for interface $vif" >&2
					destroy_vap "$vif"
				}
			fi
		;;
	esac
}

wifi_smart() {
	/etc/init.d/nrd restart
}

wifi_onemesh() {
	/etc/init.d/sync-server stop

	local tdpServer_pid=`pgrep /usr/bin/tdpServer`
	if [ -n "$tdpServer_pid" ];then
		for pid in $tdpServer_pid; do
			kill -9 "$pid"
		done
		### NOTE Delete all iptables rules and client files
		[ -f "/sbin/knock_functions.sh" ] && /sbin/knock_functions.sh remove_all
		rm -rf /tmp/dropbear/succ_cli/*
	fi

	wifi_reload

	/etc/init.d/nrd restart

	/etc/init.d/sync-server start
	local tdpServer=$(pgrep tdpServer| wc -l)
	if [ "$tdpServer" -ge 1 ]; then
		return 1
	else
		"/bin/nice" -n -5 /usr/bin/tdpServer &>/dev/null &
	fi
}

wifi_onemesh_search(){
	local operation=$1
	local easymesh_enable=`uci get meshd.meshd.enableeasymesh`
	local onemesh_version=`uci get onemesh.onemesh.version`
	local sysmode=`uci get sysmode.sysmode.mode`
	local role=`uci get meshd.meshd.role`
	
	local vifs="ath04 ath14"
	local mac_list=
	local ifname
	
	[ "$role" = "agent" -o "$onemesh_version" != "2" -o "$easymesh_enable" != "on" ] && return
	
	for ifname in $vifs; do
		if [ "$operation" = "start" ];then
			config_set $ifname disabled 0
			wifi_vap $ifname
			iwpriv $ifname maccmd 3
			iwpriv $ifname maccmd 0
		elif [ "$operation" = "stop" ];then
			result=$(wlanconfig $ifname list sta | grep '..:..:..:..:..:..' | awk '{print $1}')
			local mac_list=
			for i in $result;do 
				iwpriv $ifname addmac $i
			done
			iwpriv $ifname maccmd 1
		elif [ "$operation" = "cancel" ];then
			config_set $ifname disabled 1
			wifi_vap $ifname
		fi
	done
	
	if [ "$operation" = "start" ];then
		config_vap_monitor start &
	elif [ "$operation" = "cancel" ];then
		echo "onemesh search cancel" > /dev/console
		config_vap_monitor cancel &
		ubus call map meshd '{"action":"clear_white"}'
		ubus call tdpServer onemesh_clean_devices '{}'
		ubus call tdpServer onemesh_probe '{}' &
	fi
}

config_vap_monitor() {
	local action=$1

	if [ "$action" = "start" ];then
		local timer=0
		
		while [ $timer -lt 20 ]
		do		
			bssid_2g=$(ifconfig ath04 | grep HWaddr | awk '{print $NF}')
			bssid_5g=$(ifconfig ath14 | grep HWaddr | awk '{print $NF}')
	
			if [ -z "$bssid_2g" -a -z "$bssid_5g" ];then
				break;
			fi
			
			sleep 15
			timer=$(($timer+1))
		done
		if [ $timer -ge 20 ];then
			wifi_onemesh_search cancel
		fi
		return
	elif [ "$action" = "cancel" ];then
		pid=$(ps -w|grep "/sbin/wifi search start" |grep -v "grep" |awk '{print $1}')
		
		if [ -n "pid" ];then
			for p in ${pid}; do
				kill -9 $p
			done
		fi
	fi
}

wifi_mode() {
	local dev vif
	for dev in ${1:-$DEVICES}; do
		local vifs=""
		for vif in $(config_get "$dev" vifs); do 
			#[ -d /sys/class/net/$vif ] && append vifs "$vif" && ifconfig "$vif" down &>$STDOUT
			[ -d /sys/class/net/$vif ] && append vifs "$vif" &>$STDOUT
		done;
		config_get_bool disabled "$dev" disabled 0
		config_get_bool disabled_all "$dev" disabled_all 0
		if [ "$disabled" = "1" ] || [ "$disabled_all" = "1" ]; then
			for vif in $vifs; do if [ "$vif" = "${VIF_BACKHAUL_2G}" -o "$vif" = "${VIF_BACKHAUL_5G}" -o "$vif" = "${VIF_BACKHAUL_5G2}" ]; then continue; fi; destroy_vap "$vif" &>$STDOUT; done
			continue
		fi
		config_get hwmode "$dev" hwmode auto
		config_get htmode "$dev" htmode auto
		config_get channel "$dev" channel 0
		config_get txpower "$dev" txpower
		config_get tpscale "$dev" tpscale
		[ -n "$2" -o "$1" = "country" ] && config_country "$dev" &>$STDOUT
		for vif in $vifs; do config_vap_mode "$vif" "$hwmode:$htmode" "$channel" "$txpower" &>$STDOUT; done
		[ -n "$tpscale" ] && cfg80211tool "$dev" tpscale "$tpscale" &>$STDOUT

		if type wifi_cca_threshold_set &> /dev/null; then
			wifi_cca_threshold_set "$dev" &
		else
			echo "Function 'wifi_cca_threshold_set' dose not exist." > /dev/console
		fi
	done;
	/etc/init.d/nrd restart
	config_vap_vlan up &>$STDOUT
}

wifi_vap() {
	local device vifs disabled dev_disabled dev_disabled_all
    local tmp_dev=""
    local sysmode=`uci get sysmode.sysmode.mode`
	for vap in $1; do
		config_get device "$vap" device
		config_get vifs "$device" vifs
		config_get_bool disabled "$vap" disabled
		config_get dev_disabled "$device" disabled
		config_get dev_disabled_all "$device" disabled_all
		config_get_bool guest "$vap" guest 0
		if [ "$dev_disabled" = "on" ] || [ "$dev_disabled_all" = "on" ]; then
			continue
		fi
		[ "$disabled" = "1" -a ! -d /sys/class/net/$vap ] && continue
                if [ "$sysmode" == "repeater" -o "$sysmode" == "client" -o "$sysmode" == "multissid" ];then
            # repeater or client mode, enable(create) first vap in devices need set param in wifi_reload func.
            local vif vap_num=0
            if [ -n "$tmp_dev" -a -n "$(echo $tmp_dev | grep $device)" ]; then continue; fi

            for vif in $vifs; do [ -d /sys/class/net/$vif ] && vap_num=$(($vap_num+1)); done
            if [ $vap_num -eq 0 ]; then tmp_dev="$device $tmp_dev"; wifi_reload $device; continue; fi
        fi
		#turn down interface will make vap related config invalid when turn on again
		#if [ "$guest" = "0" ]; then
		#	for vif in $vifs; do ifconfig "$vif" down &>$STDOUT; done
		#fi
		wpa_cli -g /var/run/hostapd/global raw REMOVE $vap
		config_vap "$vap" &>$STDOUT

		if type wifi_cca_threshold_set &> /dev/null; then
			wifi_cca_threshold_set "$device" &
		else
			echo "Function 'wifi_cca_threshold_set' dose not exist." > /dev/console
		fi
	done
	/etc/init.d/nrd restart
	config_vap_vlan up &>$STDOUT
	[ -f /sbin/set_br_nf ] && set_br_nf

	local portal_support=`uci get profile.@portal[0].portal_support -c "/etc/profile.d"`
	if [ "$portal_support" = "yes" ]; then
		wifi_portal_config
	fi
}

wifi_country() {
	wifi_mode "${1:-$DEVICES}" "country" &>$STDOUT
}

wifi_radio() {
	local action="update"
	[ -n "$2" ] && action="reload"

	# TWT/OFDMA
	# if not specific dev name, apply it for all devices
	local devs=${1:-$DEVICES}
	if [ "$devs" != "$DEVICES" ]; then
		local intf=$(echo $DEVICES | grep "${devs}")
		if [ -z "$intf" ]; then
			devs=$DEVICES
		fi
	fi

	tpdbg "wifi_radio--devname:$DEVICES"
	for dev in $devs; do
        cfg80211tool $dev dbdc_enable 0
		local max_sta
		config_get vifs "$dev" vifs
		config_get tpscale "$dev" tpscale
		config_get band "$dev" band
		config_get_bool disabled "$dev" disabled 0
		config_get_bool disabled_all "$dev" disabled_all 0

		tpdbg "wifi_radio--vifs:$vifs"
		for vif in $vifs; do [ -d /sys/class/net/$vif ] && wpa_cli -g /var/run/hostapd/global raw REMOVE ${vif} &>$STDOUT; done

		tpdbg "wifi_radio--disabled:$disabled disabled_all:$disabled_all"
		if [ "$disabled" = "1" ] || [ "$disabled_all" = "1" ]; then
			for vif in $vifs; do if [ "$vif" = "${VIF_BACKHAUL_2G}" -o "$vif" = "${VIF_BACKHAUL_5G}" -o "$vif" = "${VIF_BACKHAUL_5G2}" ]; then continue; fi; config_set "$vif" disabled "on"; [ -d /sys/class/net/$vif ] && destroy_vap "$vif" &>$STDOUT; done
		fi
		[ "$action" = "reload" ] && {
			config_get macaddr "$dev" macaddr
			[ -n "$macaddr" ] && cfg80211tool "$dev" setHwaddr "${macaddr//-/:}" &>$STDOUT
			[ `/usr/sbin/cfg80211tool "$dev" getRegdomain 2>$STDOUT|cut -d: -f2` = "0" ] || cfg80211tool "$dev" setRegdomain 0 &>$STDOUT
			config_country "$dev" &>$STDOUT
			config_cfg80211tool "$dev" "$2" &>$STDOUT
			config_olcfg "$dev"
			[ "$band" = "2g" -o "$band" = "5g" -o "$band" = "5g_2" ] && {
				max_sta=$(uci get profile.@wireless[0].max_sta_number_$band -c /etc/profile.d)
			}

			[ -n "$max_sta" ] && cfg80211tool "$dev" max_sta "$max_sta" &>$STDOUT
		}
		for vif in $vifs; do config_vap "$vif" "$action" ;	done
		[ -n "$tpscale" ] && cfg80211tool "$dev" tpscale "$tpscale" &>$STDOUT
		
		get_wlan_ini FEATURE_THERMAL_MITIGATION
		if [ "$FEATURE_THERMAL_MITIGATION" = "y" ]; then
			config_thermal_mitigation "$dev"
		fi

		if type wifi_cca_threshold_set &> /dev/null; then
			wifi_cca_threshold_set "$dev" &
		else
			echo "Function 'wifi_cca_threshold_set' dose not exist." > /dev/console
		fi

	done
	/etc/init.d/nrd restart
	config_vap_vlan up &>$STDOUT
}

led_ctrl() {
	# repeater & client mode LED represent associate status, led_ctrl managed by repeater_monitor
	local sysmode=`uci get sysmode.sysmode.mode`
	[ -z "$sysmode" ] && sysmode="router"
	[ "$sysmode" = "client" ] && return

	local wifi_idx disabled_all band disabled
	wifi_idx=$1
	config_get disabled_all "$wifi_idx" disabled_all
	config_get band "$wifi_idx" band
	config_get disabled "$wifi_idx" disabled
	
	if [ "$band" = "2g" ];then
		config_get enable "$VIF_HOME_2G" enable
		if [ "$disabled_all" = "on" -o "$disabled" = "on" -o "$enable" = "off" ];then
			ledcli WIFI2G_OFF
		else
			ledcli WIFI2G_ON
		fi
	fi
	
	if [ "$band" = "5g" ];then
		config_get enable "$VIF_HOME_5G" enable
		if [ "$disabled_all" = "on" -o "$disabled" = "on" -o "$enable" = "off" ];then
			ledcli WIFI5G_OFF
		else
			ledcli WIFI5G_ON
		fi
	fi

	if [ "$band" = "5g_2" ];then
		if [ "$disabled_all" = "on" -o "$disabled" = "on" ];then
			ledcli WIFI5G_2_OFF
		else
			ledcli WIFI5G_2_ON
		fi
	fi
}

wifi_disconnect_stas()
{
	for dev in $DEVICES; do
		config_get vifs "$dev" vifs
		for vif in $vifs; do 
			[ -d /sys/class/net/$vif -a "$(config_get $vif mode)" = "ap" ] && cfg80211tool "$vif" kickmac "ff:ff:ff:ff:ff:ff";
		done
	done
}

wifi_portal_content_title_extend() {
	# fix bug 852451, replace '\' with '\\'
	local str="$1"
	local res=""
	local len=${#str}

	for i in $(seq 0 $(expr $len - 1))
	do
		if [ ${str:$i:1} == '\' ]; then
			res=$res\\\\
		else
			res=$res${str:$i:1}
		fi
	done

	echo "$res"
}

wifi_portal_set_config() {
	local dev="$1"
	local vif=""
	local eth_enable="0"
	local guest_enable="0"
	local wds_enable="0"
	local guest_vif=""
	local device
	local viftmp=""
	local USER_WIFIDOG_CONFIG_PATH="/var/etc/wifidog.conf"
	local DEFAULT_WIFIDOG_CONFIG_PATH="/etc/wifidog/wifidog.conf"
	local TMP_WIFIDOG_CONFIG_PATH="/var/etc/wifidog_tmp.conf"
	local ifname

	config_get_bool wifi_disabled $dev disabled       #hardware switch
	config_get_bool soft_disabled $dev disabled_all   #software switch

	if [ $(uci_get_state systime core sync) -ne 1 ]; then
		config_get wifi_disabled_by $dev disabled_by
		if [ "$wifi_disabled_by" = "1" ]; then
			wifi_disabled=0
		fi
	fi
	if [ "$wifi_disabled" = "0" -a "$soft_disabled" = "0" ]; then
		config_get vifs $dev vifs	
		
		for vif in $vifs; do
			config_get_bool enable $vif enable
			config_get mode $vif mode
			config_get guest $vif guest
			if [ "$enable" = "1" -a "$mode" = "ap" -a -z "$guest" ]; then
				eth_enable="1"
			elif [ "$mode" = "ap" -a "$guest" = "on" ]; then
				eth_enable="1"
				guest_enable="1"
				guest_vif="$vif"
			elif [ "$enable" = "1" -a "$mode" = "sta" ]; then
				eth_enable="1"
				wds_enable="1"
			else
				echo "=====>>>>> $dev: vif $vif is disabled" >$STDOUT
			fi
		done
	fi
	if [ "$eth_enable" = "1" -a "$guest_enable" = "1" ]; then
		vif="$guest_vif"
		config_get ifname $vif ifname
		config_get encryption $vif encryption

		if [ "$encryption" == "portal" ]; then

			if [ -n "${PORTAL_IFNAMES}" ]; then
				PORTAL_IFNAMES="${ifname} ${PORTAL_IFNAMES}"
			else
				PORTAL_IFNAMES="${ifname}"
			fi

			if [ "${PORTALSET}" = "0" ]; then
				PORTALSET="1"
				local brname
				get_brname brname

				config_get authentication_type $vif authentication_type
				config_get portal_password $vif portal_password
				config_get authentication_timeout $vif authentication_timeout
				config_get redirect $vif redirect
				config_get redirect_url $vif redirect_url
				config_get content $vif content
				config_get title $vif title
				config_get ifname $vif ifname
				config_get font_color $vif font_color
				config_get theme_color $vif theme_color
				config_get font_opacity $vif font_opacity
				config_get theme_opacity $vif theme_opacity

				content=$(wifi_portal_content_title_extend $content)
				title=$(wifi_portal_content_title_extend $title)

				touch $USER_WIFIDOG_CONFIG_PATH
				cp $DEFAULT_WIFIDOG_CONFIG_PATH  $TMP_WIFIDOG_CONFIG_PATH

				if [ -n "$authentication_type" ]; then
					sed	-e "/RAPGatewayInterface/a GatewayInterface $brname"\
					-e "/RAPAuthType/a AuthType $authentication_type"\
					-e "/RAPAuthPassword/a AuthPassword $portal_password"\
					-e "/RAPRediEnable/a RediEnable $redirect"\
					-e "/RAPRediUrl/a RediUrl $redirect_url"\
					-e "/RAPAuthTitle/a AuthTitle $title"\
					-e "/RAPAuthTerm/a AuthTerm $content"\
					-e "/RAPAuthFontColor/a AuthFontColor $font_color"\
					-e "/RAPAuthThemeColor/a AuthThemeColor $theme_color"\
					-e "/RAPAuthFontOpacity/a AuthFontOpacity $font_opacity"\
					-e "/RAPAuthThemeOpacity/a AuthThemeOpacity $theme_opacity"\
					-e "/RAPAuthTimeout/a AuthTimeout $authentication_timeout"\
						$TMP_WIFIDOG_CONFIG_PATH > $USER_WIFIDOG_CONFIG_PATH
					rm $TMP_WIFIDOG_CONFIG_PATH
				else
					mv $TMP_WIFIDOG_CONFIG_PATH $USER_WIFIDOG_CONFIG_PATH
				fi

				[ -e $USER_WIFIDOG_CONFIG_PATH ] && [ ! -s $USER_WIFIDOG_CONFIG_PATH ] && echo "error: wifidog.conf is empty" > /dev/console
				setyet="1"
			fi
		fi
	fi

}

wifi_portal_config() {
	PORTALSET="0"
	PORTAL_IFNAMES=""
	
	for dev in ${DEVICES}; do  
		wifi_portal_set_config $dev
	done

	if [ -n "${PORTAL_IFNAMES}" ];then
		if ps | grep -v grep| grep 'wifidog' > /dev/null;then
			local timer=0
			while [ $timer -lt 3 ]
			do
				if ! netstat -ap -x 2>/dev/null | grep -q 'LISTENING.*wifidog';then
					echo "wifidog is not in listening, waiting for a while" > /dev/console
					sleep 5
				else
					break
				fi
				timer=$(($timer+1))
			done
			/etc/init.d/wifidog restart
		else
			/etc/init.d/wifidog start
		fi
                
		echo "PORTAL_IFNAMES ${PORTAL_IFNAMES}" > /dev/console
		echo "${PORTAL_IFNAMES}" > /proc/portal_filter/portal_interface_list
	else
		if ps | grep -v grep| grep 'wifidog' > /dev/null;then
			/etc/init.d/wifidog stop
			echo "no portal ifnames, wifidog end" > /dev/console
		fi
	fi
}

wifi_reload() {
	[ -d /sys/class/net/wifi0 ] || load_qcawificfg80211

	local product_name=$(uci get system.system.hostname)
	if [ "$product_name" = "Archer_Air_R5" ]; then
		if [ "$(/sbin/is_cal)" = "true" ]; then
			[ -f /tmp/dut_bootdone ] && ledcli WAN0_OFF && ledcli WAN1_OFF && ledcli WPS_OFF_ONLY
		fi
	else
		[ -f /tmp/dut_bootdone ] && ledcli WPS_OFF
	fi

	config_foreach led_ctrl wifi-device
	
	wifi_radio "$1" "txchainmask rxchainmask AMPDU ampdudensity !AMSDU AMPDULim AMPDUFrames AMPDURxBsize !bcnburst:set_bcnburst=0 \
		set_smart_antenna:setSmartAntenna current_ant default_ant ant_retrain retrain_interval retrain_drop ant_train ant_trainmode \
		ant_traintype ant_pktlen ant_numpkts ant_numitr ant_train_thres:train_threshold ant_train_min_thres:train_threshold \
		ant_traffic_timer:traffic_timer dcs_enable dcs_coch_int:set_dcs_coch_int dcs_errth:set_dcs_errth dcs_phyerrth:set_dcs_phyerrth \
		dcs_usermaxc:set_dcs_usermaxc dcs_debug:set_dcs_debug set_ch_144:setCH144 !ani_enable !acs_bkscanen acs_scanintvl acs_rssivar \
		acs_chloadvar acs_lmtobss acs_ctrlflags acs_dbgtrace !dscp_ovride:set_dscp_ovride reset_dscp_map dscp_tid_map:set_dscp_tid_map \
		!igmp_dscp_ovride:sIgmpDscpOvrid igmp_dscp_tid_map:sIgmpDscpTidMap !hmmc_dscp_ovride:sHmmcDscpOvrid hmmc_dscp_tid_map:sHmmcDscpTidMap \
		!blk_report_fld:setBlkReportFld !drop_sta_query:setDropSTAQuery !burst burst_dur TXPowLim2G TXPowLim5G !enable_ol_stats \
		!rst_tso_stats !rst_lro_stats !rst_sg_stats !set_fw_recovery !allowpromisc set_sa_param !aldstats \
		!led_enable promisc block_interbss aggr_burst set_pmf txbf_snd_int=100 mcast_echo obss_rssi_th=35 obss_rx_rssi_th=35 discon_time=10 reconfig_time=60 disablestats enable_macreq=1"
	if [ -f "/lib/update_smp_affinity.sh" ]; then
		. /lib/update_smp_affinity.sh
		config_foreach enable_smp_affinity_wifi wifi-device
	fi

	local portal_support=`uci get profile.@portal[0].portal_support -c "/etc/profile.d"`
	if [ "$portal_support" = "yes" ]; then
		wifi_portal_config
	fi
	
	ubus send meshd.wifi_reload_complete
	if [ "$( cat /tmp/meshd_inited )" != "1" ]; then
		echo "=====>>>>> start meshd" >$CONSOLE
		/etc/init.d/meshd stop
		/etc/init.d/meshd start
		echo 1 > /tmp/meshd_inited
	fi
}

wifi_macfilter() {
	case $1 in
	add|del)
		config_get_bool enable filter enable
		[ "$enable" = "1" ] && for dev in $DEVICES; do
			config_get vifs "$dev" vifs
			for vif in $vifs; do 
				[ -d /sys/class/net/$vif -a "$(config_get $vif mode)" = "ap" ] && cfg80211tool "$vif" "$1"mac "${2//-/:}" && cfg80211tool "$vif" kickmac "${2//-/:}";
			done
		done
	;;
	kickall)
		for dev in $DEVICES; do
			config_get vifs "$dev" vifs
			for vif in $vifs; do 
				[ -d /sys/class/net/$vif -a "$(config_get $vif mode)" = "ap" ] && cfg80211tool "$vif" kickmac "ff:ff:ff:ff:ff:ff";
			done
		done
		;;
	*)
		for dev in $DEVICES; do
			local vaps=""
			config_get vifs "$dev" vifs
			for vif in $vifs; do 
				[ -d /sys/class/net/$vif -a "$(config_get $vif mode)" = "ap" ] && config_vap_acl "$vif" &>$STDOUT
			done
		done
	;;
	esac
}

wifi_wps() {
	local wps_cmd dev phy wps vif="$1"
	config_get_bool wps "$vif" wps 0
	config_get timeout "$vif" wps_timeout 120
	config_get dev "$vif" device
	config_get phy "$dev" phy

	wps_cmd="/usr/sbin/hostapd_cli -p /var/run/hostapd-$phy -i $vif"

	if [ "$wps" = "1" -a -e "/var/run/hostapd-$phy/$vif" ]; then
		case $2 in
		ap_pin)
			if [ "$3" = "disable" ]; then
				$wps_cmd wps_ap_pin disable
			elif [ "$($wps_cmd wps_check_pin $3)" = "$3" ]; then
				$wps_cmd wps_ap_pin set "$3" 0
			else
				echo "FAIL"
			fi;;
		pin)
			if [ "$($wps_cmd wps_check_pin $3)" = "$3" ]; then
				$wps_cmd wps_pin any "$3" "$timeout"
			else
				echo "PIN Status: Invalid"
			fi;;
		pbc) 		 $wps_cmd wps_pbc;;
		status)	 $wps_cmd wps_get_status;;
		cancel)	 $wps_cmd wps_cancel;;
		config)	 $wps_cmd get_config;;
		pin_lock)	$wps_cmd pin_lock_status;;
		*)shift 1;$wps_cmd $*;;
		esac
		echo ""
	fi
}

wifi_wps_switch() {
	wifi_reload
}

wifi_vlan() {
	config_vap_vlan &>$STDOUT
}

wifi_default() {
	local idx=0 flag_5g2=0
	cd /sys/class/net/
	[ -d wifi0 ] || load_qcawificfg80211
	for dev in $(ls -d wifi* 2>$STDOUT); do
		case "$(cat ${dev}/hwcaps)" in
			*11bgn) mode_11=ng;band="2g";;
			*11abgn) mode_11=ng;band="2g";;
			*11an) mode_11=na;band="5g";;
			*11an/ac) mode_11=ac;band="5g";;
			*11abgn/ac) mode_11=ac;band="5g";;
		esac
		
		if [ "$band" = "5g" ]; then
			if [ "$flag_5g2" = "0" ]; then
				flag_5g2=1
			else
				band="5g_2"
			fi
		fi

		[ "$(config_get wifi${idx} type)" = "qcawifi" ] || cat <<EOF
config wifi-device 'wifi${idx}'
	option type 'qcawifi'
	option phy 'wifi${idx}'
	option band '${band}'
	option macaddr '$(cat /sys/class/net/${dev}/address)'
	option country 'US'
	option hwmode '${mode_11}'
	option htmode 'auto'
	option channel 'auto'
	option txpower 'high'
	option beacon_int '100'
	option rts '2346'
	option frag '2346'
	option wpa_group_rekey '0'
	option dtim_period '1'
	option wmm 'on'
	option shortgi 'on'
	option isolate 'off'
	option disabled 'off'
	option disabled_all 'off'

EOF

		[ "$(config_get ath${idx} device)" = "wifi${idx}" ] || cat <<EOF
config wifi-iface 'ath${idx}'
	option ifname 'ath${idx}'
	option device 'wifi${idx}'
	option mode 'ap'
	option wds 'on'
	option wps 'on'
	option wps_pbc 'on'
	option wps_state '1'
	option wps_label 'on'
	option wps_pin '12345670'
	option wps_timeout '120'
	option enable 'off'
	option hidden 'off'
	option ssid 'TP-LINK_HOME_${band//g/G}'
	option encryption 'none'
	option wep_mode 'auto'
	option wep_select '1'
	option wep_format1 'asic'
	option wep_type1 '64'
	option wep_key1 ''
	option wep_format2 'asic'
	option wep_type2 '64'
	option wep_key2 ''
	option wep_format3 'asic'
	option wep_type3 '64'
	option wep_key3 ''
	option wep_format4 'asic'
	option wep_type4 '64'
	option wep_key4 ''
	option psk_key ''
	option psk_version 'auto'
	option psk_cipher 'auto'
	option server ''
	option port '1812'
	option wpa_key ''
	option wpa_version 'auto'
	option wpa_cipher 'auto'

EOF

		[ "$(config_get ath${idx}1 device)" = "wifi${idx}" ] || cat <<EOF
config wifi-iface 'ath${idx}1'
	option ifname 'ath${idx}1'
	option device 'wifi${idx}'
	option mode 'ap'
	option wds 'on'
	option guest 'on'
	option enable 'off'
	option hidden 'off'
	option ssid 'TP-LINK_GUEST_${band//g/G}'
	option encryption 'none'
	option psk_key ''
	option psk_version 'auto'
	option psk_cipher 'auto'
	option isolate 'on'
	option access 'off'

EOF

		[ "$(config_get ath${idx}2 device)" = "wifi${idx}" ] || cat <<EOF
config wifi-iface 'ath${idx}2'
	option ifname 'ath${idx}2'
	option device 'wifi${idx}'
	option mode 'sta'
	option wds 'on'
	option wds_mode '2'
	option enable 'off'
	option ssid ''
	option bssid ''
	option encryption 'none'
	option psk_key ''
	option psk_version 'auto'
	option psk_cipher 'auto'
	option wep_mode 'auto'
	option wep_select '1'
	option wep_format1 'asic'
	option wep_type1 '64'
	option wep_key1 ''
	option wep_format2 'asic'
	option wep_type2 '64'
	option wep_key2 ''
	option wep_format3 'asic'
	option wep_type3 '64'
	option wep_key3 ''
	option wep_format4 'asic'
	option wep_type4 '64'
	option wep_key4 ''

EOF
	idx=$(($idx + 1))
	done

	[ "$(config_get filter action)" != "" ] || cat <<EOF
config mac-filter 'filter'
	option enable 'off'
	option action 'deny'

EOF

	[ "$(config_get wps model_name)" != "" ] || cat <<EOF
config wps-device 'wps'
	option wps_uuid '87654321-9abc-def0-1234'
	option wps_device_type '6-0050F204-1'
	option wps_device_name 'TL-AC1900'
	option wps_manufacturer 'TP-LINK Technologies Co., Ltd.'
	option wps_manufacturer_url 'www.tp-link.com'
	option model_name 'TL-AC1900'
	option model_number '1.0'
	option model_url 'http://192.168.1.1:80/'
	option serial_number 'ac1900'
	option os_version '1.0'

EOF
}

wifi_cca_threshold_set() {
	local dev="$1"
	config_get band "$dev" band
	local country=$(getfirm COUNTRY)
	local cca=$(uci get profile.@wireless[0].cca_threshold_${band}_${country} -c /etc/profile.d)
	local wireless_ifname=$(uci get profile.@wireless[0].wireless_ifname_${band} -c /etc/profile.d)
	local wireless_mesh_ifname=$(uci get profile.@wireless[0].wireless_mesh_ifname_${band} -c /etc/profile.d)
	local timeout=3700
	local interval=5
	local retry=0
	local start_timestamp
	cca_lock_dir="/tmp/lock/cca_threshold_${band}"
	cca_lock_file="/tmp/lock/cca_threshold_${band}.lock"

	#if cca is set, the set is used, otherwise the BDF default is used
	[ -z "$cca" ] && { echo "use BDF cca_threshold" > /dev/console;return; }

	#mkdir in linux is an atomic operation
	if mkdir "$cca_lock_dir" ; then
		lock "$cca_lock_file"
		touch "$cca_lock_file";	#refresh the file modification event stamp
		start_timestamp=$(date -r "$cca_lock_file" "+%H:%M:%S" )
		lock -u "$cca_lock_file"
		trap 'rm -rf "$cca_lock_dir";' EXIT SIGTERM SIGINT
	else
		#if the folder is not successfully created, CCA monitoring is currently underway, so the timestamp is renewed
		lock "$cca_lock_file"
		touch "$cca_lock_file"; #refresh the file modification event stamp
		lock -u "$cca_lock_file"
		echo "If no lock is obtained, execution is skipped. Procedure" > /dev/console
		return
	fi

	while true; do
		#if the timestamp read this time is different from the last time, another shell process has accessed it, and start_timestamp and start_time need to be updated
		local current_timestamp=$(date -r "$cca_lock_file" "+%H:%M:%S" )
		if [ "$current_timestamp" != "$start_timestamp" ];then
			retry=0
			start_timestamp="$current_timestamp"
			echo "refresh the start_time" > /dev/console
		fi

		local cac_state_host=$(iwconfig "$wireless_ifname" 2>/dev/null  | grep -i 'Bit Rate:' | awk '{print $2}' | sed 's/[^0-9.]//g')
		local cac_state_mesh=$(iwconfig "$wireless_mesh_ifname" 2>/dev/null | grep -i 'Bit Rate:' | awk '{print $2}' | sed 's/[^0-9.]//g')
		local status_host=$(uci get wireless.${wireless_ifname}.enable)
		local status_mesh=$(uci get onemesh.${wireless_mesh_ifname}.enable)

		if [ "$status_host" != "on" ] && [ "$status_mesh" != "on" ];then
			echo "all vaps are disabled. You do not need to set the cca threshold" > /dev/console
			break
		fi

		if [ -n "$cac_state_host" ] && [ "$cac_state_host" != "0" ] || [ -n "$cac_state_mesh" ] && [ "$cac_state_mesh" != "0" ];then
			cfg80211tool "$dev" cca_threshold "$cca"
			echo "wifi_cca_threshold_set set $band cca_threshold $cca success" > /dev/console
			break
		fi

		if [ $(( retry * interval )) -ge $timeout ];then
			echo "wifi_cca_threshold_set timeout " > /dev/console
			break
		fi

		retry=$(( retry + 1 ))
		sleep $interval
	done
	rm -rf "$cca_lock_dir"
}
