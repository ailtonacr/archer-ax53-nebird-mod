#!/bin/sh

UCI_STR_FMT_TPAP_TLS_ENABLE="tpaptmp.tls.enable"
UCI_STR_FMT_TPAP_TLS_MODE="tpaptmp.tls.mode"
UCI_STR_FMT_TPAP_NOC_ENABLE="tpaptmp.noc.enable"
UCI_STR_FMT_TPAP_PAKE_ENABLE="tpaptmp.pake.enable"
UCI_STR_FMT_TPAP_PAKE_LIST="tpaptmp.pake.pklist"
UCI_STR_FMT_TPAP_SERV_USERNAME="tpaptmp.server.username"
UCI_STR_FMT_TPAP_SERV_PORT="tpaptmp.server.port"
UCI_STR_FMT_TPAP_CTRL_ENABLE="tpaptmp.ctrl.enable"

set_tpap_status(){
	uci set $1="$2"
	uci commit
	echo "set $3 $2 done"
}

UCI_FILE_PATH="/etc/config/tpaptmp"
create_tpap_uci() {
	if [ ! -f "${UCI_FILE_PATH}" ]; then
		touch "${UCI_FILE_PATH}"
	fi

	uci set tpaptmp.tls="global"
	uci set tpaptmp.pake="global"
	uci set tpaptmp.noc="global"
	uci set tpaptmp.server="global"
	uci set tpaptmp.ctrl="global"

	uci commit

	echo "create tdp-tpap debug uci done"
}

case "$1" in
	tdp_ctrl) set_tpap_status $UCI_STR_FMT_TPAP_CTRL_ENABLE $2 $1;;
	tls_svr) set_tpap_status $UCI_STR_FMT_TPAP_TLS_ENABLE $2 $1;;
	tls) set_tpap_status $UCI_STR_FMT_TPAP_TLS_MODE $2 $1;;
	pake) set_tpap_status $UCI_STR_FMT_TPAP_TLS_ENABLE $2 $1;;
	pake_list) set_tpap_status $UCI_STR_FMT_TPAP_PAKE_LIST $2 $1;;
	noc) set_tpap_status $UCI_STR_FMT_TPAP_NOC_ENABLE $2 $1;;
	username) set_tpap_status $UCI_STR_FMT_TPAP_SERV_USERNAME $2 $1;;
	port) set_tpap_status $UCI_STR_FMT_TPAP_SERV_PORT $2 $1;;
	create) create_tpap_uci;;
	*) echo "[error] Undefined function.";;
esac