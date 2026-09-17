CC = gcc
CFLAGS = -Wall -Wextra -pedantic
LDFLAGS = -lcrypto
PYTHON ?= python3

TARGET = bin/md5-fix
SRCS = src/md5-fix.c

STOCK ?= stock_decrypted.bin
BUILD_NO := $(shell test -f BUILD && tr -d '[:space:]' < BUILD || echo 1)
FIRMWARE_OUTPUT ?= work/Archer-AX53-ManagedSwitch-build-$(BUILD_NO).bin

.PHONY: all setup tools clean test test-firmware firmware

all: $(TARGET)

setup:
	$(PYTHON) -m pip install -r requirements.txt

$(TARGET): $(SRCS)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

# Local/offline validation only. No CI workflow is created by this branch.
test: test-firmware

test-firmware:
	bash -n apply-mods.sh mods/011-devssh.sh mods/020-managed-switch.sh scripts/stamp-switch-build.sh
	python3 -m py_compile scripts/patch-managed-switch-menu.py
	sh -n mods/011-devssh-files/etc/init.d/devssh
	sh -n mods/020-managed-switch-files/usr/sbin/ax53-switch
	sh -n mods/020-managed-switch-files/etc/init.d/managed-switch
	sh -n mods/020-managed-switch-files/etc/hotplug.d/switch/99-managed-switch
	sh -n scripts/test-managed-switch.sh
	@if command -v luac >/dev/null 2>&1; then luac -p mods/020-managed-switch-files/usr/lib/lua/luci/controller/admin/managed_switch.lua; else echo "luac not found; controller syntax will be checked when available"; fi
	sh scripts/test-managed-switch.sh

firmware: $(TARGET) test-firmware
	@bash -o pipefail -c 'set -e; \
		BUILD_NO="$$(tr -d "[:space:]" < BUILD)"; \
		case "$$BUILD_NO" in ""|*[!0-9]*) echo "Error: BUILD must contain a positive integer" >&2; exit 1;; esac; \
		test "$$BUILD_NO" -ge 1 || { echo "Error: BUILD must be >= 1" >&2; exit 1; }; \
		test "$$BUILD_NO" = "$(BUILD_NO)" || { echo "Error: BUILD changed after make parsed it" >&2; exit 1; }; \
		test -f "$(STOCK)" || { echo "Error: stock image not found: $(STOCK)" >&2; exit 1; }; \
		mkdir -p "$(dir $(FIRMWARE_OUTPUT))"; \
		echo "=== Managed Switch Build $$BUILD_NO ==="; \
		echo "=== [1/6] Unpacking stock firmware ==="; \
		rm -rf rootfs tmp-ubi; \
		bash 01-unpack-ubi.sh "$(STOCK)" 2>&1 | tail -8; \
		echo "=== [2/6] Applying SSH + managed-switch modifications ==="; \
		ROOTFS_DIR=rootfs bash apply-mods.sh 2>&1 | tail -80; \
		echo "=== [3/6] Stamping build identity ==="; \
		bash scripts/stamp-switch-build.sh stamp rootfs "$$BUILD_NO"; \
		STAMPED_VERSION="$$(sed -n "s/^soft_ver://p" rootfs/etc/partition_config/soft-version | head -n1)"; \
		case "$$STAMPED_VERSION" in *"-switch mod Build $$BUILD_NO") : ;; *) echo "Error: unexpected stamped version: $$STAMPED_VERSION" >&2; exit 1;; esac; \
		echo "=== [4/6] Verifying modified rootfs ==="; \
		test -x rootfs/etc/init.d/devssh || { echo "Error: devssh missing" >&2; exit 1; }; \
		test -x rootfs/usr/sbin/ax53-switch || { echo "Error: ax53-switch missing" >&2; exit 1; }; \
		test -x rootfs/etc/init.d/managed-switch || { echo "Error: managed-switch init missing" >&2; exit 1; }; \
		test -x rootfs/etc/hotplug.d/switch/99-managed-switch || { echo "Error: managed-switch hotplug missing" >&2; exit 1; }; \
		test -f rootfs/usr/lib/lua/luci/controller/admin/managed_switch.lua || { echo "Error: managed-switch LuCI controller missing" >&2; exit 1; }; \
		test -f rootfs/www/webpages/managed-switch.html || { echo "Error: managed-switch SPA page missing" >&2; exit 1; }; \
		grep -Fq "managed_switch" rootfs/usr/lib/lua/luci/controller/admin/managed_switch.lua || { echo "Error: managed-switch LuCI route missing" >&2; exit 1; }; \
		grep -Fq "const ENDPOINT=\"/cgi-bin/luci/;stok=/admin/managed_switch\"" rootfs/www/webpages/managed-switch.html || { echo "Error: managed-switch standalone LuCI endpoint missing" >&2; exit 1; }; \
		grep -Fq "credentials:\"same-origin\"" rootfs/www/webpages/managed-switch.html || { echo "Error: managed-switch page does not preserve session credentials" >&2; exit 1; }; \
		if grep -Fq "update-store-DQkZxaRI.js" rootfs/www/webpages/managed-switch.html; then echo "Error: standalone managed-switch page imports SPA-only update-store context" >&2; exit 1; fi; \
		grep -Fq "__AX53_MANAGED_SWITCH_MENU__" <(gzip -dc rootfs/www/webpages/js/index-D26yCMJF.js.gz) || { echo "Error: managed-switch SPA menu launcher missing" >&2; exit 1; }; \
		grep -Fq "__AX53_MANAGED_SWITCH_MENU_V3_NETWORK_CHILD__" <(gzip -dc rootfs/www/webpages/js/index-D26yCMJF.js.gz) || { echo "Error: managed-switch launcher is not the Network/Rede child variant" >&2; exit 1; }; \
		grep -Fq "n===\"rede\"||n===\"network\"" <(gzip -dc rootfs/www/webpages/js/index-D26yCMJF.js.gz) || { echo "Error: managed-switch launcher is not scoped to Rede/Network" >&2; exit 1; }; \
		grep -Fq "findSubmenu" <(gzip -dc rootfs/www/webpages/js/index-D26yCMJF.js.gz) || { echo "Error: managed-switch launcher lacks submenu targeting" >&2; exit 1; }; \
		grep -Fq "/webpages/managed-switch.html" <(gzip -dc rootfs/www/webpages/js/index-D26yCMJF.js.gz) || { echo "Error: managed-switch SPA menu target missing" >&2; exit 1; }; \
		grep -Fxq "enabled=0" rootfs/etc/managed-switch/default.conf || { echo "Error: managed-switch must ship disabled" >&2; exit 1; }; \
		grep -Fxq "wan_vid=4094" rootfs/etc/managed-switch/default.conf || { echo "Error: stock-compatible WAN VID missing" >&2; exit 1; }; \
		grep -Fxq "lan_vid=2" rootfs/etc/managed-switch/default.conf || { echo "Error: stock-compatible LAN VID missing" >&2; exit 1; }; \
		echo "=== [5/6] Repacking firmware ==="; \
		rm -f "$(FIRMWARE_OUTPUT)"; \
		bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)" 2>&1 | tail -8; \
		test -s "$(FIRMWARE_OUTPUT)" || { echo "Error: firmware output missing/empty" >&2; exit 1; }; \
		echo "=== [6/6] Firmware ready ==="; \
		ls -lh "$(FIRMWARE_OUTPUT)"; \
		echo "Build: $$BUILD_NO"; \
		echo "Version: $$STAMPED_VERSION"; \
		echo "Output: $(FIRMWARE_OUTPUT)"; \
		bash scripts/stamp-switch-build.sh advance "$$BUILD_NO"'

tools:
	$(MAKE) -C vendor/mtd-utils
	$(MAKE) -C vendor/squashfs
	$(MAKE) -C vendor/squashfs4

clean:
	rm -f $(TARGET)
	$(MAKE) -C vendor/mtd-utils clean
	$(MAKE) -C vendor/squashfs clean
	$(MAKE) -C vendor/squashfs4 clean
