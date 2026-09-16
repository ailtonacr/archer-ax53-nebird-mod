#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
MODS_DIR="$PROJECT_ROOT/mods"
APPLY_PATCHES="$PROJECT_ROOT/vendor/apply_patches.sh"
cd "$PROJECT_ROOT"

if [ -n "${ROOTFS_DIR:-}" ]; then
  case "$ROOTFS_DIR" in /*) ;; *) ROOTFS_DIR="$PROJECT_ROOT/$ROOTFS_DIR" ;; esac
elif [ -d rootfs ]; then
  ROOTFS_DIR="$PROJECT_ROOT/rootfs"
elif [ -d squashfs-root ]; then
  ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
else
  echo "Error: no rootfs found; unpack firmware first or set ROOTFS_DIR" >&2
  exit 1
fi
[ -d "$ROOTFS_DIR" ] || { echo "Error: ROOTFS_DIR not found: $ROOTFS_DIR" >&2; exit 1; }
export ROOTFS_DIR PROJECT_ROOT

SCRIPT_RE='^[0-9]{3}-.+\.sh$'
PATCH_RE='^[0-9]{3}(-.*)?\.patch$'
valid_scripts=()
valid_patches=()
shopt -s nullglob
for f in "$MODS_DIR"/*; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  case "$name" in
    *.sh) [[ "$name" =~ $SCRIPT_RE ]] && valid_scripts+=("$f") || echo "WARNING: skipping $name" >&2 ;;
    *.patch) [[ "$name" =~ $PATCH_RE ]] && valid_patches+=("$f") || echo "WARNING: skipping $name" >&2 ;;
  esac
done
shopt -u nullglob

if [ ${#valid_patches[@]} -gt 0 ]; then
  [ -x "$APPLY_PATCHES" ] || { echo "Error: patch helper unavailable" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  for p in "${valid_patches[@]}"; do ln -s "$p" "$tmp/$(basename "$p")"; done
  "$APPLY_PATCHES" "$ROOTFS_DIR" "$tmp"
fi
if [ ${#valid_scripts[@]} -gt 0 ]; then
  mapfile -t sorted < <(printf '%s\n' "${valid_scripts[@]}" | sort -V)
  for s in "${sorted[@]}"; do echo "--- $(basename "$s") ---"; bash -e "$s"; done
fi

echo "=== All mods applied to $ROOTFS_DIR ==="
