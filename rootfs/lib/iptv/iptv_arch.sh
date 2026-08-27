
# Copyright (C) 2011-2014 TP-LINK

#### Notice: global variable defined in this file can't be changed

#
# vlan id generation method type
# 0 : generate nothing(initial value)
# 1 : generate single vlan tag automaticly
# 2 : generate dual vlan tag automaticly
# 3 : generate in specific way
# 
gen_vid_mode=1

#
# wan interface vlan id generation method type
# 0 : generate nothing for internet tag off mode
# 1 : generate internet vlan interface for internet tag off mode
# 
gen_wan_vid_mode=1

#
# disable vlan id conflict with iptv wan vids set when gen_vid_mode is 1/2/3
# 0 : not to solve conflict vid generated
# 1 : need to solve conflict vid generated(initial value)
#
disable_conflict=1

#
# specific vlan id sequence to lan port which effect when gen_vid_mode is 3 or 4
# initial value is none
#
specific_lan_vid=""

#
# specific tx vlan id sequence to lan port which effect when gen_vid_mode is 4
# initial value is none
#
specific_lan_txvid=""

#
# Wan default vid
# initial value is 0
#
WAN_DFT_ID="0"

#VLAN setting API
clear_switch_vlan()
{
	echo reset > /proc/driver/rtl8367s/vlan
	echo init > /proc/driver/rtl8367s/vlan
}

#new arch VLAN setting
#1 VID
#2 member
#3 tag
#4 CPU
set_switch_vlan()
{
	echo "0000000 vid=$1 mem=$2 tag=$3 cpu=$4"
	local vid="$1"
	local member="$2"
	local memberMask=0
	local tagged="$3"
	local untaggedMask=0
	local cpu="$4"
	local port=0
	
	[ "$vid" -gt 0 ] || return
	
	#set pvid
	for port in $member; do
		if [ "$tagged" == "off" ]; then
			untaggedMask=$((untaggedMask|(1<<$port)))
			echo pvid set $port $vid 0 > /proc/driver/rtl8367s/port
			echo pvid set:$port $vid > /dev/console
		fi
		memberMask=$((memberMask|(1<<$port)))
	done
	
	if [ "$cpu" -eq 1 ]; then
		for port in ${CPU1_PHY_PORT_SET}; do
			memberMask=$((memberMask|(1<<$port)))
		done
	elif [ "$cpu" -eq 2 ]; then
		for port in ${CPU2_PHY_PORT_SET}; do
			memberMask=$((memberMask|(1<<$port)))
		done
	fi
	
	echo "1111111 vid=$vid memberMask=$memberMask untaggedMask=$untaggedMask" > /dev/console
	
	#set vlan
	echo set $vid $memberMask $untaggedMask > /proc/driver/rtl8367s/vlan
}
