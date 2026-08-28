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
# not hidden by tail.
firmware: $(TARGET)
	@bash -o pipefail -c 'set -e; \
		test -f "$(STOCK)" || { echo "Error: stock image not found: $(STOCK)" >&2; exit 1; }; \
		mkdir -p "$(dir $(FIRMWARE_OUTPUT))"; \
		echo "=== [1/4] Unpacking stock firmware ==="; \
		rm -rf rootfs tmp-ubi; \
		bash 01-unpack-ubi.sh "$(STOCK)" 2>&1 | tail -5; \
		echo "=== [2/4] Applying NetBird modifications ==="; \
		bash apply-mods.sh 2>&1 | tail -30; \
		echo "=== [3/4] Repacking firmware ==="; \
		rm -f "$(FIRMWARE_OUTPUT)"; \
		bash 02-repack-ubi.sh "$(FIRMWARE_OUTPUT)" 2>&1 | tail -5; \
		echo "=== [4/4] Firmware ready ==="; \
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
