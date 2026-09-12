#!/bin/bash -e
#
# 010-netbird.sh -- install the NetBird runtime and frontend prerequisites.
#
# This is the bootstrap stage consumed by 012-netbird-native-vpn.sh. The final
# image uses NetBird as native type=netbirdvpn/proto=netbird through the stock
# /admin/vpn endpoint; the dedicated /admin/netbird endpoint remains diagnostics
# only. Setup-key staging crosses stock Save as an opaque token; enrollment is consumed later by native netifd.
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
NATIVE_CONTRACT="$PROJECT_ROOT/src/web/patchnetbird_native_contract.py"
NB_CONTROLLER="$PROJECT_ROOT/src/web-backend/controller/admin/netbird.lua"
NB_MODEL="$PROJECT_ROOT/src/web-backend/model/netbird.lua"
FIREWALL_SRC="$RUNTIME_SRC/netbird_firewall.inc"

echo "### NetBird VPN Client integration ###"
echo "    rootfs: $R"

echo "[1/7] copying NetBird runtime files into rootfs ..."
for f in netbird.sh netbird-profiles.sh netbird-ctl netbird-proto.sh netbird_firewall.inc; do
  [ -f "$RUNTIME_SRC/$f" ] || { echo "Error: missing canonical runtime source $RUNTIME_SRC/$f" >&2; exit 1; }
done
mkdir -p "$R/lib/netbird" "$R/lib/netifd/proto" "$R/sbin" "$R/etc/init.d"
cp "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh"
cp "$RUNTIME_SRC/netbird-profiles.sh" "$R/lib/netbird/netbird-profiles.sh"
cp "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl"
cp "$RUNTIME_SRC/netbird-proto.sh" "$R/lib/netifd/proto/netbird.sh"
(cd "$FILES" && cp -a --parents sbin/xzmini usr/bin/netbird "$R/")

mkdir -p "$R/usr/lib/lua/luci/controller/admin" "$R/usr/lib/lua/luci/model"
[ -f "$NB_CONTROLLER" ] || { echo "Error: missing $NB_CONTROLLER" >&2; exit 1; }
[ -f "$NB_MODEL" ] || { echo "Error: missing $NB_MODEL" >&2; exit 1; }
cp "$NB_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird.lua"
cp "$NB_MODEL" "$R/usr/lib/lua/luci/model/netbird.lua"

chmod 0755 "$R/sbin/netbird-ctl" "$R/sbin/xzmini" "$R/usr/bin/netbird" "$R/lib/netifd/proto/netbird.sh" 2>/dev/null || true
chmod 0644 "$R/lib/netbird/netbird.sh" "$R/lib/netbird/netbird-profiles.sh" "$R/usr/lib/lua/luci/controller/admin/netbird.lua" "$R/usr/lib/lua/luci/model/netbird.lua" 2>/dev/null || true

cmp -s "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh" || { echo "Error: packaged netbird.sh differs from canonical source" >&2; exit 1; }
cmp -s "$RUNTIME_SRC/netbird-profiles.sh" "$R/lib/netbird/netbird-profiles.sh" || { echo "Error: packaged netbird-profiles.sh differs from canonical source" >&2; exit 1; }
cmp -s "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl" || { echo "Error: packaged netbird-ctl differs from canonical source" >&2; exit 1; }
cmp -s "$RUNTIME_SRC/netbird-proto.sh" "$R/lib/netifd/proto/netbird.sh" || { echo "Error: packaged netbird protocol differs from canonical source" >&2; exit 1; }

echo "[2/7] verifying untouched TP-Link VPN controller ..."
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
[ -f "$VPN_CONTROLLER" ] || { echo "Error: missing VPN controller $VPN_CONTROLLER" >&2; exit 1; }

is_stock_vpn() {
  python3 - "$1" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
raise SystemExit(0 if p.is_file() and p.read_bytes()[:4] == b'\x1bLua' else 1)
PY
}

is_stock_vpn "$VPN_CONTROLLER" || {
  echo "Error: vpn.lua is not original TP-Link bytecode; rebuild from the clean stock firmware" >&2
  exit 1
}

if command -v luac >/dev/null 2>&1; then
  luac -p "$NB_CONTROLLER" "$NB_MODEL"
fi

echo "[3/7] patching VPN Client frontend ..."
[ -f "$WEB_PATCHER" ] || { echo "Error: missing $WEB_PATCHER" >&2; exit 1; }
[ -f "$FACTORY_PATCHER" ] || { echo "Error: missing $FACTORY_PATCHER" >&2; exit 1; }
[ -f "$FORM_STATE_PATCHER" ] || { echo "Error: missing $FORM_STATE_PATCHER" >&2; exit 1; }
[ -f "$NATIVE_CONTRACT" ] || { echo "Error: missing $NATIVE_CONTRACT" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required for frontend patching" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Error: node is required for frontend syntax validation" >&2; exit 1; }
python3 "$WEB_PATCHER" "$R"
python3 "$FACTORY_PATCHER" "$R"
python3 "$FORM_STATE_PATCHER" "$R"
python3 "$NATIVE_CONTRACT" "$R"

echo "[4/7] adding canonical CIDR-scoped NetBird firewall integration ..."
if ! grep -q "# NetBird v4 CIDR-scoped/applied-state" "$R/lib/firewall/tpcmd.sh" 2>/dev/null; then
  cat >> "$R/lib/firewall/tpcmd.sh" <<'FIREWALL_SEPARATOR'

# NetBird canonical firewall definition follows.
FIREWALL_SEPARATOR
  cat "$FIREWALL_SRC" >> "$R/lib/firewall/tpcmd.sh"
  printf '\n' >> "$R/lib/firewall/tpcmd.sh"
else
  echo "    (canonical NetBird firewall definition already present, skipping)"
fi

echo "[5/7] wiring netbird_access|netbird_block into /sbin/fw ..."
if ! grep -q "netbird_access" "$R/sbin/fw" 2>/dev/null; then
  sed -i 's#openvpnc_access|openvpnc_block)#openvpnc_access|openvpnc_block|netbird_access|netbird_block)#' "$R/sbin/fw"
  grep -q "netbird_access" "$R/sbin/fw" || {
    echo "    fallback: patching via explicit replace"
    perl -0pi -e 's/(vpnc_access_accel_handle\|vpnc_block_accel_handle\|openvpnc_access\|openvpnc_block)\)/$1|netbird_access|netbird_block)/' "$R/sbin/fw"
  }
else
  echo "    (already present, skipping)"
fi

echo "[5b/7] isolating NetBird from TP-Link legacy VPN route/DNS hotplug ..."
VPN_HOTPLUG="$R/etc/hotplug.d/iface/90-vpn"
[ -f "$VPN_HOTPLUG" ] || { echo "Error: missing stock VPN hotplug $VPN_HOTPLUG" >&2; exit 1; }
python3 - "$VPN_HOTPLUG" <<'PY'
import pathlib, sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
guard = "# NetBird owns its own route table and DNS behavior."
if guard not in text:
    start = text.find("vpn_client_handle()")
    if start < 0:
        raise SystemExit("Error: vpn_client_handle() not found in stock 90-vpn")
    marker = 'config_get vpntype "client" "vpntype"'
    pos = text.find(marker, start)
    if pos < 0:
        raise SystemExit("Error: stock vpntype lookup not found in vpn_client_handle()")
    pos = text.find("\n", pos) + 1
    snippet = r'''
    # NetBird owns its own route table and DNS behavior. The stock VPN Client
    # hotplug otherwise installs pref-500 table-vpn policy routing and starts
    # vpnDnsproxy, which conflicts with NetBird Networks and the AX53 DNS stack.
    if [ "$vpntype" = "netbirdvpn" ]; then
        killall vpnDnsproxy >/dev/null 2>&1 || true
        while ip rule del pref "$VPN_CLIENT_PREF" fwmark "$VPN_CLIENT_MARK/$VPN_CLIENT_MASK" iif "$BRIDGE_NAME" table vpn >/dev/null 2>&1; do :; done
        ip route flush table vpn >/dev/null 2>&1 || true
        ip route flush cache >/dev/null 2>&1 || true
        return 0
    fi
'''
    text = text[:pos] + snippet + text[pos:]
    path.write_text(text)
PY
grep -Fq '# NetBird owns its own route table and DNS behavior.' "$VPN_HOTPLUG" || {
  echo "Error: NetBird stock-hotplug isolation was not installed" >&2
  exit 1
}

echo "[6/7] factory-reset cleanup in /sbin/reset ..."
if ! grep -q "tp_data/netbird" "$R/sbin/reset" 2>/dev/null; then
  sed -i 's#^sleep 3$#rm -rf /tp_data/netbird\nsleep 3#' "$R/sbin/reset"
fi

echo "[7/7] verifying installed files ..."
for f in lib/netbird/netbird.sh lib/netbird/netbird-profiles.sh lib/netifd/proto/netbird.sh sbin/netbird-ctl sbin/xzmini usr/bin/netbird \
         usr/lib/lua/luci/controller/admin/netbird.lua usr/lib/lua/luci/model/netbird.lua \
         usr/lib/lua/luci/controller/admin/vpn.lua www/webpages/js/VpnServerNetbirdForm-NB.js.gz; do
  [ -f "$R/$f" ] && echo "    ok  $f" || { echo "    MISSING $f" >&2; exit 1; }
done

is_stock_vpn "$VPN_CONTROLLER" || { echo "Error: /admin/vpn controller is not original TP-Link bytecode" >&2; exit 1; }
for forbidden_op in 'enroll' 'settings_set' 'profile_delete' 'connected_status' 'settings_get'; do
  if grep -Fq "op == \"$forbidden_op\"" "$R/usr/lib/lua/luci/controller/admin/netbird.lua"; then
    echo "Error: /admin/netbird shadows stock/provider-save operation: $forbidden_op" >&2
    exit 1
  fi
done
grep -q 'local function op_stage_setup_key(body)' "$R/usr/lib/lua/luci/controller/admin/netbird.lua" || {
  echo "Error: provider-side Setup Key staging endpoint missing" >&2; exit 1;
}
grep -q 'description' "$R/usr/lib/lua/luci/model/netbird.lua" || {
  echo "Error: NetBird profile description persistence missing" >&2; exit 1;
}
grep -q '# NetBird v4 CIDR-scoped/applied-state' "$R/lib/firewall/tpcmd.sh" || {
  echo "Error: canonical NetBird firewall source was not installed" >&2; exit 1;
}
grep -Fq -- '-o wt0 -s $cidr' "$R/lib/firewall/tpcmd.sh" || {
  echo "Error: clientless LAN -> wt0 scoped MASQUERADE missing" >&2; exit 1;
}
NB_FORM_JS="$(zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz")"
printf '%s' "$NB_FORM_JS" | grep -Fq 'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })' || {
  echo "Error: NetBird subform does not expose TP-Link native isChanged contract" >&2; exit 1;
}
printf '%s' "$NB_FORM_JS" | grep -Fq 'enrollment_token: enrollmentToken.value || ""' || {
  echo "Error: NetBird subform does not pass opaque enrollment token into stock Save" >&2; exit 1;
}
printf '%s' "$NB_FORM_JS" | grep -Fq '"onUpdate:modelValue": onSetupKey' || { echo "Error: Setup Key password model binding missing" >&2; exit 1; }
printf '%s' "$NB_FORM_JS" | grep -Fq 'onInput: onSetupKey' || { echo "Error: Setup Key native input fallback missing" >&2; exit 1; }
if printf '%s' "$NB_FORM_JS" | grep -Fq 'setup_key: setupKey.value || ""'; then
  echo "Error: Setup Key leaked into stock Save form payload" >&2
  exit 1
fi
printf '%s' "$NB_FORM_JS" | grep -Fq 'throw new Error(error.value)' || {
  echo "Error: NetBird validate() does not reject invalid state like stock forms" >&2; exit 1;
}
printf '%s' "$NB_FORM_JS" | grep -Fq 'draft.value.disable_client_routes = "0"' || {
  echo "Error: LAN gateway mode does not enable NetBird client routes" >&2; exit 1;
}
printf '%s' "$NB_FORM_JS" | grep -Fq 'DNS do NetBird fica desabilitado no AX53' || {
  echo "Error: AX53 DNS safety notice missing" >&2; exit 1;
}
if printf '%s' "$NB_FORM_JS" | grep -Fq 'Habilitar DNS do NetBird'; then
  echo "Error: unsupported NetBird DNS toggle is exposed on AX53" >&2
  exit 1
fi
for forbidden in '"label-width": { span: 10 }' '"content-width": { span: 14 }' 'async function enroll()' 'async function afterStockSave()' 'syncNativeSaveButton' 'data-netbird-dirty' '__netbirdSaveListener' 'stopImmediatePropagation' 'netbirdSaveSyncTimer' 'Já existe um perfil NetBird'; do
  if printf '%s' "$NB_FORM_JS" | grep -Fq "$forbidden"; then
    echo "Error: obsolete/singleton NetBird form logic leaked into final form: $forbidden" >&2
    exit 1
  fi
done

echo "### NetBird VPN Client integration complete ###"
