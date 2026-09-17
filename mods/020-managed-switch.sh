#!/bin/bash -e
#
# Install the managed-switch layer. The shipped configuration is disabled by
# default; flashing this firmware does not alter the active switch table until
# the operator explicitly applies it.

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
PATCH_MENU="$PROJECT_ROOT/scripts/patch-managed-switch-menu.py"
SPA_SOURCE="$PROJECT_ROOT/src/web/ManagedSwitchPage-AX.js"

echo "### Managed switch layer ###"
echo "    rootfs: $R"

[ -f "$PATCH_MENU" ] || { echo "Error: missing SPA integration patcher: $PATCH_MENU" >&2; exit 1; }
[ -f "$SPA_SOURCE" ] || { echo "Error: missing managed-switch SPA module: $SPA_SOURCE" >&2; exit 1; }

mkdir -p \
  "$R/etc/managed-switch" \
  "$R/etc/init.d" \
  "$R/etc/hotplug.d/switch" \
  "$R/etc/rc.d" \
  "$R/usr/sbin" \
  "$R/usr/lib/lua/luci/controller/admin" \
  "$R/www/webpages/js"

cp "$FILES/etc/managed-switch/default.conf" "$R/etc/managed-switch/default.conf"
cp "$FILES/etc/init.d/managed-switch" "$R/etc/init.d/managed-switch"
cp "$FILES/etc/hotplug.d/switch/99-managed-switch" "$R/etc/hotplug.d/switch/99-managed-switch"
cp "$FILES/usr/sbin/ax53-switch" "$R/usr/sbin/ax53-switch"
cp "$FILES/usr/lib/lua/luci/controller/admin/managed_switch.lua" "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua"

chmod 0644 "$R/etc/managed-switch/default.conf"
chmod 0755 "$R/etc/init.d/managed-switch"
chmod 0755 "$R/etc/hotplug.d/switch/99-managed-switch"
chmod 0755 "$R/usr/sbin/ax53-switch"
chmod 0644 "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua"

ln -sfn "../init.d/managed-switch" "$R/etc/rc.d/S99managed-switch"

# Follow the proven native frontend pattern: authored module inside TP-Link's
# SPA imports the already-initialized update-store client, while the backend
# uses luci.model.controller._index(dispatch) for stock encrypted transport.
python3 "$PATCH_MENU" "$R"

grep -Fxq 'enabled=0' "$R/etc/managed-switch/default.conf" || {
  echo "Error: managed switch must be disabled by default" >&2
  exit 1
}
grep -Fxq 'wan_vid=4094' "$R/etc/managed-switch/default.conf" || exit 1
grep -Fxq 'lan_vid=2' "$R/etc/managed-switch/default.conf" || exit 1

grep -Fq 'entry({"admin", "managed_switch"}, call("_index")' "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua" || {
  echo "Error: stock managed-switch LuCI route missing" >&2
  exit 1
}
grep -Fq 'controller._index(dispatch)' "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua" || {
  echo "Error: managed-switch backend must use TP-Link stock controller transport" >&2
  exit 1
}
[ -f "$R/www/webpages/js/ManagedSwitchPage-AX.js.gz" ] || {
  echo "Error: managed-switch SPA module not installed" >&2
  exit 1
}
if [ -e "$R/www/webpages/managed-switch.html" ]; then
  echo "Error: legacy standalone managed-switch page must not be packaged" >&2
  exit 1
fi
python3 "$PATCH_MENU" "$R" >/dev/null

echo "### Managed switch installed (disabled by default, stock SPA/API integration) ###"
