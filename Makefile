CC = gcc
CFLAGS = -Wall -Wextra -pedantic
LDFLAGS = -lcrypto

TARGET = bin/md5-fix
SRCS = src/md5-fix.c

# Firmware build defaults. Override on the command line when needed, e.g.:
#   make firmware STOCK=other_decrypted.bin
#   make firmware FIRMWARE_OUTPUT=work/Archer-AX53-NetBird-test.bin
STOCK ?= stock_decrypted.bin
FIRMWARE_OUTPUT ?= work/Archer-AX53-NetBird.bin

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
firmware: $(TARGET)
	@bash -o pipefail -c 'set -e; \
		test -f "$(STOCK)" || { echo "Error: stock image not found: $(STOCK)" >&2; exit 1; }; \
		mkdir -p "$(dir $(FIRMWARE_OUTPUT))"; \
		echo "=== [1/5] Unpacking stock firmware ==="; \
		rm -rf rootfs tmp-ubi; \
		bash 01-unpack-ubi.sh "$(STOCK)" 2>&1 | tail -5; \
		echo "=== [2/5] Applying NetBird modifications to rootfs ==="; \
		ROOTFS_DIR=rootfs bash apply-mods.sh 2>&1 | tail -40; \
		echo "=== [3/5] Verifying modified rootfs before repack ==="; \
		grep -q "NetBird adapter for TP-Link" rootfs/usr/lib/lua/luci/controller/admin/vpn.lua || { echo "Error: NetBird VPN adapter missing from rootfs" >&2; exit 1; }; \
		test -f rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua || { echo "Error: preserved stock VPN controller missing from rootfs" >&2; exit 1; }; \
		python3 -c "from pathlib import Path; p=Path(\"rootfs/usr/lib/lua/luci/controller/admin/vpn_stock.lua\"); assert p.read_bytes()[:4] == b\"\\x1bLua\", f\"invalid stock VPN bytecode header: {p.read_bytes()[:4]!r}\""; \
		zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "Ações NetBird" || { echo "Error: current native NetBird frontend missing from rootfs" >&2; exit 1; }; \
		if zcat rootfs/www/webpages/js/VpnServerNetbirdForm-NB.js.gz | grep -q "__netbirdSaveDraft"; then echo "Error: legacy NetBird save bridge still present in rootfs" >&2; exit 1; fi; \
		echo "    ok native VPN adapter"; \
		echo "    ok preserved stock VPN controller"; \
		echo "    ok current NetBird frontend"; \
		echo "=== [4/5] Repacking firmware ==="; \
		rm -f "$(FIRMWARE_OUTPUT)"; \
		bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)" 2>&1 | tail -5; \
		echo "=== [5/5] Firmware ready ==="; \
		ls -lh "$(FIRMWARE_OUTPUT)"; \
		echo "Output: $(FIRMWARE_OUTPUT)"'

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
