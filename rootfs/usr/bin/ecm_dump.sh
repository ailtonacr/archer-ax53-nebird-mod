#!/bin/sh
#
# Copyright (c) 2015-2016, The Linux Foundation. All rights reserved.
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

#now,there is only "ecm_state" in /dev/ecm/, so make it a bit direct
ECM_MODULE=ecm_state
MOUNT_ROOT=/dev/ecm

#
# usage: ecm_dump.sh [module=ecm_db]
#
# with no parameters, ecm_dump.sh will attempt to mount the
# ecm_db state file and cat its contents.
#
# example with a parameter: ecm_dump.sh ecm_classifier_default
#
# this will cause ecm_dump to attempt to find and mount the state
# file for the ecm_classifier_default module, and if successful
# cat the contents.
#

# this is one of the state files, which happens to be the
# last module started in ecm
ECM_STATE=/sys/kernel/debug/ecm/ecm_state/state_dev_major

# tests to see if ECM is up and ready to receive commands.
# returns 0 if ECM is fully up and ready, else 1
ecm_is_ready() {
	if [ ! -e "${ECM_STATE}" ]
	then
		return 1
	fi
	return 0
}

#
# module_state_mount(module_name)
#      Mounts the state file of the module, if supported
#
module_state_mount() {
	local module_name=$1
	local mount_dir=$2
	local state_file="/sys/kernel/debug/ecm/${module_name}/state_dev_major"

	if [ -e "${mount_dir}/${module_name}" ]
	then
		# already mounted
		return 0
	fi

	#echo "Mount state file for $module_name ..."
	if [ ! -e "$state_file" ]
	then
		#echo "... $module_name does not support state"
		return 1
	fi

	local major="`cat $state_file`"
	#echo "... Mounting state $state_file with major: $major"
	mknod "${mount_dir}/${module_name}" c $major 0
}

#
# main
#
ecm_is_ready || {
	#echo "ECM is not running"
	exit 1
}

# all state files are mounted under MOUNT_ROOT, so make sure it exists
mkdir -p ${MOUNT_ROOT}

usage(){
cat << EOF
	1.show ecm_state_related info
	ecm_dump.sh { [OPTION] [level VALUE] }
	OPTION:=[ "connection" | "mapping" | "host" | "node" | "interface" | "conn_chain" | 
			"map_chain" | "host_chain" | "node_chain" | "inf_chain" | "prot_count" | ]
			(default "connection") 
	VALUE:=[ 0 | 1 | 2 ]
			(default 2)
	eg. 
		ecm_dump.sh [connection] level 1
		ecm_dump.sh mapping level 2

	2.show miscellaneous stuff
	ecm_dump.sh { [OPTION] }
	OPTION:+=[ "count [all]" | "enable" | "defunct" | "gradient" | "stop" | "start" 
	| "defunct_by_tuple src_ip(hex) src_port(hex) dst_ip(hex) dst_port(hex) protocol"
	| "defunct_by_ip src_ip(hex)]

EOF
}
#
# attempt to mount state files for the requested module and cat it
# if the mount succeeded
#
ECM_STATE_FILE_OUTPUT_CONNECTIONS=1
ECM_STATE_FILE_OUTPUT_MAPPINGS=2
ECM_STATE_FILE_OUTPUT_HOSTS=4
ECM_STATE_FILE_OUTPUT_NODES=8
ECM_STATE_FILE_OUTPUT_INTERFACES=16
ECM_STATE_FILE_OUTPUT_CONNECTIONS_CHAIN=32
ECM_STATE_FILE_OUTPUT_MAPPINGS_CHAIN=64
ECM_STATE_FILE_OUTPUT_HOSTS_CHAIN=128
ECM_STATE_FILE_OUTPUT_NODES_CHAIN=256
ECM_STATE_FILE_OUTPUT_INTERFACES_CHAIN=512
ECM_STATE_FILE_OUTPUT_PROTOCOL_COUNTS=1024
#for now, reserve last signifficant 8bits to implenment show-level funciton
#define SHOW_LEVEL_SHIFT 24
#define ECM_STATE_FILE_OUTPUT_LEVEL_0 ( 1 << SHOW_LEVEL_SHIFT )//redundent, sdk original, output messages as many as we can
#define ECM_STATE_FILE_OUTPUT_LEVEL_1 ( 1 << (SHOW_LEVEL_SHIFT + 1))//normal 
#define ECM_STATE_FILE_OUTPUT_LEVEL_2 ( 1 << (SHOW_LEVEL_SHIFT + 2))//condense, output messages which are necessary

ecm_debug_dir=/sys/kernel/debug/ecm
ecm_nss_opt_dir=/proc/sys/net/ecm
ecm_output_mask_file=$ecm_debug_dir/ecm_state/state_file_output_mask
ecm_db_connection_count_file=$ecm_debug_dir/ecm_db/connection_count
ecm_db_connection_accelerated_count_file=$ecm_debug_dir/ecm_nss_ipv4/accelerated_count
ecm_db_connection_pending_accel_count_file=$ecm_debug_dir/ecm_nss_ipv4/pending_accel_count
ecm_db_connection_pending_decel_count_file=$ecm_debug_dir/ecm_nss_ipv4/pending_decel_count
ecm_db_connection_v6_accelerated_count_file=$ecm_debug_dir/ecm_nss_ipv6/accelerated_count
ecm_db_connection_v6_pending_accel_count_file=$ecm_debug_dir/ecm_nss_ipv6/pending_accel_count
ecm_db_connection_v6_pending_decel_count_file=$ecm_debug_dir/ecm_nss_ipv6/pending_decel_count
ecm_db_defunct_all_file=$ecm_debug_dir/ecm_db/defunct_all
ecm_db_defunct_by_tuple=$ecm_debug_dir/ecm_db/defunct_by_tuple
ecm_db_defunct_by_ip=$ecm_debug_dir/ecm_db/defunct_by_ip
ecm_nss_L3_hook_enable_file=$ecm_debug_dir/ecm_nss_ipv4/register_L3_hook

nf_conntrack_count_file=/proc/sys/net/netfilter/nf_conntrack_count 
ecm_nss_gradient_threshold_file="$ecm_nss_opt_dir/ecm_accelerate_*"
ecm_nss_gradient_step_file="$ecm_nss_opt_dir/ecm_nss_ipv4_accelerated_count_*"
ecm_nss_hs_sniffer_enable_file=$ecm_nss_opt_dir/ecm_nss_ipv4_is_sniffer_started 
ecm_nss_v6_gradient_step_file="$ecm_nss_opt_dir/ecm_nss_ipv6_accelerated_count_*"
ecm_nss_v6_hs_sniffer_enable_file=$ecm_nss_opt_dir/ecm_nss_ipv6_is_sniffer_started

sfe_stats_file=/proc/sfe_ipv4/statistics
sfe_v6_stats_file=/proc/sfe_ipv6/statistics

ecm_nss_front_end_stop_file=$ecm_debug_dir/front_end_ipv4_stop
ecm_nss_v6_front_end_stop_file=$ecm_debug_dir/front_end_ipv6_stop
option=$1
option_2=$2
option_3=$3
module_state_mount ${ECM_MODULE} ${MOUNT_ROOT} && {
#process option, show what
	#default:connnection
	mask=$ECM_STATE_FILE_OUTPUT_CONNECTIONS
	if [ -n "$option" ];then
		case $option in
			"help")
				usage
				exit 0;
				;;
			"defunct")
				echo 1 > $ecm_db_defunct_all_file
				echo defunct all ecm_accelearted_conneciont done!
				exit 0;
				;;
			"defunct_by_tuple")
				ip_src=$2
				src_port=$3
				ip_dst=$4
				dst_port=$5
				protocol=$6
				echo $ip_src $src_port $ip_dst $dst_port $protocol > $ecm_db_defunct_by_tuple
				exit 0;
				;;
			"defunct_by_ip")
				ip=$2
				echo $ip > $ecm_db_defunct_by_ip
				exit 0;
				;;
			"count")
				echo kernel_ct:$(cat $nf_conntrack_count_file)
				echo ecm_db_connection:$(cat $ecm_db_connection_count_file)
				if [ "$option_2" = "v4" ];then
					echo sfe_connection_ipv4:$(cat $sfe_stats_file|grep CONNECTION)
					echo ecm_db_connection_accelerated/pending-accel/pending-decel-ipv4: $(cat $ecm_db_connection_accelerated_count_file)/$(cat $ecm_db_connection_pending_accel_count_file)/$(cat $ecm_db_connection_pending_decel_count_file)
				elif [ "$option_2" = "v6" ];then
					echo sfe_connection_ipv6:$(cat $sfe_v6_stats_file|grep CONNECTION)
					echo ecm_db_connection_v6_accelerated/pending-accel/pending-decel-ipv6: $(cat $ecm_db_connection_v6_accelerated_count_file)/$(cat $ecm_db_connection_v6_pending_accel_count_file)/$(cat $ecm_db_connection_v6_pending_decel_count_file)
				else
					echo sfe_connection_ipv4:$(cat $sfe_stats_file|grep CONNECTION)
					echo sfe_connection_ipv6:$(cat $sfe_v6_stats_file|grep CONNECTION)
					echo ecm_db_connection_accelerated/pending-accel/pending-decel-ipv4: $(cat $ecm_db_connection_accelerated_count_file)/$(cat $ecm_db_connection_pending_accel_count_file)/$(cat $ecm_db_connection_pending_decel_count_file)
					echo ecm_db_connection_v6_accelerated/pending-accel/pending-decel-ipv6: $(cat $ecm_db_connection_v6_accelerated_count_file)/$(cat $ecm_db_connection_v6_pending_accel_count_file)/$(cat $ecm_db_connection_v6_pending_decel_count_file)
				fi

				if [ "$option_2" = "all" ];then
					files=$(ls $ecm_debug_dir/ecm_db/*count)
					for file in $files; do
						echo $(basename $file):$(cat $file)
					done
				fi
				exit 0;
				;;
			"gradient")
				echo steps-ipv4:$(cat $ecm_nss_gradient_step_file)
				echo steps-ipv6:$(cat $ecm_nss_v6_gradient_step_file)
				echo threshold:$(cat $ecm_nss_gradient_threshold_file)
				exit 0;
				;;
			"enable")
				echo L3_enable:$(cat $ecm_nss_L3_hook_enable_file)
				echo home_shield_sniffer_enable-ipv4:$(cat $ecm_nss_hs_sniffer_enable_file)
				echo home_shield_sniffer_enable-ipv6:$(if [ -f $ecm_nss_v6_hs_sniffer_enable_file ];then $(cat $ecm_nss_v6_hs_sniffer_enable_file); fi)
				exit 0;
				;;
			"stop")
				if [ "$option_2" = "v4" ];then
					echo 1 > $ecm_nss_front_end_stop_file
					echo "stop ipv4 nss learning"
				elif [ "$option_2" = "v6" ];then
					echo 1 > $ecm_nss_v6_front_end_stop_file
					echo "stop ipv6 nss learning"
				else
					echo 1 > $ecm_nss_front_end_stop_file
					echo 1 > $ecm_nss_v6_front_end_stop_file
					echo "stop ipv4 and ipv6 nss learning"
				fi
				exit 0;
				;;
			"start")
				if [ "$option_2" = "v4" ];then
					echo 0 > $ecm_nss_front_end_stop_file
					echo "start ipv4 nss learning"
				elif [ "$option_2" = "v6" ];then
					echo 0 > $ecm_nss_v6_front_end_stop_file
					echo "start ipv6 nss learning"
				else
					echo 0 > $ecm_nss_front_end_stop_file
					echo 0 > $ecm_nss_v6_front_end_stop_file
					echo "start ipv4 and ipv6 nss learning"
				fi
				exit 0;
				;;
			"connection")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_CONNECTIONS
				;;
			"mapping")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_MAPPINGS
				;;
			"host")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_HOSTS ;;
			"node")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_NODES
				;;
			"interface")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_INTERFACES
				;;
			"conn_chain")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_CONNECTIONS_CHAIN
				;;
			"map_chain")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_MAPPINGS_CHAIN
				;;
			"host_chain")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_HOSTS_CHAIN
				;;
			"node_chain")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_NODES_CHAIN
				;;
			"inf_chain")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_INTERFACES_CHAIN
				;;
			"prot_count")
				echo "$option"s is below
				mask=$ECM_STATE_FILE_OUTPUT_PROTOCOL_COUNTS
				;;
			*)
				echo invalid mask, default mask is chosen
				if [ -e $ecm_output_mask_file ];then
#use previous mask or default
#mask=$(cat $ecm_output_mask_file)
#mask=$((0xffffff&$mask))
					#default:connnection
					mask=$ECM_STATE_FILE_OUTPUT_CONNECTIONS
				fi
				;;
			esac
	else
		if [ -e $ecm_output_mask_file ];then
#use previous mask or default
#mask=$(cat $ecm_output_mask_file)
#mask=$((0xffffff&$mask))
			#default:connnection
			mask=$ECM_STATE_FILE_OUTPUT_CONNECTIONS
		fi
	fi
#process show level, how to show
	#default show level is 2, which is necessary for tfstat funtion
	level=2
	if [ -n "$option" -a "$option" = "level" ];then
		if [ -n "$option_2" -a $option_2 -ge 0 -a $option_2 -lt 3 ];then
			level=$option_2
		fi
	elif [ -n "$option_2" -a "$option_2" = "level" ];then
		if [ -n "$option_3" -a $option_3 -ge 0 -a $option_3 -lt 3 ];then
			level=$option_3
		fi
	fi
#show
	output=$((1<<($level+24)))	
	output=$(($mask|$output))
	echo $output > $ecm_output_mask_file
	cat ${MOUNT_ROOT}/${ECM_MODULE}

	output=$((1<<(2+24)))
	output=$(($mask|$output))
	echo $output > $ecm_output_mask_file

	echo mask:$mask level:$level> /dev/console
	exit 0
}

echo module_state_mount error!
exit 2
