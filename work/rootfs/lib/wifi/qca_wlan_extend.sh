#!/bin/sh

# Copyright (c) 2021 Shenzhen TP-LINK Technologies Co.Ltd.
#
# yanghuiting@tp-link.com.cn
# 2021-04-06
# Content:
#	Create for qca wireless-script
# 	This is a default extend-script, should be put in /lib/wifi


config_ani_and_dyn_edcca() {
	local vif="$1"

	if [ "$vif" = "${VIF_HOME_2G}" -o "$vif" = "${VIF_BACKHAUL_2G}" ]; then
		# config ANI Desense Level -5~25
		#wifitool "$vif" setUnitTestCmd 67 4 16 0 -5 25
		iwpriv "$vif" ani_def_range -5 25

		# config ANI apply cck ota failed to scale error
		wifitool "$vif" setUnitTestCmd 67 5 16 0 0 0x00880004 0

		# config ANI do not apply dynamic Noise Floor to update EDCCA
		wifitool "$vif" setUnitTestCmd 67 5 16 0 1 1 0

		# config max EDCCA Level 0x26
		#wifitool "$vif" setUnitTestCmd 67 2 16 0x26

		# config ANI enable dynamic EDCCA
		# Dynamic EDCCA does not take effect in ETSI domain
		wifitool "$vif" setUnitTestCmd 67 3 16 0 1
	fi
}

config_thermal_mitigation() {
	local dev="$1"

	if [ "$(getfirm MODEL)" == "Archer AX56" ]; then
		thermaltool -i "$dev" -set -dc 100 -lo0 -100 -hi0 100 -off0 0
		thermaltool -i "$dev" -set -dc 100 -lo1 95 -hi1 105 -off1 30
		thermaltool -i "$dev" -set -dc 100 -lo2 103 -hi2 113 -off2 50
		thermaltool -i "$dev" -set -dc 100 -lo3 110 -hi3 150 -off3 80
	elif [ "$dev" = "${DEVICE_5G}" ]; then
		thermaltool -i "$dev" -set -dc 100 -lo0 -100 -hi0 115 -off0 0
		thermaltool -i "$dev" -set -dc 100 -lo1 112 -hi1 118 -off1 30
		thermaltool -i "$dev" -set -dc 100 -lo2 115 -hi2 125 -off2 50
		thermaltool -i "$dev" -set -dc 100 -lo3 122 -hi3 150 -off3 80
	fi

	if [ "$(uci get -q eco_mode.eco_mode.enable)" = "on" ];then
		/etc/init.d/eco-mode restart
	fi
}

config_enable_rtscts() {
    local vif="$1"
    iwpriv "$vif" enablertscts 0x41
}

