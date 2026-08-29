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
test-netbird:
	node src/web/VpnServerNetbirdForm-NB.test.mjs
	python3 scripts/test-netbird-contracts.py .
	python3 -m py_compile src/web/patchnetbird_native_crud.py

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
		python3 -c "from pathlib import Path; p=Path(\"rootfs/usr/lib/lua/luci/controller/admin/vpn.lua\"); h=p.read_bytes()[:4]; assert h == b\"\\x1bLua\", f\"VPN controller is not TP-Link bytecode: {h!r}\""; \
		test ! -e rootfs/usr/lib/lua/luci/netbird/vpn_stock.lua || { echo "Error: obsolete preserved vpn_stock.lua remains in rootfs" >&2; exit 1; }; \
		test ! -e rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua || { echo "Error: legacy vpn_stock.lua remains in LuCI controller tree" >&2; exit 1; }; \
		grep -q "TYPE = \"netbirdvpn\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type registration missing" >&2; exit 1; }; \
		grep -q "TYPE_ID = \"5\"" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN type id is not 5" >&2; exit 1; }; \
		grep -q "vpn.VPN_CFG_TBL\[TYPE\] = netbird_config" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: native NetBird VPN config handler missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TYPE_NAME_TBL NetBird registration missing" >&2; exit 1; }; \
		grep -q "vpn.VPN_TBL\[TYPE\] = schema" rootfs/usr/lib/lua/luci/model/netbird_vpn_native.lua || { echo "Error: VPN_TBL NetBird schema registration missing" >&2; exit 1; }; \
		grep -q "native.install()" rootfs/usr/lib/lua/luci/controller/admin/netbird_native.lua || { echo "Error: native NetBird registry loader missing" >&2; exit 1; }; \
		grep -q "settings_set" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: auxiliary NetBird settings operation missing" >&2; exit 1; }; \
		grep -q "connected_status" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: auxiliary NetBird diagnostics endpoint missing" >&2; exit 1; }; \
		cmp -s src/init/netbird.sh rootfs/lib/netbird/netbird.sh || { echo "Error: packaged netbird.sh drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-ctl rootfs/sbin/netbird-ctl || { echo "Error: packaged netbird-ctl drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird.init rootfs/etc/init.d/netbird || { echo "Error: packaged netbird init drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-proto.sh rootfs/lib/netifd/proto/netbird.sh || { echo "Error: packaged netbird netifd handler drifted from canonical source" >&2; exit 1; }; \
		grep -q "add_protocol netbird" rootfs/lib/netifd/proto/netbird.sh || { echo "Error: netifd NetBird protocol registration missing" >&2; exit 1; }; \
		grep -q "nb_fw_prioritize_lan" rootfs/sbin/netbird-ctl || { echo "Error: prioritized LAN forwarding fix missing" >&2; exit 1; }; \
		grep -q -- "--wireguard-port" rootfs/sbin/netbird-ctl || { echo "Error: WireGuard port is not applied to NetBird runtime" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/update-store-DQkZxaRI.js.gz | grep -Fq "e.Netbird=\"netbirdvpn\"" || { echo "Error: frontend NetBird enum is not netbirdvpn" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "function f(e){return a.request(y,{operation:\"connected_status\",key:e},{preventSuccess:!0})}" || { echo "Error: NetBird connected-status is not using stock VPN endpoint" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz | grep -Fq "i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}" || { echo "Error: VPN list is not sourced exclusively from stock endpoint" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -Fq "type: \"netbirdvpn\", proto: \"netbird\"" || { echo "Error: NetBird form does not serialize native type/proto" >&2; exit 1; }; \
		if zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz | grep -Fq "a.value=_nb.concat(e)"; then echo "Error: synthetic NetBird list bridge remains" >&2; exit 1; fi; \
		if zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -Fq "e===\"netbird\"?a.request(\"/admin/netbird\",{operation:\"connected_status\"}"; then echo "Error: dedicated NetBird connected-status bridge remains" >&2; exit 1; fi; \
		if grep -q "NetBird adapter for TP-Link\|patch_dispatch_upvalues\|request_context" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua 2>/dev/null; then echo "Error: retired adapter leaked into stock VPN controller" >&2; exit 1; fi; \
		grep -Fxq "build=$$BUILD_NO" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong build number" >&2; exit 1; }; \
		grep -Fxq "display_version=$$STAMPED_VERSION" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong display version" >&2; exit 1; }; \
		echo "    ok untouched TP-Link VPN controller bytecode + native registry extension"; \
		echo "    ok NetBird native type netbirdvpn=5 / proto=netbird"; \
		echo "    ok stock list/add/modify/toggle/delete/connected-status path"; \
		echo "    ok netifd NetBird protocol handler"; \
		echo "    ok canonical runtime sources + prioritized LAN forwarding"; \
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
