#!/bin/bash
set -e

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[1;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_section() {
  echo # black line
  echo -e "${BLUE}======================================${NC}"
  echo -e "${GREEN}$1${NC}"
  echo -e "${BLUE}======================================${NC}"
  echo  # Output a blank line for spacing
}

# Resolve absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROOT_DIR="$SCRIPT_DIR/chroot"
TAR_ARCHIVE="$SCRIPT_DIR/chroot.tar.gz"

# Validate args
if [ "$#" -lt 1 ]; then
    echo -e "${RED}Usage: $0 <encrypted_firmware.bin> [output_decrypted.bin]${NC}"
    exit 1
fi

ENCRYPTED_FW="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

# Default output name: strip a trailing .bin if present, otherwise just
# append the suffix
if [[ "$ENCRYPTED_FW" == *.bin ]]; then
    DEFAULT_DECRYPTED_FW="${ENCRYPTED_FW%.bin}_decrypted.bin"
else
    DEFAULT_DECRYPTED_FW="${ENCRYPTED_FW}_decrypted.bin"
fi
DECRYPTED_FW="${2:-$DEFAULT_DECRYPTED_FW}"

# Resolve to an absolute path first
if [[ "$DECRYPTED_FW" != /* ]]; then
    DECRYPTED_FW="$(pwd)/$DECRYPTED_FW"
fi

if [ -d "$DECRYPTED_FW" ]; then
    DECRYPTED_FW="$(cd "$DECRYPTED_FW" && pwd)/$(basename "$DEFAULT_DECRYPTED_FW")"
fi

if [ ! -f "$ENCRYPTED_FW" ]; then
    echo -e "${RED}[✗] Error: Encrypted firmware '$ENCRYPTED_FW' not found!${NC}"
    exit 1
fi

log_section "Checking Paths"
echo -e "${BLUE}[*] Defined Paths ...${NC}"
echo -e " ├─ ${YELLOW}Source:${NC} $ENCRYPTED_FW"
echo -e " └─ ${YELLOW}Target:${NC} $DECRYPTED_FW\n"

# hexdump 
dump_preview() {
    local label="$1" path="$2"
    if ! command -v hexdump >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] 'hexdump' not found on PATH -- skipping ${label} preview.${NC}\n"
        return 0
    fi
    echo -e "${BLUE}[*] Hexdump preview (${label}, first 100 lines):${NC} $path"
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
    hexdump -C "$path" | head -n 100
    echo -e "${YELLOW}--------------------------------------------------------------------${NC}\n"
}

log_section "Extracting and setting up chroot ..."
if [ ! -d "$CHROOT_DIR" ]; then
    echo -e "${BLUE}[*] Extracting chroot environment from archive (sudo, preserving perms)...${NC}"
    if [ ! -f "$TAR_ARCHIVE" ]; then
        echo -e "${RED}[✗] Error: '$TAR_ARCHIVE' not found in $SCRIPT_DIR!${NC}"
        exit 1
    fi
    sudo tar -xzpf "$TAR_ARCHIVE" -C "$SCRIPT_DIR/"
fi

# check to make sure tplink firmware check binary exists
if [ ! -x "$CHROOT_DIR/usr/bin/nvrammanager" ]; then
    echo -e "${RED}[✗] Error: $CHROOT_DIR/usr/bin/nvrammanager missing or not executable.${NC}"
    echo -e "${RED}    The chroot looks incomplete or wrong.${NC}"
    exit 1
fi

# copy qemu-arm-static into the chroot
# wget https://github.com/multiarch/qemu-user-static/releases/latest/download/qemu-arm-static
if [ ! -x "$CHROOT_DIR/usr/bin/qemu-arm-static" ]; then
    echo -e "${BLUE}[*] Copying qemu-arm-static into chroot...${NC}"
    if [ ! -f "$SCRIPT_DIR/qemu-arm-static" ]; then
        echo -e "${RED}[✗] Error: '$SCRIPT_DIR/qemu-arm-static' missing from $SCRIPT_DIR!${NC}"
        exit 1
    fi
    sudo cp "$SCRIPT_DIR/qemu-arm-static" "$CHROOT_DIR/usr/bin/"
    sudo chmod +x "$CHROOT_DIR/usr/bin/qemu-arm-static"
fi

# Copy firmware and arm the hard-link trap
EXEC_FILE="payload_exec.bin"
SURVIVOR_FILE="payload_survivor.bin"

echo -e "${BLUE}[*] Staging firmware and setting hard-link trap...${NC}"
sudo cp "$ENCRYPTED_FW" "$CHROOT_DIR/$EXEC_FILE"
sudo rm -f "$CHROOT_DIR/$SURVIVOR_FILE"

# nvrammanager will delete the decrypted firmware as soon as it realizes model number don't match
# so we create a hard link (no -s!) so the data survives when nvrammanager unlinks EXEC_FILE
# This allows us to decrypt firmware for other tplink models -- not just limited to ax53
# Tested and can confirm this works for ax55 latest firmware
sudo ln "$CHROOT_DIR/$EXEC_FILE" "$CHROOT_DIR/$SURVIVOR_FILE"

log_section "Hex dump of header before decryption:"
dump_preview "encrypted input" "$ENCRYPTED_FW"

log_section "Decrypting ..."
echo -e "${BLUE}[*] Executing native ARM decryption via kernel chroot...${NC}"
echo -e "${YELLOW}--------------------------------------------------------------------${NC}"
echo

# Execute nvrammanager inside the kernel chroot
# disable 'set -e' because nvrammanager will exit with an error code upon model mismatch
set +e
sudo chroot "$CHROOT_DIR" /usr/bin/qemu-arm-static /usr/bin/nvrammanager -c "/$EXEC_FILE"
QEMU_EXIT_CODE=$?
set -e

echo -e "${YELLOW}--------------------------------------------------------------------${NC}\n"

echo -e "${YELLOW}[*] nvrammanager exit code: $QEMU_EXIT_CODE (ignored -- a nonzero/crashed exit here is${NC}"
echo -e "${YELLOW}    expected on hardware/model mismatch and does not affect the outcome below;${NC}"
echo -e "${YELLOW}    what matters is whether a firmware file actually got produced.)${NC}"
echo

# Harvest the decrypted payload from the survivor link, regardless
# of whether nvrammanager itself reported success or failure above.
if [ -f "$CHROOT_DIR/$SURVIVOR_FILE" ]; then
    echo -e "${GREEN}[✔] Hard-link trap survived! fetching payload...${NC}"

    # Move the survivor file to the requested destination
    sudo mv "$CHROOT_DIR/$SURVIVOR_FILE" "$DECRYPTED_FW"

    # Restore file ownership from root back to the current regular user
    sudo chown $(id -u):$(id -g) "$DECRYPTED_FW"

    # Clean up the primary execution file if nvrammanager didn't delete it
    sudo rm -f "$CHROOT_DIR/$EXEC_FILE"
    echo
    OUT_SIZE=$(stat -c%s "$DECRYPTED_FW" 2>/dev/null || echo 0)
    if [ "$OUT_SIZE" -gt 0 ]; then
        echo -e "${GREEN}[✔] Firmware file produced: $DECRYPTED_FW ($OUT_SIZE bytes)${NC}"
    else
        echo -e "${RED}[✗] Output file exists but is EMPTY (0 bytes) -- something went wrong upstream.${NC}"
    fi

    log_section "Hexdump of header after Decryption:"
    echo
    dump_preview "decrypted output" "$DECRYPTED_FW"

    echo -e "${BLUE}[*] Cleaning up chroot environment (will be re-extracted fresh next run)...${NC}"
    sudo rm -rf "$CHROOT_DIR"

    # ---- final summary ------------------------------------------------
    ORIG_SHA256=$(sha256sum "$ENCRYPTED_FW" | awk '{print $1}')
    DEC_SHA256=$(sha256sum "$DECRYPTED_FW" | awk '{print $1}')
    echo
    echo -e "${BLUE}[*] Summary${NC}"
    echo -e " ├─ ${YELLOW}sha256 (orig):${NC}      $ORIG_SHA256"
    echo -e " ├─ ${YELLOW}sha256 (decrypted):${NC} $DEC_SHA256"
    if [ "$ORIG_SHA256" = "$DEC_SHA256" ]; then
        echo -e " ├─ ${YELLOW}note:${NC} hashes match -- content identical to input, AES stage may not have run"
    fi
    echo -e " ├─ ${YELLOW}Original FW: ${NC} $ENCRYPTED_FW"
    echo -e " └─ ${YELLOW}Decrypted FW:${NC} $DECRYPTED_FW"
else
    echo -e "${RED}[✗] Fatal Error: Survivor file not found -- no firmware was produced at all.${NC}"
    exit 1
fi
