#!/bin/sh

NEW_ISOLATE_LIST_FILE="/tmp/new_isolate_list"
OLD_ISOLATE_LIST_FILE="/tmp/old_isolate_list"
TMP_ISOLATE_LIST_FILE="/tmp/tmp_isolate_list"

local macs_add=""
local macs_del=""

DEBUG=1

iot_echo() {
    if [ "$DEBUG" -gt 1 ]; then
        echo "${1}: ""$2" > /dev/console
    fi
}

get_new_isolate_list() {
    local section="$1"

    local mac
    config_get mac "$section" mac
	mac=${mac//-/:}

    if [ -n "$mac" ]; then
		echo $mac >> $NEW_ISOLATE_LIST_FILE
    fi
}

get_old_isolate_list() {
    iotctl get br-lan | sed 1,2d > $OLD_ISOLATE_LIST_FILE
}

client_isolate_update() {
    local mac
    for mac in $macs_add; do
        iotctl add br-lan $mac
		#For QCA models, clear the specified acceleration entry
		local model=$(uci get profile.@global[0].model -c "/etc/profile.d" -q)
		if [ $model == "QCA_IPQ50XX" -a -e '/lib/iot_security/qca_isolate.sh' ];then
			/lib/iot_security/qca_isolate.sh $mac &
		fi

		if [ $model == "RTL_8198" ];then
			echo 0 MAC $mac > /proc/fc/ctrl/flow_operation
		fi
    done

    for mac in $macs_del; do
        iotctl del br-lan $mac
    done
}

client_isolate_flush() {
    iotctl del br-lan all
}

creat_tmp_file() {
    touch $OLD_ISOLATE_LIST_FILE
    touch $NEW_ISOLATE_LIST_FILE
    touch $TMP_ISOLATE_LIST_FILE
}

clear_tmp_file() {
    [ -f "$OLD_ISOLATE_LIST_FILE" ] && rm $OLD_ISOLATE_LIST_FILE
    [ -f "$NEW_ISOLATE_LIST_FILE" ] && rm $NEW_ISOLATE_LIST_FILE
    [ -f "$TMP_ISOLATE_LIST_FILE" ] && rm $TMP_ISOLATE_LIST_FILE
}

client_isolate_config_all() {
    local system_mode=$1
    local isolate_enable=$2

    if [ "${isolate_enable}" = "0" ] || [ "${system_mode}" != "router" ]; then
        client_isolate_flush
        echo 0 > /proc/iot_filter/iot_isolate
        return 0
    fi
	
    clear_tmp_file
    creat_tmp_file
    get_old_isolate_list
    config_load iot_security
    config_foreach get_new_isolate_list isolated_client
    sort $NEW_ISOLATE_LIST_FILE $OLD_ISOLATE_LIST_FILE | uniq > $TMP_ISOLATE_LIST_FILE
	#This is used to determine which items have been added or deleted
    macs_add=$(sort $OLD_ISOLATE_LIST_FILE $TMP_ISOLATE_LIST_FILE | uniq -u)
    macs_del=$(sort $NEW_ISOLATE_LIST_FILE $TMP_ISOLATE_LIST_FILE | uniq -u)

    if [ "$macs_add" = "" -a "$macs_del" = "" ]; then 
        clear_tmp_file
        return 0
    fi

    client_isolate_update
    clear_tmp_file
}

