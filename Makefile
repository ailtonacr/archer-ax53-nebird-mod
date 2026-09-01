CC = gcc
CFLAGS = -Wall -Wextra -pedantic
LDFLAGS = -lcrypto

TARGET = bin/md5-fix
SRCS = src/md5-fix.c

# Firmware build defaults. BUILD is a persistent monotonic counter. A build
# stamps the rootfs with that number and only advances BUILD after the final
# firmware image has been produced successfully.
STOCK ?= stock_decrypted.bin
BUILD_NO := $(shell test -f BUILD && tr -d '[:space:]' < BUILD || echo 1)
FIRMWARE_OUTPUT ?= work/Archer-AX53-NetBird-build-$(BUILD_NO).bin

.PHONY: all tools clean firmware test-netbird

all: $(TARGET)

$(TARGET): $(SRCS)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

# Offline tests only. Deliberately no GitHub Actions: this target is run by the
# local firmware build and can also be invoked explicitly during development.
# It is hermetic with respect to rootfs/: generated bundles are checked after
# unpack/apply-mods against the selected STOCK image in the firmware target.
test-netbird:
	sh -n src/init/netbird.sh src/init/netbird-runtime.sh src/init/netbird-ctl src/init/netbird-proto.sh src/init/netbird.init src/init/netbird_firewall.inc scripts/test-netbird-runtime.sh
	bash -n mods/010-netbird.sh mods/012-netbird-native-vpn.sh
	sh scripts/test-netbird-runtime.sh
	node src/web/VpnServerNetbirdForm-NB.test.mjs
	python3 scripts/test-netbird-contracts.py .
	python3 scripts/test-netbird-native-frontend.py
	python3 -m py_compile src/web/patchnetbird_native_crud.py src/web/patchnetbird_factory_semantics.py src/web/patchnetbird_form_state.py scripts/verify-tplink-vpn-bytecode.py scripts/test-netbird-contracts.py scripts/test-netbird-native-frontend.py

firmware: $(TARGET) test-netbird
	@bash -o pipefail -c 'set -e; \
		BUILD_NO="$$(tr -d "[:space:]" < BUILD)"; \
		case "$$BUILD_NO" in ""|*[!0-9]*) echo "Error: BUILD must contain a positive integer" >&2; exit 1;; esac; \
		test "$$BUILD_NO" -ge 1 || { echo "Error: BUILD must be >= 1" >&2; exit 1; }; \
		test "$$BUILD_NO" = "$(BUILD_NO)" || { echo "Error: BUILD changed after make parsed it (make=$(BUILD_NO), runtime=$$BUILD_NO)" >&2; exit 1; }; \
		test -f "$(STOCK)" || { echo "Error: stock image not found: $(STOCK)" >&2; exit 1; }; \
		mkdir -p "$(dir $(FIRMWARE_OUTPUT))"; \
		echo "=== Firmware identity: NetBird Build $$BUILD_NO ==="; \
		echo "=== [1/6] Unpacking stock firmware ==="; \
		rm -rf rootfs tmp-ubi; \
		bash 01-unpack-ubi.sh "$(STOCK)" 2>&1 | tail -5; \
		echo "=== [2/6] Applying NetBird modifications to rootfs ==="; \
		ROOTFS_DIR=rootfs bash apply-mods.sh 2>&1 | tail -60; \
		echo "=== [3/6] Stamping build identity ==="; \
		bash scripts/stamp-build-version.sh stamp rootfs "$$BUILD_NO"; \
		STAMPED_VERSION="$$(sed -n "s/^soft_ver://p" rootfs/etc/partition_config/soft-version | head -n1)"; \
		case "$$STAMPED_VERSION" in *"-netbird mod Build $$BUILD_NO") : ;; *) echo "Error: unexpected stamped soft version: $$STAMPED_VERSION" >&2; exit 1;; esac; \
		echo "=== [4/6] Verifying modified rootfs before repack ==="; \
		python3 scripts/verify-tplink-vpn-bytecode.py rootfs/usr/lib/lua/luci/controller/admin/vpn.lua; \
		test ! -e rootfs/usr/lib/lua/luci/netbird/vpn_stock.lua || { echo "Error: obsolete preserved vpn_stock.lua remains in rootfs" >&2; exit 1; }; \
		test ! -e rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua || { echo "Error: legacy vpn_stock.lua remains in LuCI controller tree" >&2; exit 1; }; \
		grep -q "TYPE = \"netbirdvpn\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type registration missing" >&2; exit 1; }; \
		grep -q "TYPE_ID = \"5\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type id is not 5" >&2; exit 1; }; \
		grep -q "local schema = { proto = PROTO }" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN_TBL schema does not match stock shape" >&2; exit 1; }; \
		grep -q "table.insert(schema, { key = key })" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN_TBL field entries are not stock-shaped" >&2; exit 1; }; \
		grep -q "vpn.VPN_CFG_TBL\[TYPE\] = netbird_config" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN config handler missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_NAME_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TBL\[TYPE\] = schema" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TBL NetBird schema registration missing" >&2; exit 1; }; \
		grep -q "native.install()" rootfs/usr/lib/lua/luci/controller/admin/netbird_native.lua || { echo "Error: native NetBird registry loader missing" >&2; exit 1; }; \
		grep -q "settings_get" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: auxiliary read-only NetBird settings operation missing" >&2; exit 1; }; \
		if grep -Fq "elseif op == \"settings_set\"" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua; then echo "Error: auxiliary NetBird endpoint still exposes writable settings_set" >&2; exit 1; fi; \
		grep -q "result = \"noop\"" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: NetBird delete cleanup is not idempotent" >&2; exit 1; }; \
		grep -q "connected_status" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: auxiliary NetBird diagnostics endpoint missing" >&2; exit 1; }; \
		grep -Fq "/etc/init.d/vpnc restart" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: UI restart bypasses native vpnc lifecycle" >&2; exit 1; }; \
		grep -q "server routes must be enabled when LAN routing is enabled" rootfs/usr/lib/lua/luci/model/netbird.lua || { echo "Error: backend does not reject routing with server routes disabled" >&2; exit 1; }; \
		grep -q "NetBird firewall must be enabled when LAN routing is enabled" rootfs/usr/lib/lua/luci/model/netbird.lua || { echo "Error: backend does not require NetBird firewall policy enforcement for LAN routing" >&2; exit 1; }; \
		cmp -s src/init/netbird.sh rootfs/lib/netbird/netbird.sh || { echo "Error: packaged netbird.sh drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-runtime.sh rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: packaged native runtime drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-ctl rootfs/sbin/netbird-ctl || { echo "Error: packaged netbird-ctl drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird.init rootfs/etc/init.d/netbird || { echo "Error: packaged netbird init drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-proto.sh rootfs/lib/netifd/proto/netbird.sh || { echo "Error: packaged netbird netifd handler drifted from canonical source" >&2; exit 1; }; \
		grep -q "add_protocol netbird" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: netifd NetBird protocol registration missing" >&2; exit 1; }; \
		grep -q "nb_runtime_connect" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: netifd does not call shared native runtime" >&2; exit 1; }; \
		if grep -q "/sbin/netbird-ctl" rootfs/lib/netifd/proto/netbird.sh; then echo "Error: netifd still depends on netbird-ctl" >&2; exit 1; fi; \
		if grep -q "proto_set_available" rootfs/lib/netifd/proto/netbird.sh; then echo "Error: transient NetBird failure changes protocol availability" >&2; exit 1; fi; \
		PROTO_SETUP="$$(sed -n "/^proto_netbird_setup()/,/^proto_netbird_teardown()/p" rootfs/lib/netifd/proto/netbird.sh)"; \
		test "$$(printf "%s\n" "$$PROTO_SETUP" | grep -c "nb_runtime_stop")" -ge 2 || { echo "Error: netifd setup rollback is incomplete" >&2; exit 1; }; \
		test ! -e rootfs/etc/rc.d/S99netbird || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }; \
		grep -q "NB_FW_STATE=\"/tmp/netbird-firewall.state\"" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: applied firewall state snapshot missing" >&2; exit 1; }; \
		grep -q "nb_runtime_validate_settings" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: runtime routing settings validation missing" >&2; exit 1; }; \
		grep -q "LAN routing requires NetBird firewall policy enforcement" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: runtime does not preserve NetBird Route ACL enforcement" >&2; exit 1; }; \
		if grep -Eq "iptables[[:space:]].*(-I|--insert)[[:space:]]+FORWARD" rootfs/lib/netbird/netbird-runtime.sh; then echo "Error: runtime contains a priority FORWARD bypass" >&2; exit 1; fi; \
		if grep -q "nb_fw_prioritize_lan" rootfs/lib/netbird/netbird-runtime.sh; then echo "Error: retired Route ACL bypass helper remains" >&2; exit 1; fi; \
		grep -q -- "--wireguard-port" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: WireGuard port is not applied by canonical NetBird flag builder" >&2; exit 1; }; \
		grep -q "# NetBird v4 CIDR-scoped/applied-state" rootfs/lib/firewall/tpcmd.sh || { echo "Error: ACL-safe canonical NetBird firewall source missing" >&2; exit 1; }; \
		if grep -Fq "fw_s_add 4 f FORWARD ACCEPT 1 {" rootfs/lib/firewall/tpcmd.sh; then echo "Error: TP-Link NetBird FORWARD rules bypass Route ACL ordering" >&2; exit 1; fi; \
		zcat rootfs/www/webpages/js/update-store-DQkZxaRI.js.gz | grep -Fq "e.Netbird=\"netbirdvpn\"" || { echo "Error: frontend NetBird enum is not netbirdvpn" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "function f(e){return a.request(y,{operation:\"connected_status\",key:e},{preventSuccess:!0})}" || { echo "Error: NetBird connected-status is not using stock VPN endpoint" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "new URL(n).hostname" || { echo "Error: NetBird stock server field is not normalized to a pingable hostname" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "function nbDelete(){return a.request(nb,{operation:\"profile_delete\"}" || { echo "Error: final delete-only auxiliary bridge missing" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz | grep -Fq "i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}" || { echo "Error: VPN list is not sourced exclusively from stock endpoint" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "const existing = !!(value && (value.key || value.id))" || { echo "Error: NetBird Add/Edit is not keyed by persisted stock identity" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "const creating = ref(true)" || { echo "Error: NetBird Add form does not default to CREATE" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "stockComponent(this, \"su-form\")" || { echo "Error: NetBird form is not using stock TP-Link controls" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "s.advertise_lan === \"1\" && s.disable_server_routes !== \"0\"" || { echo "Error: frontend server-route invariant missing" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "s.advertise_lan === \"1\" && s.disable_firewall !== \"0\"" || { echo "Error: frontend NetBird firewall invariant missing" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "Permitir roteamento da LAN" || { echo "Error: LAN routing label still overpromises management-side announcement" >&2; exit 1; }; \
		if zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "value.type === \"netbirdvpn\""; then echo "Error: NetBird Add/Edit still inferred from VPN type" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "Anunciar rede local"; then echo "Error: misleading LAN announcement label remains" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz | grep -Fq "a.value=_nb.concat(e)"; then echo "Error: synthetic NetBird list bridge remains" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "e===\"netbird\"?a.request(\"/admin/netbird\",{operation:\"connected_status\"}"; then echo "Error: dedicated NetBird connected-status bridge remains" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "operation:\"settings_set\""; then echo "Error: writable hybrid NetBird helper remains in final bundle" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "function nbSettingsSet("; then echo "Error: nbSettingsSet remains in final bundle" >&2; exit 1; fi; \
		if grep -q "NetBird adapter for TP-Link\|patch_dispatch_upvalues\|request_context" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua 2>/dev/null; then echo "Error: retired adapter leaked into stock VPN controller" >&2; exit 1; fi; \
		grep -Fxq "build=$$BUILD_NO" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong build number" >&2; exit 1; }; \
		grep -Fxq "display_version=$$STAMPED_VERSION" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong display version" >&2; exit 1; }; \
		echo "    ok TP-Link VPN bytecode registry export contract"; \
		echo "    ok untouched TP-Link VPN controller bytecode + native registry extension"; \
		echo "    ok NetBird native type netbirdvpn=5 / proto=netbird"; \
		echo "    ok stock list/add/modify/toggle/delete/connected-status path"; \
		echo "    ok auxiliary endpoint read-only for profile settings"; \
		echo "    ok vpnc/netifd sole normal lifecycle owner + rollback"; \
		echo "    ok key-based Add/Edit + stock TP-Link protocol subform"; \
		echo "    ok routing-peer invariants + NetBird Route ACL ordering + applied firewall state"; \
		echo "    ok build identity: $$STAMPED_VERSION"; \
		echo "=== [5/6] Repacking firmware ==="; \
		rm -f "$(FIRMWARE_OUTPUT)"; \
		bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)" 2>&1 | tail -5; \
		test -s "$(FIRMWARE_OUTPUT)" || { echo "Error: firmware output missing/empty after repack" >&2; exit 1; }; \
		echo "=== [6/6] Firmware ready ==="; \
		ls -lh "$(FIRMWARE_OUTPUT)"; \
		echo "Build: $$BUILD_NO"; \
		echo "Version: $$STAMPED_VERSION"; \
		echo "Output: $(FIRMWARE_OUTPUT)"; \
		bash scripts/stamp-build-version.sh advance "$$BUILD_NO"'

tools:
	$(MAKE) -C vendor/mtd-utils
	$(MAKE) -C vendor/squashfs
	$(MAKE) -C vendor/squashfs4

clean:
	rm -f $(TARGET)
	$(MAKE) -C vendor/mtd-utils clean
	$(MAKE) -C vendor/squashfs clean
	$(MAKE) -C vendor/squashfs4 clean
