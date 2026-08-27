#!/bin/bash -e
if [ $# -ne 1 ]; then
  echo "Usage: $0 <new firmware filename>"
  exit 1
fi

# Pin repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
firmware="$1"
case "$firmware" in
  /*) : ;;                                   # already absolute
  *) firmware="$(pwd)/$firmware" ;;
esac
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"
# -------------------------

if [ -f "$firmware" ]; then
  echo "Error: file already exists: $firmware"
  exit 1
fi

MKFS_UBIFS="$PROJECT_ROOT/bin/mkfs.ubifs"
UBINIZE="$PROJECT_ROOT/bin/ubinize"
MD5FIX="$PROJECT_ROOT/bin/md5-fix"

# Using the vendor-patched binaries (built from TP-Link's own GPL-released
# mtd-utils 1.5.1 + 136-mkfs.ubifs-xz-support.patch), NOT system mkfs.ubifs/
# ubinize. Mainline mtd-utils has no XZ backend at all, and this vendor
# kernel interprets UBIFS compression type 3 as XZ (not zstd, mainline's
# assignment for that slot) -- confirmed independently both by direct byte
# inspection during unpack AND by reading this exact patch's enum insertion
# (UBIFS_COMPR_XZ landing at value 3 by construction). See project notes.
for bin_path in "$MKFS_UBIFS" "$UBINIZE" "$MD5FIX"; do
  if [ ! -x "$bin_path" ]; then
    echo "Error: $bin_path not found or not executable."
    echo "       Build it first: see vendor/mtd-utils/ and the project Makefile."
    exit 1
  fi
done

if [ ! -f "tmp-ubi/stock_ubi_size.txt" ]; then
  echo "Error: tmp-ubi/stock_ubi_size.txt not found. You must run 01-unpack.sh first to capture the target size."
  exit 1
fi

# --- LOAD DYNAMIC UBI LAYOUT ---
# Captured by 01-unpack.sh from the actual stock image's volume table
# (LEB_SIZE, ROOTFS_PEBS, ROOTFS_BUDGET_BYTES, ROOTFS_VOL_SIZE_KIB). Nothing
# firmware-size-related below is hardcoded anymore -- if TP-Link ships a
# revision with a different partition table, re-running 01-unpack.sh against
# that dump picks it up automatically.
if [ ! -f "tmp-ubi/ubi_layout.env" ]; then
  echo "Error: tmp-ubi/ubi_layout.env not found. You must run 01-unpack.sh first to capture the UBI layout."
  exit 1
fi
# shellcheck source=/dev/null
source tmp-ubi/ubi_layout.env

for var in LEB_SIZE ROOTFS_PEBS ROOTFS_BUDGET_BYTES ROOTFS_VOL_SIZE_KIB; do
  if [ -z "${!var:-}" ]; then
    echo "Error: $var missing from tmp-ubi/ubi_layout.env -- re-run 01-unpack.sh." >&2
    exit 1
  fi
done
echo "Loaded UBI layout: LEB_SIZE=${LEB_SIZE}B ROOTFS_PEBS=${ROOTFS_PEBS} budget=${ROOTFS_BUDGET_BYTES}B (${ROOTFS_VOL_SIZE_KIB}KiB)"
# --------------------------------

# --- DYNAMIC JOURNAL SIZE ---
# Previously hardcoded at 4698112 bytes. That number is exactly 37 LEBs
# (37 * 126976), which against the stock 282-PEB ubi_rootfs reservation
# works out to ~13.12% of the rootfs volume. Rather than hardcode the byte
# count, we preserve that same PEB-count-to-budget ratio and scale it to
# whatever ROOTFS_PEBS this firmware actually has, rounding to the nearest
# whole LEB (UBIFS journal size should be a multiple of the LEB size) with
# a floor so we never ask mkfs.ubifs for a journal too small to be valid.
#
# Override: set JOURNAL_LEBS_OVERRIDE to force an exact LEB count instead.
JOURNAL_RATIO_NUM=37
JOURNAL_RATIO_DEN=282
MIN_JOURNAL_LEBS=8

if [ -n "${JOURNAL_LEBS_OVERRIDE:-}" ]; then
  JOURNAL_LEBS="$JOURNAL_LEBS_OVERRIDE"
else
  # Integer round-to-nearest: (a*num + den/2) / den
  JOURNAL_LEBS=$(( (ROOTFS_PEBS * JOURNAL_RATIO_NUM + JOURNAL_RATIO_DEN / 2) / JOURNAL_RATIO_DEN ))
  if [ "$JOURNAL_LEBS" -lt "$MIN_JOURNAL_LEBS" ]; then
    JOURNAL_LEBS=$MIN_JOURNAL_LEBS
  fi
fi
JOURNAL_BYTES=$((JOURNAL_LEBS * LEB_SIZE))
echo "Journal size: ${JOURNAL_LEBS} LEBs = ${JOURNAL_BYTES} bytes (ratio ${JOURNAL_RATIO_NUM}:${JOURNAL_RATIO_DEN} of ${ROOTFS_PEBS} rootfs PEBs)"
# -----------------------------

echo "Compiling native UBIFS filesystem with real XZ compression..."
# -m 2048 (min I/O), -e 124KiB (Logical Erase Block), -c 4096 (Max LEB count)
#
# NOTE: "-x xz" alone is REJECTED by this vendor-patched mkfs.ubifs
# ("Error: 'xz' can't be used as default compressor") -- confirmed via
# direct testing. The working invocation is "-x zlib -z xz": -x sets a
# required-but-functionally-irrelevant nominal default (zlib passes the
# validation -x xz doesn't), while -z/--force-compr unconditionally
# overrides EVERY file's compression to xz regardless of what -x says.
# This matches how TP-Link's own build most likely always invoked it.
fakeroot "$MKFS_UBIFS" -r rootfs/ -m 2048 -e 124KiB -c 4096 -x zlib -z xz -j "$JOURNAL_BYTES" -F -U -o tmp-ubi/rootfs.bin

# --- SIZE COMPARISON (informational, not a gate) ---
# Confirmed via `df -h` on a live AX53: ubi_rootfs mounts read-only at
# /rom, 100% used, 0 available -- and the actual writable layer is a
# tmpfs-backed overlay (RAM, non-persistent), not ubi_rootfs itself.
# Nothing ever writes back into this volume at runtime, so there's no
# "reserve headroom for future growth" requirement the way a genuinely
# live/writable UBIFS volume might need. Stock's own 282-PEB reservation
# is just whatever TP-Link's build happened to produce, not a limit the
# device enforces -- UBI reads the volume table fresh from whatever image
# is actually flashed. The real constraint is the final partition-size
# check below, against the physical mtd partition, not this number.
ROOTFS_BIN_SIZE=$(stat -c%s tmp-ubi/rootfs.bin)
echo "Built rootfs.bin: $ROOTFS_BIN_SIZE bytes (stock's own build was: $ROOTFS_BUDGET_BYTES bytes)"
if [ "$ROOTFS_BIN_SIZE" -gt "$ROOTFS_BUDGET_BYTES" ]; then
    echo "Note: larger than stock's own ubi_rootfs footprint -- not an error by"
    echo "      itself, checked against the real partition ceiling further down."
else
    echo "Within stock's own footprint ($(( ROOTFS_BUDGET_BYTES - ROOTFS_BIN_SIZE )) bytes under it)."
fi
# --------------------

kernel=$(find tmp-ubi -name "*kernel.ubifs" | head -n 1)
if [ -z "$kernel" ]; then
  echo "Error: kernel.ubifs not found in tmp-ubi/."
  exit 1
fi

echo "Found kernel at: $kernel"
[[ -f tmp-ubi/kernel.itb ]] && rm -f tmp-ubi/kernel.itb
cp -f "$kernel" tmp-ubi/kernel.itb

# --- RENDER ubinize.cfg FROM TEMPLATE ---
# etc/ubinize-ipq50xx.cfg.tmpl carries a @PROJECT_ROOT@ placeholder.
# No longer forcing a vol_size on [rootfs] here -- see the "SIZE
# COMPARISON" note above for why: ubi_rootfs mounts read-only on this
# device with no runtime write-growth need, so there's no reason to
# reserve headroom beyond content size. ubinize sizes it to fit instead.
TEMPLATE="etc/ubinize-ipq50xx.cfg.tmpl"
if [ ! -f "$TEMPLATE" ]; then
  echo "Error: $TEMPLATE not found." >&2
  exit 1
fi
sed -e "s#@PROJECT_ROOT@#${PROJECT_ROOT}#g" \
    "$TEMPLATE" > tmp-ubi/ubinize.cfg
echo "Rendered tmp-ubi/ubinize.cfg"
# -----------------------------------------

echo "Running ubinize to build UBI container..."
"$UBINIZE" -m 2048 -p 128KiB -o tmp-ubi/ubi-new.img tmp-ubi/ubinize.cfg

# --- PHYSICAL PARTITION CEILING ---
# Read from tmp-ubi/ubi_layout.env, where 01-unpack-ubi.sh captured it
# fresh from THIS firmware's own rootfs/etc/partition_config/partition-table
# -- not a number typed in by hand. Falls back to the AX53-hardware-verified
# constant only if ubi_layout.env predates this capture (re-run
# 01-unpack-ubi.sh to pick up the dynamic detection).
if [ -z "${PARTITION_SIZE_BYTES:-}" ]; then
  PARTITION_SIZE_BYTES=44040192
  echo "Note: PARTITION_SIZE_BYTES missing from tmp-ubi/ubi_layout.env (old unpack run?)"
  echo "      -- falling back to the AX53-hardware-verified default: $PARTITION_SIZE_BYTES bytes."
  echo "      Re-run 01-unpack-ubi.sh to capture it fresh from this firmware instead."
fi

# PADDING LOGIC
STOCK_UBI_SIZE=$(cat tmp-ubi/stock_ubi_size.txt)
current_size=$(stat -c%s tmp-ubi/ubi-new.img)

# Always write at least as much as stock's own build did -- padded with
# 0xFF to simulate a clean erase -- preserving the original intent for
# anything within that footprint.
if [ "$current_size" -lt "$STOCK_UBI_SIZE" ]; then
    pad_bytes=$((STOCK_UBI_SIZE - current_size))
    echo "Padding ubi-new.img with $pad_bytes bytes (0xFF) to match stock's own footprint ($STOCK_UBI_SIZE bytes)..."
    # Generate 0xFF bytes to simulate erased NAND memory
    head -c "$pad_bytes" /dev/zero | tr '\0' '\377' >> tmp-ubi/ubi-new.img
    current_size=$STOCK_UBI_SIZE
elif [ "$current_size" -gt "$STOCK_UBI_SIZE" ]; then
    echo "Note: built image ($current_size bytes) is larger than stock's own"
    echo "      footprint ($STOCK_UBI_SIZE bytes) -- checking against the real"
    echo "      partition ceiling instead of treating this alone as an error."
fi

# The actual hard constraint: does it fit the real physical partition?
if [ "$current_size" -gt "$PARTITION_SIZE_BYTES" ]; then
    echo "ERROR: ubi-new.img ($current_size bytes) exceeds the actual mtd"
    echo "       partition size ($PARTITION_SIZE_BYTES bytes, verified via"
    echo "       /proc/mtd). This WOULD overflow the partition on flash --"
    echo "       do not proceed. Trim rootfs/ before retrying."
    exit 1
fi
echo "OK — $current_size / $PARTITION_SIZE_BYTES bytes used ($(( PARTITION_SIZE_BYTES - current_size )) bytes headroom against the real partition)"

echo "Stitching image..."
cat tmp-ubi/header.bin tmp-ubi/ubi-new.img > "$firmware"

echo "Applying 'Proud' bypass hack to firmware header..."
printf '\x50\x72' | dd of="$firmware" bs=1 seek=28 count=2 conv=notrunc

echo "Recalculating MD5 checksum..."
"$MD5FIX" "$firmware"

echo "Success! Firmware repacked to: $firmware"
