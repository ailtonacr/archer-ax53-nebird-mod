TARBALL = ./squashfs3.0.tar.gz
SRC_DIR = squashfs3.0
TOOLS_DIR = $(SRC_DIR)/squashfs-tools
BIN_DIR = ../../bin

.PHONY: all extract patch build install clean

all: install

extract:
	@if [ ! -d "$(SRC_DIR)" ]; then \
		echo "Extracting squashfs tarball..."; \
		tar -xzf $(TARBALL); \
	fi

patch: extract
	@if [ ! -f "$(SRC_DIR)/.patched" ]; then \
		echo "Applying squashfs patches..."; \
		../apply_patches.sh $(CURDIR)/$(SRC_DIR) $(CURDIR)/patches && \
		touch $(SRC_DIR)/.patched; \
	fi

build: patch
	@echo "Compiling squashfs tools..."
	$(MAKE) -C $(TOOLS_DIR)

install: build
	@echo "Installing squashfs tools to $(BIN_DIR)..."
	mkdir -p $(BIN_DIR)
	cp $(TOOLS_DIR)/mksquashfs $(BIN_DIR)/
	cp $(TOOLS_DIR)/unsquashfs $(BIN_DIR)/

clean:
	@echo "Cleaning squashfs build environment..."
	rm -rf $(SRC_DIR)
	