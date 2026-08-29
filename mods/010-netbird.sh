#!/bin/bash -e
#
# 010-netbird.sh -- integrate NetBird (0.77.1) in the stock VPN Client UI.
#
# NetBird is visually integrated with TP-Link's VPN Client page, but profile
# CRUD/control uses /admin/netbird. Hardware validation proved the compiled
# TP-Link /admin/vpn dispatcher does not call replacement Lua handlers, so the
# vendor VPN controller is deliberately kept byte-for-byte stock.
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
RUNTIME_SRC="$PROJECT_ROOT/src/init"
R="$ROOTFS_DIR"
WEB_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_web.py"
FACTORY_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_factory_semantics.py"
FORM_STATE_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_form_state.py"
NATIVE_SAVE_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_native_save.py"
NB_CONTROLLER="$PROJECT_ROOT/src/web-backend/controller/admin/netbird.lua"
NB_MODEL="$PROJECT_ROOT/src/web-backend/model/netbird.lua"

echo "### NetBird VPN Client integration ###"
echo "    rootfs: $R"

echo "[1/8] copying NetBird runtime files into rootfs ..."
for f in netbird.sh netbird-ctl netbird.init; do
  [ -f "$RUNTIME_SRC/$f" ] || { echo "Error: missing canonical runtime source $RUNTIME_SRC/$f" >&2; exit 1; }
done
mkdir -p "$R/lib/netbird" "$R/sbin" "$R/etc/init.d"
cp "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh"
cp "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl"
cp "$RUNTIME_SRC/netbird.init" "$R/etc/init.d/netbird"
(cd "$FILES" && cp -a --parents sbin/xzmini usr/bin/netbird "$R/")

mkdir -p "$R/usr/lib/lua/luci/controller/admin" "$R/usr/lib/lua/luci/model"
[ -f "$NB_CONTROLLER" ] || { echo "Error: missing $NB_CONTROLLER" >&2; exit 1; }
[ -f "$NB_MODEL" ] || { echo "Error: missing $NB_MODEL" >&2; exit 1; }
cp "$NB_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird.lua"
cp "$NB_MODEL" "$R/usr/lib/lua/luci/model/netbird.lua"

chmod 0755 "$R/sbin/netbird-ctl" "$R/sbin/xzmini" "$R/usr/bin/netbird" "$R/etc/init.d/netbird" 2>/dev/null || true
chmod 0644 "$R/lib/netbird/netbird.sh" "$R/usr/lib/lua/luci/controller/admin/netbird.lua" "$R/usr/lib/lua/luci/model/netbird.lua" 2>/dev/null || true

cmp -s "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh" || { echo "Error: packaged netbird.sh differs from canonical source" >&2; exit 1; }
cmp -s "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl" || { echo "Error: packaged netbird-ctl differs from canonical source" >&2; exit 1; }
cmp -s "$RUNTIME_SRC/netbird.init" "$R/etc/init.d/netbird" || { echo "Error: packaged netbird init differs from canonical source" >&2; exit 1; }

echo "[2/8] restoring/verifying untouched TP-Link VPN controller ..."
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
VPN_STOCK="$R/usr/lib/lua/luci/netbird/vpn_stock.lua"
LEGACY_VPN_STOCK="$R/usr/lib/lua/luci/controller/admin/vpn_stock.lua"
[ -f "$VPN_CONTROLLER" ] || { echo "Error: missing VPN controller $VPN_CONTROLLER" >&2; exit 1; }

is_stock_vpn() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
raise SystemExit(0 if p.is_file() and p.read_bytes()[:4] == b'\x1bLua' else 1)
PY
}

if is_stock_vpn "$VPN_CONTROLLER"; then
  echo "    stock VPN controller already present"
elif [ -f "$VPN_STOCK" ] && is_stock_vpn "$VPN_STOCK"; then
  cp -p "$VPN_STOCK" "$VPN_CONTROLLER"
  echo "    restored stock VPN controller from previous adapter backup"
elif [ -f "$LEGACY_VPN_STOCK" ] && is_stock_vpn "$LEGACY_VPN_STOCK"; then
  cp -p "$LEGACY_VPN_STOCK" "$VPN_CONTROLLER"
  echo "    restored stock VPN controller from legacy backup"
else
  echo "Error: vpn.lua is not stock bytecode and no valid stock backup exists" >&2
  exit 1
fi

rm -f "$VPN_STOCK" "$LEGACY_VPN_STOCK"

if command -v luac >/dev/null 2>&1; then
  luac -p "$NB_CONTROLLER" "$NB_MODEL"
fi
is_stock_vpn "$VPN_CONTROLLER" || { echo "Error: TP-Link VPN controller restoration failed" >&2; exit 1; }

echo "[3/8] patching VPN Client frontend ..."
[ -f "$WEB_PATCHER" ] || { echo "Error: missing $WEB_PATCHER" >&2; exit 1; }
[ -f "$FACTORY_PATCHER" ] || { echo "Error: missing $FACTORY_PATCHER" >&2; exit 1; }
[ -f "$FORM_STATE_PATCHER" ] || { echo "Error: missing $FORM_STATE_PATCHER" >&2; exit 1; }
[ -f "$NATIVE_SAVE_PATCHER" ] || { echo "Error: missing $NATIVE_SAVE_PATCHER" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required for frontend patching" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Error: node is required for frontend syntax validation" >&2; exit 1; }
python3 "$WEB_PATCHER" "$R"
python3 "$FACTORY_PATCHER" "$R"
python3 "$FORM_STATE_PATCHER" "$R"
python3 "$NATIVE_SAVE_PATCHER" "$R"

echo "[4/8] adding CIDR-scoped fw_netbird_access/block ..."
if ! grep -q "# NetBird v2 CIDR-scoped" "$R/lib/firewall/tpcmd.sh" 2>/dev/null; then
  cat >> "$R/lib/firewall/tpcmd.sh" <<'FIREWALL_EOF'

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
FIREWALL_EOF
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
         usr/lib/lua/luci/controller/admin/vpn.lua www/webpages/js/VpnServerNetbirdForm-NB.js.gz; do
  [ -f "$R/$f" ] && echo "    ok  $f" || { echo "    MISSING $f" >&2; exit 1; }
done

[ ! -e "$VPN_STOCK" ] || { echo "Error: retired vpn_stock.lua backup remains in image" >&2; exit 1; }
[ ! -e "$LEGACY_VPN_STOCK" ] || { echo "Error: legacy vpn_stock.lua remains in controller tree" >&2; exit 1; }
is_stock_vpn "$VPN_CONTROLLER" || { echo "Error: /admin/vpn controller is not original TP-Link bytecode" >&2; exit 1; }
grep -q 'profile_delete' "$R/usr/lib/lua/luci/controller/admin/netbird.lua" || {
  echo "Error: dedicated NetBird profile CRUD controller incomplete" >&2; exit 1;
}
grep -q 'description' "$R/usr/lib/lua/luci/model/netbird.lua" || {
  echo "Error: NetBird profile description persistence missing" >&2; exit 1;
}
NB_FORM_JS="$(zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz")"
printf '%s' "$NB_FORM_JS" | grep -Fq 'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })' || {
  echo "Error: NetBird subform does not expose TP-Link native isChanged contract" >&2; exit 1;
}
printf '%s' "$NB_FORM_JS" | grep -Fq 'throw new Error(error.value)' || {
  echo "Error: NetBird validate() does not reject invalid state like stock forms" >&2; exit 1;
}
for legacy in 'syncNativeSaveButton' 'data-netbird-dirty' '__netbirdSaveListener' 'stopImmediatePropagation' 'netbirdSaveSyncTimer'; do
  if printf '%s' "$NB_FORM_JS" | grep -Fq "$legacy"; then
    echo "Error: legacy NetBird Save interception leaked into final form: $legacy" >&2
    exit 1
  fi
done

echo "### NetBird VPN Client integration complete ###"
