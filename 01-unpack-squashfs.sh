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
# Same vendored copy the UBI pipeline uses. Only ubireader_extract_images
# is needed here, to pull the volume dumps back out of the UBI container --
# squashfs decompression itself is handled natively by unsquashfs.
UBIREADER_VERSION="0.8.14"
UBIREADER_SRC="${UBIREADER_SRC_OVERRIDE:-$PROJECT_ROOT/vendor/ubi_reader/src/ubi_reader-$UBIREADER_VERSION}"
if [ ! -d "$UBIREADER_SRC/ubireader" ]; then
  echo "Error: vendored ubi_reader source not found at $UBIREADER_SRC" >&2
  echo "       See vendor/ubi_reader/README.md to (re)populate it." >&2
  exit 1
fi
export PYTHONPATH="$UBIREADER_SRC${PYTHONPATH:+:$PYTHONPATH}"
# ----------------------------------------------------------------------

# mksquashfs/unsquashfs are also vendor-pinned in bin/ now, not system
# PATH tools -- using the "4" pair specifically: the squashfs-tools
# Makefile (SRC_DIR=squashfs4.2, XZ_SUPPORT=1 LZMA_XZ_SUPPORT=1) only
# builds squashfs4 with real XZ support and installs it as bin/*4;
# squashfs3 (unsuffixed bin/mksquashfs, if present) is LZMA-only and
# won't produce the SquashFS 4.0/xz format binwalk confirmed for stock.
UNSQUASHFS="$PROJECT_ROOT/bin/unsquashfs4"
if [ ! -x "$UNSQUASHFS" ]; then
  echo "Error: $UNSQUASHFS not found or not executable." >&2
  echo "       Build it first: see the project Makefile." >&2
  exit 1
fi

# Clean state: unsquashfs refuses to write into an existing squashfs-root/
# without -f, and a stale tmp-squashfs/ would silently mix old extraction results
# with the new one.
[ -d squashfs-root ] && rm -rf squashfs-root
[ -d tmp-squashfs ] && rm -rf tmp-squashfs
mkdir -p tmp-squashfs

pos=$(grep -a -b -m 1 "UBI#" "$firmware" | cut -d ":" -f 1)
if [ -z "$pos" ] || ! [[ "$pos" =~ ^[0-9]+$ ]]; then
  echo "Error: no 'UBI#' magic found in $firmware -- this file likely isn't" >&2
  echo "       the same header+raw-UBI-container format this pipeline assumes." >&2
  echo "       Run 'binwalk \"$firmware\"' to see what's actually inside." >&2
  exit 1
fi

# Stock's total UBI container size, as shipped in the firmware file --
# used only as a fallback basis for partition-size detection further
# down, if this firmware's own partition_config isn't available.
stock_total=$(stat -c%s "$firmware")
stock_ubi_size=$((stock_total - pos))
echo "$stock_ubi_size" > tmp-squashfs/stock_ubi_size.txt

dd if="$firmware" of=tmp-squashfs/header.bin bs="$pos" count=1
dd if="$firmware" of=tmp-squashfs/ubi.img bs="$pos" skip=1

cd tmp-squashfs
python3 -m ubireader.scripts.ubireader_extract_images ubi.img
cd ..

ROOTFS_UBIFS=$(find tmp-squashfs -name "*rootfs.ubifs" | head -n 1)
if [ -z "$ROOTFS_UBIFS" ]; then
  echo "Error: no *rootfs.ubifs volume dump found under tmp-squashfs/ -- check the" >&2
  echo "       ubireader_extract_images output above." >&2
  exit 1
fi

# --- FILESYSTEM TYPE SNIFF ---
# ubireader_extract_images names every per-volume dump "*.ubifs" purely
# from the UBI *volume* name ("ubi_rootfs") -- it does not inspect the
# payload. Confirm it's actually SquashFS before handing it to unsquashfs;
# fail cleanly instead of a confusing unsquashfs error on the wrong format.
magic=$(od -An -tx1 -N 4 "$ROOTFS_UBIFS" | tr -d ' \n')
case "$magic" in
  68737173)  # "hsqs" -- SquashFS, little-endian
    ;;
  31181006)  # UBIFS common-node-header magic (0x06101831, little-endian on disk)
    echo "Error: $ROOTFS_UBIFS is UBIFS, not SquashFS." >&2
    echo "       This script only handles SquashFS rootfs images -- use the" >&2
    echo "       UBI unpack script for this firmware instead." >&2
    exit 1
    ;;
  *)
    echo "Error: $ROOTFS_UBIFS doesn't start with a recognized filesystem" >&2
    echo "       magic (got: ${magic:-<empty>}). Expected SquashFS ('hsqs')." >&2
    echo "       Run: binwalk \"$PROJECT_ROOT/$ROOTFS_UBIFS\" to identify it." >&2
    exit 1
    ;;
esac
# -----------------------------

FAKEROOT_STATE="tmp-squashfs/fakeroot.state"
fakeroot -s "$FAKEROOT_STATE" -- "$UNSQUASHFS" "$ROOTFS_UBIFS"

# --- PHYSICAL PARTITION SIZE, READ FROM THE FIRMWARE'S OWN CONFIG ---
# Same mechanism as the UBI pipeline's 01-unpack-ubi.sh: read the real
# rootfs MTD partition size straight from THIS firmware's own
# etc/partition_config/partition-table rather than assuming a number.
# Confirmed reliable across multiple TP-Link IPQ50xx models (AX55, AX72),
# same file format, same column layout.
#
# Fallback if that file is missing/unparseable: stock_ubi_size (the whole
# UBI container as shipped in this firmware) plus a small margin. This is
# a real number this exact firmware proved fits, not a guess, and it's a
# noticeably tighter fallback than using just the ubi_rootfs volume's own
# PEB reservation would be -- the total shipped container is already much
# closer to the true partition ceiling.
PARTITION_TABLE="squashfs-root/etc/partition_config/partition-table"
FALLBACK_MARGIN_BYTES="${PARTITION_SIZE_MARGIN_BYTES:-262144}"
FALLBACK_PARTITION_SIZE_BYTES=$((stock_ubi_size + FALLBACK_MARGIN_BYTES))

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
    echo "         this firmware's own total UBI container size + ${FALLBACK_MARGIN_BYTES}-byte margin:" >&2
    echo "         $PARTITION_SIZE_BYTES bytes. Conservative, not exact -- for a firmer number," >&2
    echo "         telnet into a live device and check \`cat /proc/mtd\` for the 'rootfs' MTD" >&2
    echo "         partition, then set PARTITION_SIZE_MARGIN_BYTES to extend this." >&2
  fi
else
  PARTITION_SIZE_BYTES=$FALLBACK_PARTITION_SIZE_BYTES
  echo "Warning: $PARTITION_TABLE not found -- falling back to this firmware's own total" >&2
  echo "         UBI container size + ${FALLBACK_MARGIN_BYTES}-byte margin: $PARTITION_SIZE_BYTES bytes." >&2
  echo "         Conservative, not exact -- for a firmer number, telnet into a live device" >&2
  echo "         and check \`cat /proc/mtd\` for the 'rootfs' MTD partition, then set" >&2
  echo "         PARTITION_SIZE_MARGIN_BYTES to extend this if there's more headroom." >&2
fi
echo "$PARTITION_SIZE_BYTES" > tmp-squashfs/partition_size.txt
# ----------------------------------------------------------------------

echo "Successfully unpacked rootfs to squashfs-root. Modify anything you want and repack the firmware"
