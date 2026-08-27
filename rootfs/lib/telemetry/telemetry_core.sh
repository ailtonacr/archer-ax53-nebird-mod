# Copyright (C) 2009-2010 OpenWrt.org
. /lib/config/uci.sh

set_device_info() {
	local mac=$(getfirm MAC)
	local dev_id=$(getfirm DEV_ID)
	local hw_id=$(getfirm HW_ID)
	local hw_version=$(getfirm HARDVERSION)
	local sw_version=$(getfirm SOFTVERSION)
	local device_model=$(getfirm MODEL)
	local oem_id=$(getfirm OEM_ID)
	
	# create /var/state/
	# uci_revert_state "telemetry"
	uci_toggle_state "telemetry" "dev_info" "" "telemetry"
	uci_toggle_state "telemetry" "dev_info" "mac" "${mac}"
	uci_toggle_state "telemetry" "dev_info" "dev_id" "${dev_id}"
	uci_toggle_state "telemetry" "dev_info" "hw_id" "${hw_id}"
	uci_toggle_state "telemetry" "dev_info" "hw_version" "${hw_version}"
	uci_toggle_state "telemetry" "dev_info" "sw_version" "${sw_version}"
	uci_toggle_state "telemetry" "dev_info" "device_model" "${device_model}"
	uci_toggle_state "telemetry" "dev_info" "oem_id" "${oem_id}"
}

telemetry_start() {
	set_device_info
}

telemetry_check() {
	local enable=$(uci get telemetry.basic.enable)
	if [ "${enable}" != "on" ]; then
		return 0
	fi
	
	local telemetry_pid=$(pgrep telemetry)
	[ -z "${telemetry_pid}" ] && {
		echo "telemetry monit start" > /dev/console
		/usr/bin/telemetry &
	}
}

add_monit_crontab() {
	local CRON_FILE="/etc/crontabs/root"
	local TMP_CRONTAB="/tmp/telemetry_cron"
	local TELEMETRY_MONIT_BIN="/usr/sbin/telemetry_monit"
	local new_cron_item="*/5 * * * * ${TELEMETRY_MONIT_BIN}"
	
	cron_item=`grep "${TELEMETRY_MONIT_BIN}" ${CRON_FILE}`
	[ "${cron_item}" != "${new_cron_item}" ] && {
		echo "${new_cron_item}" > ${TMP_CRONTAB}
		crontab -l | grep -v "${TELEMETRY_MONIT_BIN}" | cat - "${TMP_CRONTAB}" | crontab -
		rm -f ${TMP_CRONTAB}
	}
}

del_monit_crontab() {
	local TELEMETRY_MONIT_BIN="/usr/sbin/telemetry_monit"

	crontab -l | grep -v "${TELEMETRY_MONIT_BIN}" | crontab -
}
