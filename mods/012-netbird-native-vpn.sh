#!/bin/bash -e
# Finalize NetBird as a fifth native TP-Link VPN Client type while preserving
# the vendor vpn.lua bytecode byte-for-byte. This runs after 010-netbird.sh so
# it can migrate the historical dedicated CRUD bridges to the stock endpoint.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R="${ROOTFS_DIR:-$PROJECT_ROOT/rootfs}"
case "$R" in /*) ;; *) R="$PROJECT_ROOT/$R" ;; esac

NATIVE_MODEL="$PROJECT_ROOT/src/web-backend/model/netbird_vpn_native.lua"
NATIVE_CONTROLLER="$PROJECT_ROOT/src/web-backend/controller/admin/netbird_native.lua"
NATIVE_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_native_crud.py"
BYTECODE_VERIFIER="$PROJECT_ROOT/scripts/verify-tplink-vpn-bytecode.py"
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"

for f in "$NATIVE_MODEL" "$NATIVE_CONTROLLER" "$NATIVE_PATCHER" "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"; do
  [ -f "$f" ] || { echo "Error: missing native NetBird input: $f" >&2; exit 1; }
done

# Native registration depends on these four registries being module globals in
# TP-Link's compiled controller. Verify the exact bytecode contract rather than
# trusting only the Lua magic header or source-level assumptions.
python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"

mkdir -p "$R/usr/lib/lua/luci/model" "$R/usr/lib/lua/luci/controller/admin"
cp "$NATIVE_MODEL" "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
cp "$NATIVE_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
chmod 0644 "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua" "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"

if command -v luac >/dev/null 2>&1; then
  luac -p "$NATIVE_MODEL" "$NATIVE_CONTROLLER"
fi

python3 "$NATIVE_PATCHER" "$R"

# Native lifecycle ownership: vpnc/netifd is the only normal boot/start path.
# Keep /etc/init.d/netbird as a manual compatibility/recovery command, but remove
# the S99 autostart symlink installed by the historical hybrid integration.
rm -f "$R/etc/rc.d/S99netbird"

# Structural checks: real stock registries are extended, not replaced.
grep -q 'TYPE = "netbirdvpn"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'TYPE_ID = "5"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'local schema = { proto = PROTO }' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'table.insert(schema, { key = key })' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_CFG_TBL\[TYPE\] = netbird_config' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TBL\[TYPE\] = schema' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'native.install()' "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"

test ! -e "$R/etc/rc.d/S99netbird" || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }

zcat "$R/www/webpages/js/update-store-DQkZxaRI.js.gz" | grep -Fq 'e.Netbird="netbirdvpn"'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'new URL(n).hostname'
zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'type: "netbirdvpn", proto: "netbird"'

if zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'a.value=_nb.concat(e)'; then
  echo "Error: synthetic NetBird list bridge still present" >&2
  exit 1
fi
if zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}'; then
  echo "Error: dedicated NetBird connected-status bridge still present" >&2
  exit 1
fi

# Reconfirm the stock bytecode contract after all rootfs mutations too.
python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"

echo "### NetBird native TP-Link VPN registration complete ###"
