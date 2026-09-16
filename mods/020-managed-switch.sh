#!/bin/bash -e
#
# Install the managed-switch layer. The shipped configuration is disabled by
# default; flashing this firmware does not alter the active switch table until
# the operator explicitly enables/applies it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "$PROJECT_ROOT/rootfs" ]; then ROOTFS_DIR="$PROJECT_ROOT/rootfs"
  elif [ -d "$PROJECT_ROOT/squashfs-root" ]; then ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
  else echo "Error: no rootfs dir" >&2; exit 1; fi
else
  case "$ROOTFS_DIR" in
    /*) ;;
    *) ROOTFS_DIR="$PROJECT_ROOT/$ROOTFS_DIR" ;;
  esac
fi

FILES="$SCRIPT_DIR/020-managed-switch-files"
R="$ROOTFS_DIR"

echo "### Managed switch layer ###"
echo "    rootfs: $R"

mkdir -p   "$R/etc/managed-switch"   "$R/etc/init.d"   "$R/etc/hotplug.d/switch"   "$R/etc/rc.d"   "$R/usr/sbin"

cp "$FILES/etc/managed-switch/default.conf" "$R/etc/managed-switch/default.conf"
cp "$FILES/etc/init.d/managed-switch" "$R/etc/init.d/managed-switch"
cp "$FILES/etc/hotplug.d/switch/99-managed-switch" "$R/etc/hotplug.d/switch/99-managed-switch"
cp "$FILES/usr/sbin/ax53-switch" "$R/usr/sbin/ax53-switch"

chmod 0644 "$R/etc/managed-switch/default.conf"
chmod 0755 "$R/etc/init.d/managed-switch"
chmod 0755 "$R/etc/hotplug.d/switch/99-managed-switch"
chmod 0755 "$R/usr/sbin/ax53-switch"

ln -sfn "../init.d/managed-switch" "$R/etc/rc.d/S99managed-switch"

grep -Fxq 'enabled=0' "$R/etc/managed-switch/default.conf" || {
  echo "Error: managed switch must be disabled by default" >&2
  exit 1
}
grep -Fxq 'wan_vid=4094' "$R/etc/managed-switch/default.conf" || exit 1
grep -Fxq 'lan_vid=2' "$R/etc/managed-switch/default.conf" || exit 1

echo "### Managed switch installed (disabled by default) ###"
