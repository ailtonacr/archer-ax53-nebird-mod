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

# Build a complete AX53 firmware from a decrypted stock image.
# apply-mods.sh already runs the NetBird frontend patcher, so it must not be
# invoked separately here. pipefail guarantees that a failing build stage is
# not hidden by tail. ROOTFS_DIR=rootfs pins the exact tree produced by
# 01-unpack-ubi.sh, so a stale squashfs-root/ can never receive the mods by
# accident while rootfs/ gets repacked unchanged.
#
# Build identity is stamped after all mods and before validation/repack:
#   soft_ver:<stock-base>-netbird mod Build N
#   /etc/netbird-build -> build number + git commit/branch + UTC timestamp
# The BUILD counter advances only after the output image exists successfully.
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
		ROOTFS_DIR=rootfs bash apply-mods.sh 2>&1 | tail -40; \
		echo "=== [3/6] Stamping build identity ==="; \
		bash scripts/stamp-build-version.sh stamp rootfs "$$BUILD_NO"; \
		STAMPED_VERSION="$$(sed -n "s/^soft_ver://p" rootfs/etc/partition_config/soft-version | head -n1)"; \
		case "$$STAMPED_VERSION" in *"-netbird mod Build $$BUILD_NO") : ;; *) echo "Error: unexpected stamped soft version: $$STAMPED_VERSION" >&2; exit 1;; esac; \
		echo "=== [4/6] Verifying modified rootfs before repack ==="; \
		python3 -c "from pathlib import Path; p=Path(\"rootfs/usr/lib/lua/luci/controller/admin/vpn.lua\"); h=p.read_bytes()[:4]; assert h == b\"\\x1bLua\", f\"VPN controller is not untouched TP-Link bytecode: {h!r}\""; \
		test ! -e rootfs/usr/lib/lua/luci/netbird/vpn_stock.lua || { echo "Error: obsolete preserved vpn_stock.lua remains in rootfs" >&2; exit 1; }; \
		test ! -e rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua || { echo "Error: legacy vpn_stock.lua remains in LuCI controller tree and would break dispatch" >&2; exit 1; }; \
		grep -q "profile_delete" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: dedicated NetBird profile delete operation missing" >&2; exit 1; }; \
		grep -q "settings_set" rootfs/usr/lib/lua/luci/controller/admin/netbird.lua || { echo "Error: dedicated NetBird settings operation missing" >&2; exit 1; }; \
		cmp -s src/init/netbird.sh rootfs/lib/netbird/netbird.sh || { echo "Error: packaged netbird.sh drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird-ctl rootfs/sbin/netbird-ctl || { echo "Error: packaged netbird-ctl drifted from canonical source" >&2; exit 1; }; \
		cmp -s src/init/netbird.init rootfs/etc/init.d/netbird || { echo "Error: packaged netbird init drifted from canonical source" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "Ações NetBird" || { echo "Error: current NetBird frontend missing from rootfs" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -q "profile_delete" || { echo "Error: dedicated NetBird delete bridge missing from model bundle" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/model-CI6Gt3Hz.js.gz | grep -q "/admin/netbird" || { echo "Error: dedicated NetBird API bridge missing from model bundle" >&2; exit 1; }; \
		zcat rootfs/www/webpages/js/index-DTNtPvwx.js.gz | grep -q "profileExists" || { echo "Error: NetBird synthetic list bridge missing from VPN page bundle" >&2; exit 1; }; \
		if zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "__netbirdSaveDraft"; then echo "Error: legacy NetBird save bridge still present in rootfs" >&2; exit 1; fi; \
		if grep -q "NetBird adapter for TP-Link\|patch_dispatch_upvalues\|request_context" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua 2>/dev/null; then echo "Error: retired NetBird VPN adapter leaked into stock controller" >&2; exit 1; fi; \
		grep -Fxq "build=$$BUILD_NO" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong build number" >&2; exit 1; }; \
		grep -Fxq "display_version=$$STAMPED_VERSION" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong display version" >&2; exit 1; }; \
		echo "    ok untouched TP-Link VPN controller bytecode"; \
		echo "    ok no obsolete vpn_stock copies"; \
		echo "    ok dedicated NetBird CRUD/runtime controller"; \
		echo "    ok canonical runtime sources packaged without drift"; \
		echo "    ok dedicated NetBird frontend/list bridges"; \
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

# Explicit target to build the vendor mtd-utils suite
tools:
	$(MAKE) -C vendor/mtd-utils
	$(MAKE) -C vendor/squashfs
	$(MAKE) -C vendor/squashfs4

clean:
	rm -f $(TARGET)
	$(MAKE) -C vendor/mtd-utils clean
	$(MAKE) -C vendor/squashfs clean
	$(MAKE) -C vendor/squashfs4 clean
