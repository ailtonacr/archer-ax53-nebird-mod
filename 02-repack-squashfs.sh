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

UBINIZE="$PROJECT_ROOT/bin/ubinize"
MD5FIX="$PROJECT_ROOT/bin/md5-fix"
MKSQUASHFS="$PROJECT_ROOT/bin/mksquashfs4"

# mksquashfs/ubinize are both vendor-pinned bin/ builds now. mksquashfs4
# specifically: the squashfs-tools Makefile (SRC_DIR=squashfs4.2,
# XZ_SUPPORT=1 LZMA_XZ_SUPPORT=1) is the one with real XZ support,
# matching stock's confirmed SquashFS 4.0/xz format -- the unsuffixed
# squashfs3 build is LZMA-only.
for bin_path in "$UBINIZE" "$MD5FIX" "$MKSQUASHFS"; do
  if [ ! -x "$bin_path" ]; then
    echo "Error: $bin_path not found or not executable." >&2
    echo "       Build it first: see vendor/mtd-utils/ and the project Makefile." >&2
    exit 1
  fi
done

FAKEROOT_STATE="tmp-squashfs/fakeroot.state"
if [ ! -f "$FAKEROOT_STATE" ]; then
  echo "Error: $FAKEROOT_STATE not found -- run 01-unpack-squashfs.sh first" >&2
  echo "       (it records which files in squashfs-root/ are real device nodes," >&2
  echo "       since a non-root unsquashfs can't create actual ones on disk)." >&2
  exit 1
fi

if [ ! -f "tmp-squashfs/partition_size.txt" ]; then
  echo "Error: tmp-squashfs/partition_size.txt not found -- run 01-unpack-squashfs.sh first" >&2
  echo "       to capture the real physical partition size for this firmware." >&2
  exit 1
fi
PARTITION_SIZE_BYTES=$(cat tmp-squashfs/partition_size.txt)

fakeroot -i "$FAKEROOT_STATE" -- "$MKSQUASHFS" squashfs-root/ tmp-squashfs/rootfs.bin -comp xz -b 256K -noappend

kernel=$(find tmp-squashfs -name "*kernel.ubifs" | head -n 1)
if [ -z "$kernel" ]; then
  echo "Error: kernel.ubifs not found under tmp-squashfs/ -- run 01-unpack.sh first." >&2
  exit 1
fi
[[ -f tmp-squashfs/kernel.itb ]] && rm -f tmp-squashfs/kernel.itb
cp -f "$kernel" tmp-squashfs/kernel.itb
"$UBINIZE" -m 2048 -p 128KiB -o tmp-squashfs/ubi-new.img etc/ubinize-ipq50xx.cfg

# --- PHYSICAL PARTITION CEILING ---
header_size=$(stat -c%s tmp-squashfs/header.bin)
ubi_size=$(stat -c%s tmp-squashfs/ubi-new.img)
final_size=$((header_size + ubi_size))
echo "Built UBI container: $ubi_size bytes (+ $header_size byte header = $final_size bytes total)"
if [ "$final_size" -gt "$PARTITION_SIZE_BYTES" ]; then
  echo "ERROR: final image ($final_size bytes) exceeds the actual mtd partition" >&2
  echo "       size ($PARTITION_SIZE_BYTES bytes). This WOULD overflow the partition" >&2
  echo "       on flash -- do not proceed. Trim squashfs-root/ before retrying." >&2
  exit 1
fi
echo "OK — $final_size / $PARTITION_SIZE_BYTES bytes used ($(( PARTITION_SIZE_BYTES - final_size )) bytes headroom)"
# ----------------------------------------------------------------------

cat tmp-squashfs/header.bin tmp-squashfs/ubi-new.img > "$firmware"
printf '\x50\x72' | dd of="$firmware" bs=1 seek=28 count=2 conv=notrunc
"$MD5FIX" "$firmware"
