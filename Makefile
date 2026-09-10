CC = gcc
CFLAGS = -Wall -Wextra -pedantic
LDFLAGS = -lcrypto
PYTHON ?= python3

TARGET = bin/md5-fix
SRCS = src/md5-fix.c

# Firmware build defaults. BUILD is a persistent monotonic counter. A build
# stamps the rootfs with that number and only advances BUILD after the final
# firmware image has been produced successfully.
STOCK ?= stock_decrypted.bin
BUILD_NO := $(shell test -f BUILD && tr -d '[:space:]' < BUILD || echo 1)
FIRMWARE_OUTPUT ?= work/Archer-AX53-NetBird-build-$(BUILD_NO).bin

.PHONY: all tools clean firmware test-netbird setup

all: $(TARGET)

setup:
	$(PYTHON) -m pip install -r requirements.txt

$(TARGET): $(SRCS)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

# Offline tests only. Deliberately no GitHub Actions: this target is run by the
# local firmware build and can also be invoked explicitly during development.
# Generated rootfs bundles are checked again after unpack/apply-mods.
test-netbird:
	sh -n src/init/netbird.sh src/init/netbird-profiles.sh src/init/netbird-runtime.sh src/init/netbird-ctl src/init/netbird-proto.sh src/init/netbird-profile-gc.init src/init/netbird-recovery src/init/netbird-recovery.init src/init/netbird_firewall.inc scripts/test-netbird-runtime.sh scripts/test-netbird-profiles.sh scripts/test-netbird-recovery.sh
	bash -n mods/010-netbird.sh mods/012-netbird-native-vpn.sh mods/013-netbird-recovery.sh
	sh scripts/test-netbird-runtime.sh
	sh scripts/test-netbird-profiles.sh
	sh scripts/test-netbird-recovery.sh
	node src/web/VpnServerNetbirdForm-NB.test.mjs
	python3 scripts/test-netbird-contracts.py .
	python3 scripts/test-netbird-native-frontend.py
	python3 -m py_compile src/web/patchnetbird_web.py src/web/patchnetbird_native_crud.py src/web/patchnetbird_factory_semantics.py src/web/patchnetbird_form_state.py src/web/patchnetbird_native_contract.py scripts/verify-tplink-vpn-bytecode.py scripts/test-netbird-contracts.py scripts/test-netbird-native-frontend.py

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
		grep -q "TYPE = \"netbirdvpn\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type registration missing" >&2; exit 1; }; \
		grep -q "TYPE_ID = \"5\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type id is not 5" >&2; exit 1; }; \
		grep -q "local schema = { proto = PROTO }" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN_TBL schema does not match stock shape" >&2; exit 1; }; \
		grep -Fq "table.insert(schema, { key = key })" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN_TBL entries do not match stock { key = field } shape" >&2; exit 1; }; \
		if grep -Fq "field = { key }" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || grep -Fq "canbe_empty = true" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua; then echo "Error: retired inferred VPN_TBL rule shape remains" >&2; exit 1; fi; \
		grep -q "vpn.VPN_CFG_TBL\[TYPE\] = netbird_config" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN config handler missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_NAME_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TBL\[TYPE\] = schema" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TBL NetBird schema registration missing" >&2; exit 1; }; \
		grep -q "local enrollment_token = cfg.enrollment_token" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: stock callback does not consume enrollment token" >&2; exit 1; }; \
		grep -q "local function enroll_transient(profile_key, enrollment_token)" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: token-based enrollment handler missing" >&2; exit 1; }; \
		grep -Fq "nb_model.staged_setup_key_path(enrollment_token)" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: staged Setup Key is not resolved by opaque token" >&2; exit 1; }; \
		if sed -n "/local FIELDS = {/,/^}/p" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua | grep -Fq "\"setup_key\""; then echo "Error: setup key leaked into persistent VPN_TBL fields" >&2; exit 1; fi; \
		grep -q "native.install()" rootfs/usr/lib/lua/luci/controller/admin/netbird_native.lua || { echo "Error: native NetBird registry loader missing" >&2; exit 1; }; \
		if grep -Eq "op == \"(enroll|settings_set|settings_get|profile_delete|connected_status)\"" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua; then echo "Error: auxiliary NetBird endpoint shadows stock/provider-save operations" >&2; exit 1; fi; \
		grep -q "local function op_stage_setup_key(body)" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: transient Setup Key staging endpoint missing" >&2; exit 1; }; \
		grep -q "model.stage_setup_key(setup_key)" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: Setup Key staging is not delegated to provider model" >&2; exit 1; }; \
		grep -Fq "/etc/init.d/vpnc restart" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: NetBird restart bypasses native vpnc lifecycle" >&2; exit 1; }; \
		grep -q "server routes must be enabled when LAN routing is enabled" rootfs/usr/lib/lua/luci/model/netbird.lua || { echo "Error: backend does not reject routing with server routes disabled" >&2; exit 1; }; \
		grep -q "NetBird firewall must be enabled when LAN routing is enabled" rootfs/usr/lib/lua/luci/model/netbird.lua || { echo "Error: backend does not require NetBird firewall policy enforcement for LAN routing" >&2; exit 1; }; \
		cmp -s src/init/netbird.sh rootfs/lib/netbird/netbird.sh || { echo "Error: packaged netbird.sh drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-profiles.sh rootfs/lib/netbird/netbird-profiles.sh || { echo "Error: packaged profile helper drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-runtime.sh rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: packaged native runtime drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-ctl rootfs/sbin/netbird-ctl || { echo "Error: packaged netbird-ctl drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-proto.sh rootfs/lib/netifd/proto/netbird.sh || { echo "Error: packaged netbird netifd handler drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-profile-gc.init rootfs/etc/init.d/netbird-profile-gc || { echo "Error: packaged NetBird profile GC drifted from canonical source" >&2; exit 1; }; \
		grep -q "add_protocol netbird" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: netifd NetBird protocol registration missing" >&2; exit 1; }; \
		grep -q "proto_config_add_string \"profile_key\"" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: profile key is not carried through netifd" >&2; exit 1; }; \
		grep -q "nb_runtime_connect" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: netifd does not call shared native runtime" >&2; exit 1; }; \
		if grep -Ev "^[[:space:]]*#" rootfs/lib/netifd/proto/netbird.sh | grep -q "/sbin/netbird-ctl"; then echo "Error: netifd still depends on netbird-ctl" >&2; exit 1; fi; \
		if grep -q "proto_set_available" rootfs/lib/netifd/proto/netbird.sh; then echo "Error: transient NetBird failure changes protocol availability" >&2; exit 1; fi; \
		PROTO_SETUP="$$(sed -n "/^proto_netbird_setup()/,/^proto_netbird_teardown()/p" rootfs/lib/netifd/proto/netbird.sh)"; \
		test "$$(printf "%s\n" "$$PROTO_SETUP" | grep -c "nb_runtime_stop")" -ge 2 || { echo "Error: netifd setup rollback is incomplete" >&2; exit 1; }; \
		test ! -e rootfs/etc/rc.d/S99netbird || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }; \
		grep -q "nb_profile_gc_orphans" rootfs/etc/init.d/netbird-profile-gc || { echo "Error: stock-delete orphan identity maintenance missing" >&2; exit 1; }; \
		grep -q "NB_FW_STATE=\"/tmp/netbird-firewall.state\"" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: applied firewall state snapshot missing" >&2; exit 1; }; \
		grep -q "nb_runtime_validate_settings" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: runtime routing settings validation missing" >&2; exit 1; }; \
		grep -q "LAN routing requires NetBird firewall policy enforcement" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: runtime does not preserve NetBird Route ACL enforcement" >&2; exit 1; }; \
		if grep -Eq "iptables[[:space:]].*(-I|--insert)[[:space:]]+FORWARD" rootfs/lib/netbird/netbird-runtime.sh; then echo "Error: runtime contains a priority FORWARD bypass" >&2; exit 1; fi; \
		if grep -q "nb_fw_prioritize_lan" rootfs/lib/netbird/netbird-runtime.sh; then echo "Error: retired Route ACL bypass helper remains" >&2; exit 1; fi; \
		grep -q -- "--wireguard-port" rootfs/lib/netbird/netbird-runtime.sh || { echo "Error: WireGuard port is not applied by canonical NetBird flag builder" >&2; exit 1; }; \
		NB_FW_CANONICAL="$$(sed -n "/# NetBird v4 CIDR-scoped\\/applied-state/,\$$p" rootfs/lib/firewall/tpcmd.sh)"; \
		test -n "$$NB_FW_CANONICAL" || { echo "Error: ACL-safe canonical NetBird firewall source missing" >&2; exit 1; }; \
		if printf "%s\n" "$$NB_FW_CANONICAL" | grep -Fq "fw_s_add 4 f FORWARD ACCEPT 1 {"; then echo "Error: canonical TP-Link NetBird FORWARD rules bypass Route ACL ordering" >&2; exit 1; fi; \
		UPDATE_JS="$$(zcat rootfs/www/webpages/js/update-store-DQkZxaRI.js.gz)"; \
		MODEL_JS="$$(zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz)"; \
		PAGE_JS="$$(zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz)"; \
		FORM_JS="$$(zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz)"; \
		printf "%s" "$$UPDATE_JS" | grep -Fq "e.Netbird=\"netbirdvpn\"" || { echo "Error: frontend NetBird enum is not netbirdvpn" >&2; exit 1; }; \
		printf "%s" "$$MODEL_JS" | grep -Fq "function f(e){return a.request(y,{operation:\"connected_status\",key:e},{preventSuccess:!0})}" || { echo "Error: connected-status is not stock" >&2; exit 1; }; \
		printf "%s" "$$MODEL_JS" | grep -Fq "async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}" || { echo "Error: generic VPN toggle/update is not stock" >&2; exit 1; }; \
		printf "%s" "$$MODEL_JS" | grep -Fq "async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}" || { echo "Error: generic VPN DELETE is not stock" >&2; exit 1; }; \
		printf "%s" "$$MODEL_JS" | grep -Fq "k=e.key||t()" || { echo "Error: NetBird does not use the stock profile-key generator" >&2; exit 1; }; \
		printf "%s" "$$MODEL_JS" | grep -Fq "key:k,des:e.description,type:e.type,enable:i(e.enable),server:n,profile_key:k" || { echo "Error: NetBird generic serializer fields do not match stock provider shape" >&2; exit 1; }; \
		printf "%s" "$$PAGE_JS" | grep -Eq 'from"\\./model-CI6Gt3Hz\\.js\\?v=[0-9a-f]{12}"' || { echo "Error: modified VPN model import is not cache-busted" >&2; exit 1; }; \
		printf "%s" "$$PAGE_JS" | grep -Fq "i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}" || { echo "Error: VPN list is not stock" >&2; exit 1; }; \
		printf "%s" "$$PAGE_JS" | grep -Fq "\"add\"===n.type?await Ce(i):await ne(i,n.tableItem)" || { echo "Error: VPN ADD/EDIT Save path is not stock" >&2; exit 1; }; \
		printf "%s" "$$PAGE_JS" | grep -Fq "case it.Netbird:return VpnServerNetbirdForm" || { echo "Error: NetBird provider form mapping missing" >&2; exit 1; }; \
		printf "%s" "$$PAGE_JS" | grep -Fq "VpnServerNetbirdForm-NB.js?v=" || { echo "Error: NetBird custom module cache-busting missing" >&2; exit 1; }; \
		printf "%s" "$$FORM_JS" | grep -Fq "const existing = !!(value && (value.key || value.id))" || { echo "Error: NetBird Add/Edit is not keyed by persisted stock identity" >&2; exit 1; }; \
		printf "%s" "$$FORM_JS" | grep -Fq "enrollment_token: enrollmentToken.value || \"\"" || { echo "Error: opaque enrollment token missing from stock Save payload" >&2; exit 1; }; \
		if printf "%s" "$$MODEL_JS" | grep -Fq "setup_key:e.setup_key"; then echo "Error: Setup Key leaked into stock VPN serializer" >&2; exit 1; fi; \
		printf "%s" "$$FORM_JS" | grep -Fq "stockComponent(this, \"su-password\")" || { echo "Error: stock Setup Key control missing" >&2; exit 1; }; \
		printf "%s" "$$FORM_JS" | grep -Fq "_h(SuForm, { model: s }, { default: () => items })" || { echo "Error: provider form context missing" >&2; exit 1; }; \
		printf "%s" "$$FORM_JS" | grep -Fq "Permitir roteamento da LAN" || { echo "Error: LAN routing label still overpromises management-side announcement" >&2; exit 1; }; \
		for FORBIDDEN in "key:e.key||\"netbird\"" "a.value=_nb.concat(e)" "operation:\"settings_set\"" "function nbSettingsSet(" "function nbControl(" "function nbDelete(" "\"label-width\": { span: 10 }" "\"content-width\": { span: 14 }" "async function enroll()" "async function afterStockSave()" "__nbActiveStockVpn" "window.__netbirdSaveDraft" "__netbirdSaveListener"; do \
			if printf "%s\n%s\n%s\n" "$$MODEL_JS" "$$PAGE_JS" "$$FORM_JS" | grep -Fq "$$FORBIDDEN"; then echo "Error: custom generic VPN interception remains: $$FORBIDDEN" >&2; exit 1; fi; \
		done; \
		if grep -q "NetBird adapter for TP-Link\|patch_dispatch_upvalues\|request_context" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua 2>/dev/null; then echo "Error: non-stock adapter leaked into TP-Link VPN controller" >&2; exit 1; fi; \
		grep -Fxq "build=$$BUILD_NO" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong build number" >&2; exit 1; }; \
		grep -Fxq "display_version=$$STAMPED_VERSION" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong display version" >&2; exit 1; }; \
		echo "    ok untouched TP-Link vpn.lua + native NetBird registry extension"; \
		echo "    ok stock list/add/edit/save/toggle/delete/connected-status"; \
		echo "    ok one-step stock Save + transient Setup Key enrollment"; \
		echo "    ok provider-only NetBird form + content cache-busting"; \
		echo "    ok independent profile identities + orphan GC"; \
		echo "    ok vpnc/netifd sole normal lifecycle owner + rollback"; \
		echo "    ok routing-peer invariants + NetBird Route ACL ordering"; \
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
