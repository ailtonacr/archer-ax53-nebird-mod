######### Switch APIs for BCM470X board #########

#Registers
local PAGE_VLAN=0x34
local REG_VLAN_PTAG=0x10	# REG_VLAN_PTAG0 - REG_VLAN_PTAG8: 0x10 - 0x18
#Registers

local PAGE_VTBL=0x05
local REG_VTBL_ENTRY=0x83
local REG_VTBL_INDEX=0x81
local REG_VTBL_ACCESS=0x80

#Registers
local PAGE_GPHY=0x10

#Switch ports & vlans, saved in /etc/config/switch?
local LAN_PORTS="1 2 3 4"
local WAN_PORTS="0"
local CPU_PORTS="16"
local MAX_VLAN="4095"

local support_gmac3=$(uci get profile.@gmac3[0].support_gmac3 -c "/etc/profile.d" -q)

log () {
	#echo "$@" >> /dev/console
	echo "$@" >> /dev/null
}

et_d () {
	log "et $@"
	if [ "$support_gmac3" = "yes" ];then
		et -i eth0 $@
	else
		et $@
	fi
}

core_phy_init() {	#	<lan ports> <wan ports> <cpu ports>
	if [ $# -eq 3 ] ;
	then 
		LAN_PORTS=${1:-$LAN_PORTS}
		WAN_PORTS=${2:-$WAN_PORTS}
		CPU_PORTS=${3:-$CPU_PORTS}
	fi
	
	log "\$LAN_PORTS=\"$LAN_PORTS\" \$WAN_PORTS=\"$WAN_PORTS\" \$CPU_PORTS=\"$CPU_PORTS\""
}

phy_lan_is_linked () {	# given port or any lan ports
	local port="$1"
	
	if [ -n "$port" ] ;
	then
		if [ -n "$(echo $LAN_PORTS | grep $(($port + 0)))" ] ;
		then
			[ -n "$(et_d port_status $port | grep Up)" ] && return 0;
		fi
	else
		for p in $LAN_PORTS
		do
			[ -n "$(et_d port_status $p | grep Up)" ] && return 0;
		done
	fi
	
	return 1;
}

phy_wan_is_linked () {	# given port or any wan ports
	local port="$1"
	
	if [ -n "$port" ] ;
	then
		if [ -n "$(echo $WAN_PORTS | grep $(($port + 0)))" ] ;
		then
			[ -n "$(et_d port_status $port | grep Up)" ] && return 0;
		fi
	else
		for p in $WAN_PORTS
		do
			[ -n "$(et_d port_status $p | grep Up)" ] && return 0;
		done
	fi
	
	return 1;
}

setup_port_vlan() {	#	<port> <vid>
	local port=$1
	local vid=$2
	
	if [ "$support_gmac3" = "yes" ];then
		et_d robowr $PAGE_VLAN $(($REG_VLAN_PTAG + (2 * $port))) $vid 2
	else
		et_d robowr $PAGE_VLAN $(($REG_VLAN_PTAG + (2 * $port))) $vid
	fi
}

setup_member_vlan() {	#	<vid> <memberMap> <untagMap>
	local map=$((($3 << 9) | $2))	#bit 0-8:	member group bits
									#bit 9-17:	untag bits
	if [ "$support_gmac3" = "yes" ];then
		et_d robowr $PAGE_VTBL $REG_VTBL_ENTRY $map 4
	else
		et_d robowr $PAGE_VTBL $REG_VTBL_ENTRY $map
	fi
	
	local vid=$1
	if [ "$support_gmac3" = "yes" ];then
		et_d robowr $PAGE_VTBL $REG_VTBL_INDEX $vid 2
	else
		et_d robowr $PAGE_VTBL $REG_VTBL_INDEX $vid
	fi
	
	local access=$(((0x1<<7)|0x0))	#bit 7:		start command
									#bit 0-1:	write
	if [ "$support_gmac3" = "yes" ];then
		et_d robowr $PAGE_VTBL $REG_VTBL_ACCESS $access 1
	else
		et_d robowr $PAGE_VTBL $REG_VTBL_ACCESS $access
	fi
}

clear_vlan_table() {
	local access=$(((0x1<<7)|0x02))	#bit 7:		start command
									#bit 0-1:	10--->clear-table
	if [ "$support_gmac3" = "yes" ];then
		et_d robowr $PAGE_VTBL $REG_VTBL_ACCESS $access 1
	else
		et_d robowr $PAGE_VTBL $REG_VTBL_ACCESS $access
	fi
}

clear_all_vlans() {
	local vid
	local port
	
	for port in $LAN_PORTS
	do
		setup_port_vlan $port 0		# set all ports's default vlan is 0
	done

	clear_vlan_table
}

setup_switch_vlan() {	#	<vid> <port>{u} <port>{u}...
	#switch, only 6ports: 4 LAN ports, 1 WAN port, 1 CPU port

	local vid="$1"
	local port
	local flag
	
	local memberMap=0	#6 bits, ports
	local untagMap=0	#6 bits, ports
	
	shift
	log "ports=$@"
	while [ -n "$1" ]
	do

		$(echo "$1" | grep -Eq "[0-8][\*ut]?") || { 
			log "SWITCH: the format of port is incorrect!"
			exit 1; 
		}

		port=${1:0:1}
		flag=${1:1}

		memberMap=$(($memberMap | (0x1 << $port)))

		# non-cpu port should be untaged
		if $(echo "$CPU_PORTS" | grep -Eq "$port")
		then
			# flag "u" tell untag
			$(echo "$flag" | grep -Eq "u") && {
				setup_port_vlan $port $vid
				untagMap=$(($untagMap | (0x1 << $port)))
			}
		else
			setup_port_vlan $port $vid
			# flag "t" tell tag
			$(echo "$flag" | grep -Eq "t") || {
				untagMap=$(($untagMap | (0x1 << $port)))
			}
		fi

		shift
	done

	setup_member_vlan $vid $memberMap $untagMap
}

link_down_phy_port () {	# <port>
	local port=$1
	
	echo set $port 0 > /proc/driver/rtl8367s/phy
}

link_up_phy_port () {	# <port>
	local port=$1
	
	echo set $port 1 > /proc/driver/rtl8367s/phy
}

link_down_lan_ports() {
	for port in $LAN_PORTS
	do
		link_down_phy_port $port
	done

	log "lan ports is linked down!"
}	

link_up_lan_ports () {
	for port in $LAN_PORTS
	do
		link_up_phy_port $port
	done
	
	log "lan ports is linked up!"
}

link_down_wan_ports() {
	for port in $WAN_PORTS
	do
		link_down_phy_port $port
	done

	log "wan ports is linked down!"
}	

link_up_wan_ports () {
	for port in $WAN_PORTS
	do
		link_up_phy_port $port
	done
	
	log "wan ports is linked up!"
}

link_down_all_ports () {
	#add by wanghao
	echo linkup 0 > /proc/driver/rtl8367s/phy
	#add end
	
	log "switch ports is linked down!"
}

link_up_all_ports () {
	local lan_ports=$(uci get switch.lan.ports -q)
	local wan_ports=$(uci get switch.wan.ports)
	local ports="$lan_ports $wan_ports"
	local giga_lite_state=$(uci get giga_lite.giga_lite.enable -q)
	local sysmode=$(uci get sysmode.sysmode.mode)
	local jumbo_frame_support=$(uci get profile.@jumbo_frame[0].jumbo_frame_support -c "/etc/profile.d" -q)
	local length_switch
	local leghth_gmac

	#add by wanghao
	echo 1 > /proc/driver/rtl8367s/sgmii
	#added by gaokaiwu, cpu port only accept tagged frames, accept all frames by default.
	echo ptype set $CPU_PORTS 1 > /proc/driver/rtl8367s/port

	#added by liuzhe, check giga lite
	if [ x"$giga_lite_state" = x"on" ] ; then
		for p in $ports
		do
			echo pgigalite set $p 1 > /proc/driver/rtl8367s/port
		done
	else
		for p in $ports
		do
			echo pgigalite set $p 0 > /proc/driver/rtl8367s/port
		done
	fi
	
	#check jumbo frame
	if [ x"$jumbo_frame_support" = x"yes" ] ; then
		if [ x"$jumbo_frame_state" = x"on" ] ; then
			#switch: default;	GMAC: 9014
			length_switch=16368
			length_gmac=0x2336
		else
			#switch: limited;	GMAC: default
			length_switch=1536
			length_gmac=0x5F6
		fi
		echo maxpktlen set 0 $length_switch > /proc/driver/rtl8367s/port
		echo 0 > /sys/ssdk/dev_id
		ssdk_sh port framemaxsize set 2 $length_gmac
	fi
	echo linkup 1 > /proc/driver/rtl8367s/phy
	
	#Enable 0 pause time support and disable TX pause
	ssdk_sh port flowCtrl set 2 enable
	devmem 0x39D00018 32 0xFFFF0004
	#add end
	
	log "switch ports is linked up!"
}

bit_set()	# val, pos1, pos2 ...
{
	val=$1
	
	shift

	while [ $# -ne 0 ]
	do
		pos=$1
		val=$(($val | (1 << $pos)))
		shift
	done

	echo $val
}

bit_clear()	# val, pos1, pos2 ...
{
	val=$1

	shift

	while [ $# -ne 0 ]
	do
		pos=$1
		val=$(($val & (~(1 << $pos))))
		shift
	done
	
	echo $val
}

to_hexstr()
{
	echo "0x"$(printf %x $1)
}

set_port_duplex () {	#	<port> <rate> <duplex> <auto>
	local port=$1
	local rate=$2
	local duplex=$3
	local auto=$4
	local rateduplex="$rate$duplex"
	local mask=0
	local lan_ports=$(uci get switch.lan.ports)
	local wan_ports=$(uci get switch.wan.ports)
	local sysmode=$(uci get sysmode.sysmode.mode)
	local fc_port
	local fc_tx
	local fc_rx
	local wan_fc_get_done=0
	local fc_val
	local ports
	
	for fc_port in $wan_ports; do
		if [ $fc_port == $port ]; then
			if [ $sysmode == "ap" ]; then
				fc_tx=$(uci get switch.lan.fc_tx)
				fc_rx=$(uci get switch.lan.fc_rx)
			else
				fc_tx=$(uci get switch.wan.fc_tx)
				fc_rx=$(uci get switch.wan.fc_rx)
			fi
			wan_fc_get_done=1
			ports=$wan_ports
			break
		fi
	done
       
	if [ $wan_fc_get_done -eq 0 ]; then
		for fc_port in $lan_ports; do
			if [ $fc_port == $port ]; then
				fc_tx=$(uci get switch.lan.fc_tx)
				fc_rx=$(uci get switch.lan.fc_rx)
				ports=$lan_ports
				break
			fi
		done
	fi
	
	fc_val=$((fc_tx<<1|fc_rx))
	#The switch value of flow control is not exactly the same as ASYM Pause and SYM pause
	if [ $fc_val -eq 1 ];then
		fc_val=3
	fi
	
	case $auto in
		"on")
			mask=0x11111
			;;
		"off")
			case $rateduplex in
				"1000full")
					mask=0x10000
					;;
				"100full")
					mask=0x01000
					;;
				"100half")
					mask=0x00100
					;;
				"10full")
					mask=0x00010
					;;
				"10half")
					mask=0x00001
					;;
				*)
					return
					;;
			esac
			;;
		*)
			return
			;;
	esac
	
	for port in $ports; do
		echo fc_mode set $port $mask $fc_val > /proc/driver/rtl8367s/phy
	done
}

set_defaut_duplex_all_ports()
{
	for port in $LAN_PORTS $WAN_PORTS
	do
		set_port_duplex "$port" "1000" "full" "on"
	done
}

local REG_ARLA_SRCH_CTL=0x50
local REG_ARLA_SRCH_RSLT_0_MACVID=0x60
local REG_ARLA_SRCH_RSLT=0x68
local REG_ARLA_SRCH_RSLT_1_MACVID=0x70
local REG_ARLA_SRCH_RSLT_1=0x78

dump_arl_table()
{
	local val8
	local val32
	local val64

	# write 1 to bit 7 Page 5, address 0x50 
	et -i eth0 robowr $PAGE_VTBL $REG_ARLA_SRCH_CTL 0x80

	val8=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_CTL)
	val8=$(($val8 & 0x81))

	while [ $val8 -ne 0 ]
	do
		val64=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_RSLT_0_MACVID 8)
		val32=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_RSLT 4)

		if [ $(($val64)) -ne 0 -a $(($val8 & 0x01)) -ne 0 ];
		then
			dump_arl_table_entry $val64 $val32
		fi

		val64=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_RSLT_1_MACVID 8)
		val32=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_RSLT_1 4)

		if [ $(($val64)) -ne 0 -a $(($val8 & 0x01)) -ne 0 ];
		then
			dump_arl_table_entry $val64 $val32
		fi

		val8=$(et -i eth0 robord $PAGE_VTBL $REG_ARLA_SRCH_CTL)
		val8=$(($val8 & 0x81))
	done

}

dump_arl_table_entry() # macv, status
{
	local val64=$(($1))
	local val32=$(($2))

	local macn=$(($val64 & 0x0000FFFFFFFFFFFF))
	local vidn=$((($val64 & 0x0FFF000000000000) >> 48))
	local prtn=$(($val32 & 0x1FF))

	printf "%012llx 0x%0llx %d 0x%08x\n" $macn $vidn $prtn $val32
}

###### Aggregation Port ######
local PAGE_MAC_TRUNK=0x32
local REG_MAC_TRUNK_CTL=0x00
local REG_GRP_TRUNK_CTL1=0x10
local REG_GRP_TRUNK_CTL2=0x12

config_agg_ports_static() #ports
{
	local ports=$1
	local pbits=$(bit_set 0 $ports)
	et_d robowr $PAGE_MAC_TRUNK $REG_MAC_TRUNK_CTL 0x08
	et_d robowr $PAGE_MAC_TRUNK $REG_GRP_TRUNK_CTL1 $pbits
}

config_agg_ports_dynamic() # ports, lacpmode, systemprio, portprio
{
	local ports="$1"
	local pmode="$2"
	local syprio="$3"
	local ptprio="$4"

# stop
	ifconfig eth0.1 down
	nvram set lacp_enabled=1
	nvram set lacp=1
	nvram set lacpdev="eth0.1"	
	nvram set lacpmode="$pmode"
	nvram set lacpports="$ports"
#	nvram set lacpsysprio="$syprio"
#	nvram set lacpportprio="$ptprio"

	insmod lacp
# start
	ifconfig eth0.1 up
}

config_agg_clear()
{
	ifconfig eth0.1 down
	et_d robowr $PAGE_MAC_TRUNK $REG_MAC_TRUNK_CTL 0x0
	et_d robowr $PAGE_MAC_TRUNK $REG_GRP_TRUNK_CTL1 0x0
	et_d robowr $PAGE_MAC_TRUNK $REG_GRP_TRUNK_CTL2 0x0
	nvram set lacp_enabled=0
	if [ "x$(lsmod | grep lacp)" != "x" ] ;then
		rmmod lacp
	fi
	ifconfig eth0.1 up
}

config_agg_ports() # mode, ports, { lacpmode, systemprio, portprio}
{
	local mode="$1"
	local ports="$2"

	shift
	shift

	config_agg_clear

	case $mode in
		"static" )
			config_agg_ports_static "$ports"
			;;
		"dynamic" )
			config_agg_ports_dynamic "$ports" "$@"
			;;
		* )
			return
			;;
	esac
}
