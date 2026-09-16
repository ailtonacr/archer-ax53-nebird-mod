#!/bin/bash
set -euo pipefail
#
# apply-mods.sh -- discovers and applies everything in mods/ against the
# selected unpacked rootfs tree, in order.
#
# ROOTFS_DIR may be supplied explicitly by the caller. The UBIFS firmware
# pipeline uses rootfs/. Auto-detection remains useful for standalone work.
#
# Naming convention:
#   NNN-description.sh         run via bash -e, sort -V order
#   NNN[-description].patch    applied as one patch batch
#
# Files outside those patterns are deliberately skipped with a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

MODS_DIR="$PROJECT_ROOT/mods"
APPLY_PATCHES="$PROJECT_ROOT/vendor/apply_patches.sh"

if [ -n "${ROOTFS_DIR:-}" ]; then
  case "$ROOTFS_DIR" in
    /*) ;;
    *) ROOTFS_DIR="$PROJECT_ROOT/$ROOTFS_DIR" ;;
  esac
  [ -d "$ROOTFS_DIR" ] || {
    echo "Error: explicit ROOTFS_DIR does not exist: $ROOTFS_DIR" >&2
    exit 1
  }
elif [ -d "rootfs" ]; then
  ROOTFS_DIR="$PROJECT_ROOT/rootfs"
elif [ -d "squashfs-root" ]; then
  ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
else
  echo "Error: neither rootfs nor squashfs-root exists." >&2
  exit 1
fi
export ROOTFS_DIR PROJECT_ROOT

echo "=== Mod target rootfs: $ROOTFS_DIR ==="

[ -d "$MODS_DIR" ] || { echo "Error: $MODS_DIR not found." >&2; exit 1; }
[ -x "$APPLY_PATCHES" ] || { echo "Error: $APPLY_PATCHES missing/not executable." >&2; exit 1; }

SCRIPT_RE='^[0-9]{3}-.+\.sh$'
PATCH_RE='^[0-9]{3}(-.*)?\.patch$'
valid_scripts=()
valid_patches=()

shopt -s nullglob
for f in "$MODS_DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  case "$name" in
    *.sh)
      if [[ "$name" =~ $SCRIPT_RE ]]; then
        valid_scripts+=("$f")
      else
        echo "WARNING: skipping $name -- invalid mod script name" >&2
      fi
      ;;
    *.patch)
      if [[ "$name" =~ $PATCH_RE ]]; then
        valid_patches+=("$f")
      else
        echo "WARNING: skipping $name -- invalid patch name" >&2
      fi
      ;;
    *)
      echo "WARNING: skipping $name -- unsupported mod file" >&2
      ;;
  esac
done
shopt -u nullglob

if [ ${#valid_scripts[@]} -eq 0 ] && [ ${#valid_patches[@]} -eq 0 ]; then
  echo "No valid mods found."
  exit 0
fi

if [ ${#valid_patches[@]} -gt 0 ]; then
  echo "=== Applying ${#valid_patches[@]} patch(es) ==="
  TMP_PATCH_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_PATCH_DIR"' EXIT
  for p in "${valid_patches[@]}"; do
    ln -s "$p" "$TMP_PATCH_DIR/$(basename "$p")"
  done
  "$APPLY_PATCHES" "$ROOTFS_DIR" "$TMP_PATCH_DIR"
fi

if [ ${#valid_scripts[@]} -gt 0 ]; then
  mapfile -t sorted_scripts < <(printf '%s\n' "${valid_scripts[@]}" | sort -V)
  echo "=== Running ${#sorted_scripts[@]} mod script(s) ==="
  for s in "${sorted_scripts[@]}"; do
    echo "--- $(basename "$s") ---"
    bash -e "$s"
  done
fi

echo "=== All mods applied to $ROOTFS_DIR ==="
