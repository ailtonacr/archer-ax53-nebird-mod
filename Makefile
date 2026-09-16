CC = gcc
CFLAGS = -Wall -Wextra -pedantic
LDFLAGS = -lcrypto

TARGET = bin/md5-fix
SRCS = src/md5-fix.c
STOCK ?= stock_decrypted.bin
FIRMWARE_OUTPUT ?= work/Archer-AX53-Managed-Switch.bin

.PHONY: all tools clean test-firmware firmware

all: $(TARGET)

$(TARGET): $(SRCS)
	mkdir -p bin
	$(CC) $(CFLAGS) $(SRCS) -o $(TARGET) $(LDFLAGS)

tools:
	$(MAKE) -C vendor/mtd-utils
	$(MAKE) -C vendor/squashfs
	$(MAKE) -C vendor/squashfs4

test-firmware:
	bash -n apply-mods.sh mods/011-devssh.sh mods/020-managed-switch.sh
	sh -n mods/020-managed-switch-files/usr/sbin/managed-switch mods/020-managed-switch-files/etc/init.d/managed-switch
	@test -f mods/011-devssh-files/etc/init.d/devssh
	@test -f mods/020-managed-switch-files/etc/config/managed_switch
	@! find mods -type f -iname '*netbird*' | grep -q . || { echo 'Error: NetBird artifact found in managed-switch branch' >&2; exit 1; }
	@! find mods -maxdepth 1 -type f \( -name '001-telnet.sh' -o -name '002-iperf3.sh' \) | grep -q . || { echo 'Error: unrelated telnet/iperf mod found' >&2; exit 1; }
	@echo 'Managed-switch firmware tests: OK'

firmware: $(TARGET) test-firmware
	@test -f "$(STOCK)" || { echo "Error: stock image not found: $(STOCK)" >&2; exit 1; }
	@mkdir -p "$(dir $(FIRMWARE_OUTPUT))"
	@rm -f "$(FIRMWARE_OUTPUT)"
	@echo '=== [1/4] Unpacking stock firmware ==='
	@rm -rf rootfs tmp-ubi
	@bash 01-unpack-ubi.sh "$(STOCK)"
	@echo '=== [2/4] Applying SSH + managed-switch mods ==='
	@ROOTFS_DIR=rootfs bash apply-mods.sh
	@echo '=== [3/4] Verifying applied rootfs ==='
	@test -x rootfs/etc/init.d/devssh
	@test -x rootfs/usr/sbin/managed-switch
	@test -f rootfs/etc/config/managed_switch
	@! find rootfs -path '*netbird*' -print -quit | grep -q . || { echo 'Error: NetBird artifact unexpectedly present in output rootfs' >&2; exit 1; }
	@echo '=== [4/4] Repacking firmware ==='
	@bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)"
	@echo "Firmware ready: $(FIRMWARE_OUTPUT)"

clean:
	rm -f $(TARGET)
	rm -rf tmp-ubi
	$(MAKE) -C vendor/mtd-utils clean
	$(MAKE) -C vendor/squashfs clean
	$(MAKE) -C vendor/squashfs4 clean
