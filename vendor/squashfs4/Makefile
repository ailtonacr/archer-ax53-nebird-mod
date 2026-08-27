TARBALL = ./squashfs4.2.tar.gz
SRC_DIR = squashfs4.2
TOOLS_DIR = $(SRC_DIR)/squashfs-tools
BIN_DIR = ../../bin

CC = gcc

# Dynamic linking against system liblzma (install liblzma-dev or xz-devel first)
# For static linking instead, use: LZMA_LIB = /usr/lib/x86_64-linux-gnu/liblzma.a
LZMA_LIB = -llzma

.PHONY: all extract patch build install clean

all: install

extract:
	@if [ ! -d "$(SRC_DIR)" ]; then \
		echo "Extracting squashfs4 tarball..."; \
		tar -xzf $(TARBALL); \
	fi

patch: extract
	@if [ ! -f "$(SRC_DIR)/.patched" ]; then \
		echo "Applying squashfs4 patches..."; \
		../apply_patches.sh $(CURDIR)/$(SRC_DIR) $(CURDIR)/patches && \
		touch $(SRC_DIR)/.patched; \
	fi

build: patch
	@echo "Compiling squashfs4 tools..."
	$(MAKE) -C $(TOOLS_DIR) \
		CC="$(CC)" \
		XZ_SUPPORT=1 \
		LZMA_XZ_SUPPORT=1 \
		XATTR_SUPPORT= \
		LZMA_LIB="$(LZMA_LIB)" \
		mksquashfs unsquashfs

install: build
	@echo "Installing squashfs4 tools to $(BIN_DIR)..."
	mkdir -p $(BIN_DIR)
	cp $(TOOLS_DIR)/mksquashfs $(BIN_DIR)/mksquashfs4
	cp $(TOOLS_DIR)/unsquashfs $(BIN_DIR)/unsquashfs4

clean:
	@echo "Cleaning squashfs4 build environment..."
	$(MAKE) -C $(TOOLS_DIR) clean
	rm -rf $(SRC_DIR)
	