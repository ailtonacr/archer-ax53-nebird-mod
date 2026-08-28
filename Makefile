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

.PHONY: all tools clean firmware

all: $(TARGET)

$(TARGET): $(SRCS)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

# Build a complete AX53 firmware from a decrypted stock image.
# apply-mods.sh already runs the NetBird frontend patcher, so it must not be
# invoked separately here. pipefail guarantees that a failing build stage is
# not hidden by tail. ROOTFS_DIR=rootfs pins the exact tree produced by
# 01-unpack-ubi.sh, so a stale squashfs-root/ can never receive the mods by
# accident while rootfs/ gets repacked unchanged.
#
# Build identity is stamped after all mods and before validation/repack:
#   soft_ver:1.7.1-netbird mod Build N
#   /etc/netbird-build -> build number + git commit/branch + UTC timestamp
# The BUILD counter advances only after the output image exists successfully.
firmware: $(TARGET)
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
		echo "=== [4/6] Verifying modified rootfs before repack ==="; \
		grep -q "NetBird adapter for TP-Link" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua || { echo "Error: NetBird VPN adapter missing from rootfs" >&2; exit 1; }; \
		test -f rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua || { echo "Error: preserved stock VPN controller missing from rootfs" >&2; exit 1; }; \
		python3 -c "from pathlib import Path; p=Path(\"rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua\"); assert p.read_bytes()[:4] == b\"\\x1bLua\", f\"invalid stock VPN bytecode header: {p.read_bytes()[:4]!r}\""; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "Ações NetBird" || { echo "Error: current native NetBird frontend missing from rootfs" >&2; exit 1; }; \
		if zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "__netbirdSaveDraft"; then echo "Error: legacy NetBird save bridge still present in rootfs" >&2; exit 1; fi; \
		grep -Fxq "soft_ver:1.7.1-netbird mod Build $$BUILD_NO" rootfs/etc/partition_config/soft-version || { echo "Error: stamped soft version missing or unexpected" >&2; cat rootfs/etc/partition_config/soft-version >&2; exit 1; }; \
		grep -Fxq "build=$$BUILD_NO" rootfs/etc/netbird-build || { echo "Error: /etc/netbird-build has wrong build number" >&2; exit 1; }; \
		echo "    ok native VPN adapter"; \
		echo "    ok preserved stock VPN controller"; \
		echo "    ok current NetBird frontend"; \
		echo "    ok build identity: 1.7.1-netbird mod Build $$BUILD_NO"; \
		echo "=== [5/6] Repacking firmware ==="; \
		rm -f "$(FIRMWARE_OUTPUT)"; \
		bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)" 2>&1 | tail -5; \
		test -s "$(FIRMWARE_OUTPUT)" || { echo "Error: firmware output missing/empty after repack" >&2; exit 1; }; \
		echo "=== [6/6] Firmware ready ==="; \
		ls -lh "$(FIRMWARE_OUTPUT)"; \
		echo "Build: $$BUILD_NO"; \
		echo "Version: 1.7.1-netbird mod Build $$BUILD_NO"; \
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
