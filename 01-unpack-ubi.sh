#!/bin/bash -e
if [ $# -ne 1 ]; then
  echo "Usage: $0 <firmware>"
  exit 1
fi

if [ ! -f "$1" ]; then
  echo "Error: file not found: $1"
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

# --- SELF-CONTAINED ubi_reader (no pip-installed console scripts) ---
# ubi_reader is vendored in-repo instead of relying on `ubireader_*`
# console scripts from some venv's PATH -- see vendor/ubi_reader/README.md
# for the pinned version/sha256/license and, importantly, the caveat
# about ubi_reader's own compiled deps (lzallright/zstandard/cryptography)
# which vendoring the source does NOT eliminate.
# Override with UBIREADER_SRC_OVERRIDE=/path/to/ubi_reader/src if needed.
UBIREADER_VERSION="0.8.14"
UBIREADER_SRC="${UBIREADER_SRC_OVERRIDE:-$PROJECT_ROOT/vendor/ubi_reader/src/ubi_reader-$UBIREADER_VERSION}"
if [ ! -d "$UBIREADER_SRC/ubireader" ]; then
  echo "Error: vendored ubi_reader source not found at $UBIREADER_SRC" >&2
  echo "       See vendor/ubi_reader/README.md to (re)populate it." >&2
  exit 1
fi
export PYTHONPATH="$UBIREADER_SRC${PYTHONPATH:+:$PYTHONPATH}"
# ----------------------------------------------------------------------

[ -d rootfs ] && rm -rf rootfs
[ -d tmp-ubi ] && rm -rf tmp-ubi

pos=$(grep -a -b -m 1 "UBI#" "$firmware" | cut -d ":" -f 1)
if [ -z "$pos" ] || ! [[ "$pos" =~ ^[0-9]+$ ]]; then
  echo "Error: no 'UBI#' magic found in $firmware -- this file likely isn't" >&2
  echo "       the same header+raw-UBI-container format the rest of this" >&2
  echo "       pipeline assumes (e.g. a different signed/nosign recovery" >&2
  echo "       image wrapper). Run 'binwalk \"$firmware\"' to see what's" >&2
  echo "       actually inside before treating this as a repack bug." >&2
  exit 1
fi
mkdir -p tmp-ubi

# --- DYNAMIC SIZE CALCULATION ---
# Calculate the exact size of the UBI portion of the stock firmware
# so we can perfectly pad our repacked image later.
stock_total=$(stat -c%s "$firmware")
stock_ubi_size=$((stock_total - pos))
echo "$stock_ubi_size" > tmp-ubi/stock_ubi_size.txt
# --------------------------------

dd if="$firmware" of=tmp-ubi/header.bin bs="$pos" count=1
dd if="$firmware" of=tmp-ubi/ubi.img bs="$pos" skip=1

echo "Extracting UBI container..."
cd tmp-ubi
python3 -m ubireader.scripts.ubireader_extract_images ubi.img

# --- DYNAMIC UBI LAYOUT CAPTURE ---
# Read the actual volume table out of THIS firmware's UBI image (LEB size,
# reserved PEBs per volume) instead of hardcoding numbers we measured once
# against one dump. 02-repack.sh sources tmp-ubi/ubi_layout.env to compute the
# rootfs budget, the ubinize vol_size, and the mkfs.ubifs journal size, so
# if a firmware revision ever ships with a different partition table this
# is picked up automatically rather than silently repacking against a
# stale budget.
#
# Override knobs (skip auto-detection if the display_info output format
# ever changes on us): set LEB_SIZE_OVERRIDE / ROOTFS_PEBS_OVERRIDE /
# KERNEL_PEBS_OVERRIDE in the environment before running this script.
echo "Reading UBI volume layout..."
python3 -m ubireader.scripts.ubireader_display_info ubi.img > ubi_info.txt 2>&1 || true

if [ -n "${LEB_SIZE_OVERRIDE:-}" ]; then
  LEB_SIZE="$LEB_SIZE_OVERRIDE"
else
  LEB_SIZE=$(awk '/^[[:space:]]*LEB Size:/ {print $NF; exit}' ubi_info.txt)
fi

find_reserved_pebs() {
  # $1 = volume name to look for
  awk -v target="$1" '
    /^[[:space:]]*Volume: / { vol=$NF }
    /reserved_pebs:/ { if (vol==target) { print $NF; exit } }
  ' ubi_info.txt
}

if [ -n "${ROOTFS_PEBS_OVERRIDE:-}" ]; then
  ROOTFS_PEBS="$ROOTFS_PEBS_OVERRIDE"
else
  ROOTFS_PEBS=$(find_reserved_pebs "ubi_rootfs")
fi

if [ -n "${KERNEL_PEBS_OVERRIDE:-}" ]; then
  KERNEL_PEBS="$KERNEL_PEBS_OVERRIDE"
else
  KERNEL_PEBS=$(find_reserved_pebs "kernel")
fi

if [ -z "$LEB_SIZE" ] || [ -z "$ROOTFS_PEBS" ]; then
  echo "Error: could not auto-detect UBI layout from 'ubireader_display_info ubi.img'." >&2
  echo "       Inspect tmp-ubi/ubi_info.txt manually, then re-run with" >&2
  echo "       LEB_SIZE_OVERRIDE=<bytes> ROOTFS_PEBS_OVERRIDE=<count> $0 $1" >&2
  exit 1
fi

ROOTFS_BUDGET_BYTES=$((ROOTFS_PEBS * LEB_SIZE))
if [ $((ROOTFS_BUDGET_BYTES % 1024)) -ne 0 ]; then
  echo "Error: computed rootfs budget ($ROOTFS_BUDGET_BYTES bytes) isn't a" >&2
  echo "       whole number of KiB -- LEB_SIZE=$LEB_SIZE looks wrong, check tmp-ubi/ubi_info.txt" >&2
  exit 1
fi
ROOTFS_VOL_SIZE_KIB=$((ROOTFS_BUDGET_BYTES / 1024))

cat > ubi_layout.env <<EOF
# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ) from: $(basename "$firmware")
LEB_SIZE=$LEB_SIZE
ROOTFS_PEBS=$ROOTFS_PEBS
KERNEL_PEBS=${KERNEL_PEBS:-0}
ROOTFS_BUDGET_BYTES=$ROOTFS_BUDGET_BYTES
ROOTFS_VOL_SIZE_KIB=$ROOTFS_VOL_SIZE_KIB
EOF

echo "Detected: LEB_SIZE=${LEB_SIZE}B, ubi_rootfs reserved_pebs=${ROOTFS_PEBS} (budget ${ROOTFS_BUDGET_BYTES}B / ${ROOTFS_VOL_SIZE_KIB}KiB), kernel reserved_pebs=${KERNEL_PEBS:-unknown}"
echo "Layout captured to tmp-ubi/ubi_layout.env"
# -----------------------------------

# Find the raw UBIFS volume
ROOTFS_UBIFS=$(find . -name "*rootfs.ubifs" | head -n 1)

# --- FILESYSTEM TYPE SNIFF ---
# ubireader_extract_images names every per-volume dump "*.ubifs" purely
# from the UBI *volume* name ("ubi_rootfs") -- it does not inspect the
# payload at all. Some firmware revisions (confirmed: AX55 v1.3.3) still
# ship SquashFS inside that volume, not UBIFS -- consistent with the
# earlier v1.2.2 forum dump's squashfs-root/rootfs_data-overlay layout.
# Feeding that straight into the UBIFS extractor produces misleading
# parser errors ("Block size could not be determined", "Wrong node
# type") that look like a UBIFS bug but really just mean "this isn't
# UBIFS". Sniff the real magic first and fail cleanly on anything else --
# non-UBIFS firmware is out of scope for this script; use the dedicated
# squashfs unpack script for that case.
magic=$(od -An -tx1 -N 4 "$ROOTFS_UBIFS" | tr -d ' \n')
case "$magic" in
  31181006)  # UBIFS common-node-header magic (0x06101831, little-endian on disk)
    ;;
  68737173)  # "hsqs" -- SquashFS, little-endian
    echo "Error: $ROOTFS_UBIFS is SquashFS, not UBIFS." >&2
    echo "       This script only handles UBIFS rootfs images" >&2
    exit 1
    ;;
  *)
    echo "Error: $ROOTFS_UBIFS doesn't start with a recognized filesystem" >&2
    echo "       magic (got: ${magic:-<empty>}). Expected a UBIFS superblock" >&2
    echo "       node (0x06101831)." >&2
    echo "       Run: binwalk \"$PROJECT_ROOT/tmp-ubi/$ROOTFS_UBIFS\" to identify it." >&2
    exit 1
    ;;
esac
# -----------------------------

echo "Extracting UBIFS filesystem (XZ compression-type-3 patch applied) from $ROOTFS_UBIFS..."
# extract_xz_patch.py lives in src/ and loads ubi_reader from vendor/
# itself (see that file's docstring) -- it monkey-patches
# ubireader.ubifs.misc.decompress in-memory for the duration of this one
# extraction only, it never touches the vendored source on disk.
fakeroot python3 "$PROJECT_ROOT/src/extract_xz_patch.py" "$ROOTFS_UBIFS" extracted_fs

cd ..
mv tmp-ubi/extracted_fs rootfs

exec_count=$(find rootfs -type f -perm -u+x | wc -l)
echo "Sanity check: $exec_count executable regular files under rootfs/ (expect > 0, typically hundreds)."

# --- PHYSICAL PARTITION SIZE, READ FROM THE FIRMWARE'S OWN CONFIG ---
# TP-Link's nvrammanager binary (their proprietary OTA-decrypt/cross-check
# tool) reads rootfs/etc/partition_config/ itself to validate model/info,
# so this file's presence and format is something TP-Link's own tooling
# depends on -- a reasonable signal it's a stable convention, not
# something to assume is universal across every TP-Link/IPQ50xx model
# without checking. Reading it fresh from THIS firmware avoids betting on
# whether a different model shares the same partition layout at all.
#
# Fallback: 44,040,192 bytes (0x02a00000) -- independently confirmed via
# `cat /proc/mtd` on a live Archer AX53 (mtd11 "rootfs" / mtd12
# "rootfs_1"), AND independently confirmed present with the identical
# format (and, on AX72, the identical 0x02a00000 value) across multiple
# other TP-Link IPQ5018-family models -- reliable enough to trust as the
# primary source across this device family, not just AX53.
#
# Fallback, for firmware where this file is missing or unparseable:
# ROOTFS_BUDGET_BYTES (already captured above, from the UBI volume table
# itself -- works for ANY UBI firmware, not TP-Link-specific) is stock's
# own ubi_rootfs volume size. That's PROVEN achievable (stock itself fit
# in it), so it's a safe floor regardless of device. A small margin is
# added on top since a partition holding kernel + rootfs + UBI's own
# per-PEB overhead is essentially never sized with zero slack beyond the
# rootfs volume alone -- but this is a guess for an unverified device, so
# it's deliberately small (256KB ~= 2 LEBs at this LEB_SIZE) and
# overridable via PARTITION_SIZE_MARGIN_BYTES if you have better data for
# a specific model (e.g. from its own /proc/mtd).
PARTITION_TABLE="rootfs/etc/partition_config/partition-table"
FALLBACK_MARGIN_BYTES="${PARTITION_SIZE_MARGIN_BYTES:-262144}"
FALLBACK_PARTITION_SIZE_BYTES=$((ROOTFS_BUDGET_BYTES + FALLBACK_MARGIN_BYTES))

if [ -f "$PARTITION_TABLE" ]; then
  detected_hex=$(awk -F',' '
    { name=$1; sub(/^[0-9]+=/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", name)
      if (name == "rootfs") { size=$3; gsub(/[ \t]/, "", size); print size } }
  ' "$PARTITION_TABLE")
  if [[ "$detected_hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
    PARTITION_SIZE_BYTES=$((detected_hex))
    echo "Detected physical rootfs partition size from $PARTITION_TABLE: $PARTITION_SIZE_BYTES bytes ($detected_hex)"
  else
    PARTITION_SIZE_BYTES=$FALLBACK_PARTITION_SIZE_BYTES
    echo "Warning: couldn't parse a 'rootfs' entry from $PARTITION_TABLE -- falling back to" >&2
    echo "         stock's own ubi_rootfs size + ${FALLBACK_MARGIN_BYTES}-byte margin:" >&2
    echo "         $PARTITION_SIZE_BYTES bytes. This is conservative, not exact -- for a firmer" >&2
    echo "         number, telnet into a live device and check \`cat /proc/mtd\` for the 'rootfs'" >&2
    echo "         MTD partition (not 'ubi_rootfs', that's the smaller UBI volume inside it)," >&2
    echo "         then set PARTITION_SIZE_MARGIN_BYTES to extend this if there's more headroom." >&2
  fi
else
  PARTITION_SIZE_BYTES=$FALLBACK_PARTITION_SIZE_BYTES
  echo "Warning: $PARTITION_TABLE not found -- falling back to stock's own ubi_rootfs size" >&2
  echo "         + ${FALLBACK_MARGIN_BYTES}-byte margin: $PARTITION_SIZE_BYTES bytes. This is" >&2
  echo "         conservative, not exact -- for a firmer number, telnet into a live device and" >&2
  echo "         check \`cat /proc/mtd\` for the 'rootfs' MTD partition (not 'ubi_rootfs', that's" >&2
  echo "         the smaller UBI volume inside it), then set PARTITION_SIZE_MARGIN_BYTES to" >&2
  echo "         extend this if there's more headroom." >&2
fi
echo "PARTITION_SIZE_BYTES=$PARTITION_SIZE_BYTES" >> tmp-ubi/ubi_layout.env
# ----------------------------------------------------------------------

echo "Successfully unpacked UBIFS rootfs to rootfs."
[ -f tmp-ubi/rootfs_xz_chunks_manifest.txt ] && echo "XZ-chunk manifest: tmp-ubi/rootfs_xz_chunks_manifest.txt"
