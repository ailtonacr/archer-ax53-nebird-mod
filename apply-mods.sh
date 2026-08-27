#!/bin/bash -e
#
# apply-mods.sh -- discovers and applies everything in mods/ against the
# unpacked rootfs tree (squashfs-root/ preferred, rootfs/ as fallback), in
# order.
#
# Naming convention inside mods/:
#   NNN-description.sh        -- run directly via `bash`, in sort -V order
#   NNN.patch / NNN-desc.patch -- applied via vendor/apply_patches.sh
#                                  against squashfs-root/, as a single batch
#
# Exactly 3 leading digits required. Anything that doesn't match this
# (wrong digit count, missing digits, or a prefix like a 'd' -- e.g.
# renaming 001-telnet.sh to d001-telnet.sh) is WARNED ABOUT AND SKIPPED,
# not applied and not treated as an error. That's the deliberate mechanism
# for disabling a specific mod/patch without deleting it.
#
# Patches are applied first (as one apply_patches.sh call), then scripts
# run in order -- not interleaved by number across the two types.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

MODS_DIR="$PROJECT_ROOT/mods"
APPLY_PATCHES="$PROJECT_ROOT/vendor/apply_patches.sh"

if [ -d "squashfs-root" ]; then
  ROOTFS_DIR="squashfs-root"
elif [ -d "rootfs" ]; then
  ROOTFS_DIR="rootfs"
else
  echo "Error: neither 'squashfs-root' nor 'rootfs' directory found!" >&2
  echo "       Run an unpack script first." >&2
  exit 1
fi
export ROOTFS_DIR
export PROJECT_ROOT

if [ ! -d "$MODS_DIR" ]; then
  echo "Error: $MODS_DIR not found." >&2
  exit 1
fi

if [ ! -x "$APPLY_PATCHES" ]; then
  echo "Error: $APPLY_PATCHES not found or not executable." >&2
  exit 1
fi

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
        echo "WARNING: skipping $name -- doesn't match NNN-description.sh (disabled or misnamed?)" >&2
      fi
      ;;
    *.patch)
      if [[ "$name" =~ $PATCH_RE ]]; then
        valid_patches+=("$f")
      else
        echo "WARNING: skipping $name -- doesn't match NNN[-description].patch (disabled or misnamed?)" >&2
      fi
      ;;
    *)
      echo "WARNING: skipping $name -- not a .sh or .patch file" >&2
      ;;
  esac
done
shopt -u nullglob

if [ ${#valid_scripts[@]} -eq 0 ] && [ ${#valid_patches[@]} -eq 0 ]; then
  echo "No valid mods found in $MODS_DIR -- nothing to do."
  exit 0
fi

if [ ${#valid_patches[@]} -gt 0 ]; then
  echo "=== Applying ${#valid_patches[@]} patch(es) ==="
  TMP_PATCH_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_PATCH_DIR"' EXIT
  for p in "${valid_patches[@]}"; do
    ln -s "$p" "$TMP_PATCH_DIR/$(basename "$p")"
  done
  "$APPLY_PATCHES" "$PROJECT_ROOT/$ROOTFS_DIR" "$TMP_PATCH_DIR"
fi

if [ ${#valid_scripts[@]} -gt 0 ]; then
  mapfile -t sorted_scripts < <(printf '%s\n' "${valid_scripts[@]}" | sort -V)
  echo "=== Running ${#sorted_scripts[@]} mod script(s) ==="
  for s in "${sorted_scripts[@]}"; do
    echo "--- $(basename "$s") ---"
    bash "$s"
  done
fi

echo "=== All mods applied ==="
