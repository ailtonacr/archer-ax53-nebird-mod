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
PATCH_MENU="$PROJECT_ROOT/scripts/patch-managed-switch-menu.py"

echo "### Managed switch layer ###"
echo "    rootfs: $R"

[ -f "$PATCH_MENU" ] || { echo "Error: missing SPA menu patcher: $PATCH_MENU" >&2; exit 1; }

mkdir -p \
  "$R/etc/managed-switch" \
  "$R/etc/init.d" \
  "$R/etc/hotplug.d/switch" \
  "$R/etc/rc.d" \
  "$R/usr/sbin" \
  "$R/usr/lib/lua/luci/controller/admin" \
  "$R/usr/lib/lua/luci/view" \
  "$R/www/webpages"

cp "$FILES/etc/managed-switch/default.conf" "$R/etc/managed-switch/default.conf"
cp "$FILES/etc/init.d/managed-switch" "$R/etc/init.d/managed-switch"
cp "$FILES/etc/hotplug.d/switch/99-managed-switch" "$R/etc/hotplug.d/switch/99-managed-switch"
cp "$FILES/usr/sbin/ax53-switch" "$R/usr/sbin/ax53-switch"
cp "$FILES/usr/lib/lua/luci/controller/admin/managed_switch.lua" "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua"
cp "$FILES/usr/lib/lua/luci/view/managed-switch.html" "$R/usr/lib/lua/luci/view/managed-switch.html"
cp "$FILES/www/webpages/managed-switch.html" "$R/www/webpages/managed-switch.html"

chmod 0644 "$R/etc/managed-switch/default.conf"
chmod 0755 "$R/etc/init.d/managed-switch"
chmod 0755 "$R/etc/hotplug.d/switch/99-managed-switch"
chmod 0755 "$R/usr/sbin/ax53-switch"
chmod 0644 "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua"
chmod 0644 "$R/usr/lib/lua/luci/view/managed-switch.html"
chmod 0644 "$R/www/webpages/managed-switch.html"

ln -sfn "../init.d/managed-switch" "$R/etc/rc.d/S99managed-switch"

# The visible TP-Link UI is a Vue SPA rooted at /webpages/index.html#/.
# LuCI entry() does not automatically add a SPA menu item, so patch only the
# common frontend bundle with an idempotent launcher nested under Rede/Network.
python3 "$PATCH_MENU" "$R"

grep -Fxq 'enabled=0' "$R/etc/managed-switch/default.conf" || {
  echo "Error: managed switch must be disabled by default" >&2
  exit 1
}
grep -Fxq 'wan_vid=4094' "$R/etc/managed-switch/default.conf" || exit 1
grep -Fxq 'lan_vid=2' "$R/etc/managed-switch/default.conf" || exit 1
grep -Fq 'entry({"admin", "managed_switch"}' "$R/usr/lib/lua/luci/controller/admin/managed_switch.lua" || {
  echo "Error: managed switch LuCI route missing" >&2
  exit 1
}
grep -Fq 'const ENDPOINT="/cgi-bin/luci/;stok=/admin/managed_switch"' "$R/www/webpages/managed-switch.html" || {
  echo "Error: managed switch SPA page direct LuCI endpoint missing" >&2
  exit 1
}
if grep -Fq 'update-store-DQkZxaRI.js' "$R/www/webpages/managed-switch.html"; then
  echo "Error: standalone managed-switch page must not import TP-Link update-store" >&2
  exit 1
fi
grep -Fq 'Switch / VLAN' "$R/www/webpages/managed-switch.html" || {
  echo "Error: managed switch SPA page missing" >&2
  exit 1
}
python3 "$PATCH_MENU" "$R" >/dev/null

echo "### Managed switch installed (disabled by default, Rede/Network menu + UI included) ###"
