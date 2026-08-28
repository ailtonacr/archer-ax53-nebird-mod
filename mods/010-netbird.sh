#!/bin/bash -e
#
# 010-netbird.sh -- integrate NetBird (0.77.1) as a native VPN Client on AX53.
#
# Installs: init service, control CLI, tiny /usr/bin/netbird wrapper, xzmini
# decoder, NetBird runtime/diagnostic LuCI backend, native TP-Link VPN controller
# adapter, patched VPN Client frontend, firewall rules, factory-reset cleanup and
# boot enable symlink.
#
# The large NetBird ELF is NOT embedded in rootfs and NOT stored on any MTD/UBI
# partition; it is downloaded over HTTPS and materialized into /tmp at runtime.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "rootfs" ]; then ROOTFS_DIR="$PROJECT_ROOT/rootfs"
  elif [ -d "squashfs-root" ]; then ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
  else echo "Error: no rootfs dir" >&2; exit 1; fi
else
  case "$ROOTFS_DIR" in
    /*) ;;
    *) ROOTFS_DIR="$PROJECT_ROOT/$ROOTFS_DIR" ;;
  esac
fi
[ -d "$ROOTFS_DIR" ] || { echo "Error: rootfs dir does not exist: $ROOTFS_DIR" >&2; exit 1; }

FILES="$SCRIPT_DIR/010-netbird-files"
R="$ROOTFS_DIR"
WEB_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_web.py"
NB_CONTROLLER="$PROJECT_ROOT/src/web-backend/controller/admin/netbird.lua"
NB_MODEL="$PROJECT_ROOT/src/web-backend/model/netbird.lua"
VPN_ADAPTER="$PROJECT_ROOT/src/web-backend/controller/admin/vpn_netbird_adapter.lua"

echo "### NetBird native VPN Client integration ###"
echo "    rootfs: $R"

echo "[1/8] copying NetBird runtime files into rootfs ..."
# The large NetBird ELF is deliberately absent here. Runtime materialization
# downloads the pinned XZ payload to /tmp; only the tiny CLI wrapper/decoder
# and integration files belong in squashfs.
(cd "$FILES" && cp -a --parents lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini \
   usr/bin/netbird etc/init.d/netbird "$R/")

# Canonical LuCI sources live under src/web-backend. Do not copy stale mirrored
# controller/model files from mods/010-netbird-files.
mkdir -p "$R/usr/lib/lua/luci/controller/admin" "$R/usr/lib/lua/luci/model"
[ -f "$NB_CONTROLLER" ] || { echo "Error: missing $NB_CONTROLLER" >&2; exit 1; }
[ -f "$NB_MODEL" ] || { echo "Error: missing $NB_MODEL" >&2; exit 1; }
cp "$NB_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird.lua"
cp "$NB_MODEL" "$R/usr/lib/lua/luci/model/netbird.lua"

chmod 0755 "$R/sbin/netbird-ctl" "$R/sbin/xzmini" "$R/usr/bin/netbird" "$R/etc/init.d/netbird" 2>/dev/null || true
chmod 0644 "$R/lib/netbird/netbird.sh" "$R/usr/lib/lua/luci/controller/admin/netbird.lua" "$R/usr/lib/lua/luci/model/netbird.lua" 2>/dev/null || true

echo "[2/8] adapting the native TP-Link VPN controller for NetBird ..."
[ -f "$VPN_ADAPTER" ] || { echo "Error: missing $VPN_ADAPTER" >&2; exit 1; }
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
VPN_STOCK="$R/usr/lib/lua/luci/controller/admin/vpn_stock.lua"
[ -f "$VPN_CONTROLLER" ] || { echo "Error: missing stock VPN controller $VPN_CONTROLLER" >&2; exit 1; }

# Preserve the original compiled TP-Link controller exactly once. On repeated
# builds vpn.lua is already our text adapter, so the immutable stock bytecode
# remains in vpn_stock.lua and must never be overwritten by the adapter.
if [ ! -f "$VPN_STOCK" ]; then
  cp -p "$VPN_CONTROLLER" "$VPN_STOCK"
  echo "    preserved stock controller as vpn_stock.lua"
else
  echo "    stock controller already preserved"
fi
cp "$VPN_ADAPTER" "$VPN_CONTROLLER"
chmod 0644 "$VPN_CONTROLLER" "$VPN_STOCK" 2>/dev/null || true

grep -q 'vpn_stock.lua' "$VPN_CONTROLLER" || { echo "Error: VPN adapter was not installed" >&2; exit 1; }

echo "[3/8] patching VPN Client frontend ..."
[ -f "$WEB_PATCHER" ] || { echo "Error: missing $WEB_PATCHER" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required for frontend patching" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Error: node is required for frontend syntax validation" >&2; exit 1; }
python3 "$WEB_PATCHER" "$R"

echo "[4/8] adding CIDR-scoped fw_netbird_access/block ..."
if ! grep -q "# NetBird v2 CIDR-scoped" "$R/lib/firewall/tpcmd.sh" 2>/dev/null; then
  cat >> "$R/lib/firewall/tpcmd.sh" <<'EOF'

# NetBird v2 CIDR-scoped -- later definition intentionally overrides v1.
fw_netbird_access(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }

    if [ "$access" == "lan" ] && [ -n "$cidr" ]; then
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i wt0 -o $homeif -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i $homeif -o wt0 -s $cidr" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    if [ -n "$cidr" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
}
EOF
else
  echo "    (CIDR-scoped override already present, skipping)"
fi

echo "[5/8] wiring netbird_access|netbird_block into /sbin/fw ..."
if ! grep -q "netbird_access" "$R/sbin/fw" 2>/dev/null; then
  sed -i 's#openvpnc_access|openvpnc_block)#openvpnc_access|openvpnc_block|netbird_access|netbird_block)#' "$R/sbin/fw"
  grep -q "netbird_access" "$R/sbin/fw" || {
    echo "    fallback: patching via explicit replace"
    perl -0pi -e 's/(vpnc_access_accel_handle\|vpnc_block_accel_handle\|openvpnc_access\|openvpnc_block)\)/$1|netbird_access|netbird_block)/' "$R/sbin/fw"
  }
else
  echo "    (already present, skipping)"
fi

echo "[6/8] factory-reset cleanup in /sbin/reset ..."
if ! grep -q "tp_data/netbird" "$R/sbin/reset" 2>/dev/null; then
  sed -i 's#^sleep 3$#rm -rf /tp_data/netbird\nsleep 3#' "$R/sbin/reset"
fi

echo "[7/8] enabling service (rc.d S99netbird) ..."
mkdir -p "$R/etc/rc.d"
ln -sfn "../init.d/netbird" "$R/etc/rc.d/S99netbird" 2>/dev/null || true

echo "[8/8] verifying installed files ..."
for f in lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini usr/bin/netbird etc/init.d/netbird \
         usr/lib/lua/luci/controller/admin/netbird.lua usr/lib/lua/luci/model/netbird.lua \
         usr/lib/lua/luci/controller/admin/vpn.lua usr/lib/lua/luci/controller/admin/vpn_stock.lua \
         www/webpages/js/VpnServerNetbirdForm-NB.js.gz; do
  [ -f "$R/$f" ] && echo "    ok  $f" || { echo "    MISSING $f" >&2; exit 1; }
done

grep -q 'NetBird adapter for TP-Link' "$R/usr/lib/lua/luci/controller/admin/vpn.lua" || {
  echo "Error: native VPN adapter validation failed" >&2; exit 1;
}
python3 - "$R/usr/lib/lua/luci/controller/admin/vpn_stock.lua" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
data = p.read_bytes()[:4]
if data != b'\x1bLua':
    raise SystemExit(f"Error: {p} is not the preserved stock Lua bytecode (header={data!r})")
PY

echo "### NetBird native VPN Client integration complete ###"
