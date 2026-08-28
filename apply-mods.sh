#!/bin/bash -e
#
# apply-mods.sh -- discovers and applies everything in mods/ against the
# selected unpacked rootfs tree, in order.
#
# ROOTFS_DIR may be supplied explicitly by the caller. This is important for
# the UBIFS firmware pipeline, whose canonical output is rootfs/. Falling back
# to directory auto-detection remains useful for older standalone workflows.
#
# Naming convention inside mods/:
#   NNN-description.sh        -- run directly via `bash`, in sort -V order
#   NNN.patch / NNN-desc.patch -- applied via vendor/apply_patches.sh
#                                  against the selected rootfs, as a single batch
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
  # The current AX53 UBIFS pipeline always unpacks to rootfs/. Prefer it over a
  # stale squashfs-root/ left by unrelated/legacy experiments.
  ROOTFS_DIR="$PROJECT_ROOT/rootfs"
elif [ -d "squashfs-root" ]; then
  ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
else
  echo "Error: neither 'rootfs' nor 'squashfs-root' directory found!" >&2
  echo "       Run an unpack script first or set ROOTFS_DIR explicitly." >&2
  exit 1
fi
export ROOTFS_DIR
export PROJECT_ROOT

echo "=== Mod target rootfs: $ROOTFS_DIR ==="

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
  "$APPLY_PATCHES" "$ROOTFS_DIR" "$TMP_PATCH_DIR"
fi

if [ ${#valid_scripts[@]} -gt 0 ]; then
  mapfile -t sorted_scripts < <(printf '%s\n' "${valid_scripts[@]}" | sort -V)
  echo "=== Running ${#sorted_scripts[@]} mod script(s) ==="
  for s in "${sorted_scripts[@]}"; do
    echo "--- $(basename "$s") ---"
    bash "$s"
  done
fi

echo "=== All mods applied to $ROOTFS_DIR ==="
