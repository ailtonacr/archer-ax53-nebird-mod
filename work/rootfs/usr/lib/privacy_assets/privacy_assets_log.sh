#!/bin/sh
# Copyright(c) 2011-2025 Shenzhen TP-Link Technologies Co.Ltd.
#
# /usr/lib/privacy_assets/privacy_assets_log.sh
# Written by yuzebin<yuzebin1@tp-link.com.cn>, June 2025
#
# This script is used to make privacy-assets log

PROJ_LOG_ID_PRIVACY_ASSETS=400
#MSG(PRIVACY_ASSETS_PUBLIC_IP_CHANGE, 1, INF, "Public ip changed")
PRIVACY_ASSETS_PUBLIC_IP_CHANGE=1
#MSG(PRIVACY_ASSETS_TP_LINK_ID_LOGIN, 10, INF, "TP-Link ID login")
PRIVACY_ASSETS_TP_LINK_ID_LOGIN=10
#MSG(PRIVACY_ASSETS_TP_LINK_ID_LOGOUT, 11, INF, "TP-Link ID logout")
PRIVACY_ASSETS_TP_LINK_ID_LOGOUT=11
#MSG(PRIVACY_ASSETS_TP_LINK_ID_CHANGE_PWD, 12, INF, "TP-Link ID change password")
PRIVACY_ASSETS_TP_LINK_ID_CHANGE_PWD=12
#MSG(PRIVACY_ASSETS_UP_TRAFFIC_STAT_INFO, 20, INF, "Upload traffic statistics information")
PRIVACY_ASSETS_UP_TRAFFIC_STAT_INFO=20
#MSG(PRIVACY_ASSETS_UP_CLIENT_IDENT_INFO, 21, INF, "Upload client identification information")
PRIVACY_ASSETS_UP_CLIENT_IDENT_INFO=21

# privacy_assets_syslog log_id log_param
privacy_assets_syslog()
{
    local log_id=$1
    shift
    logx -p $$ $PROJ_LOG_ID_PRIVACY_ASSETS $log_id "$@"
}

