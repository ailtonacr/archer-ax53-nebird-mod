TARBALL = ./mtd-utils-1.5.1-92686f212c9a4e16891c6a3c57629cbf4f0f8360.tar.gz
SRC_DIR = mtd-utils-1.5.1
BIN_DIR = ../../bin

.PHONY: all extract patch build install clean

all: install

extract:
	@if [ ! -d "$(SRC_DIR)" ]; then \
		echo "Extracting mtd-utils tarball..."; \
		tar -xzf $(TARBALL); \
	fi

patch: extract
	@if [ ! -f "$(SRC_DIR)/.patched" ]; then \
		echo "Applying TP-Link/OpenWrt patches..."; \
		../apply_patches.sh $(CURDIR)/$(SRC_DIR) $(CURDIR)/patches && \
		touch $(SRC_DIR)/.patched; \
	fi

build: patch
	@echo "Compiling mtd-utils..."
	$(MAKE) -C $(SRC_DIR) \
		WITHOUT_LZO=1 \
		WITHOUT_XATTR=1 \
		SUBDIRS="" \
		TARGETS="mkfs.jffs2 ubi-utils/ubinize mkfs.ubifs/mkfs.ubifs"

install: build
	@echo "Installing tools to $(BIN_DIR)..."
	mkdir -p $(BIN_DIR)
	cp $(SRC_DIR)/mkfs.jffs2 $(BIN_DIR)/
	cp $(SRC_DIR)/ubi-utils/ubinize $(BIN_DIR)/
	cp $(SRC_DIR)/mkfs.ubifs/mkfs.ubifs $(BIN_DIR)/

clean:
	@echo "Cleaning mtd-utils build environment..."
	rm -rf $(SRC_DIR)
	