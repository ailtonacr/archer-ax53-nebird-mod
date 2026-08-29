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
NATIVE_RUNTIME="$PROJECT_ROOT/src/init/netbird-runtime.sh"
BYTECODE_VERIFIER="$PROJECT_ROOT/scripts/verify-tplink-vpn-bytecode.py"
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
VPN_CORE="$R/lib/vpn/vpn_core.sh"

for f in "$NATIVE_MODEL" "$NATIVE_CONTROLLER" "$NATIVE_PATCHER" "$NATIVE_RUNTIME" "$BYTECODE_VERIFIER" "$VPN_CONTROLLER" "$VPN_CORE"; do
  [ -f "$f" ] || { echo "Error: missing native NetBird input: $f" >&2; exit 1; }
done

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"

mkdir -p "$R/usr/lib/lua/luci/model" "$R/usr/lib/lua/luci/controller/admin" "$R/lib/netbird"
cp "$NATIVE_MODEL" "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
cp "$NATIVE_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
cp "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"
chmod 0644 "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua" \
    "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua" \
    "$R/lib/netbird/netbird-runtime.sh"

if command -v luac >/dev/null 2>&1; then
  luac -p "$NATIVE_MODEL" "$NATIVE_CONTROLLER"
fi

python3 "$NATIVE_PATCHER" "$R"

# vpnc/netifd is the only normal boot/start owner.
rm -f "$R/etc/rc.d/S99netbird"

# Vendor acceleration hooks only know stock protocol families. Preserve them for
# every stock VPN and skip them only for the native NetBird type.
python3 - "$VPN_CORE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
old = '''\t#init accelskip rule
\tfw vpnc_access_accel_handle $vpntype
\t
\t#init accelskip rule
\tfw vpnc_accelskip_add $vpntype
'''
new = '''\t# NetBird is a userspace/no-device netifd protocol and does not use the
\t# vendor acceleration hooks for PPTP/L2TP/OpenVPN/WireGuard.
\tif [ "$vpntype" != "netbirdvpn" ]; then
\t\t#init accelskip rule
\t\tfw vpnc_access_accel_handle $vpntype
\t\t
\t\t#init accelskip rule
\t\tfw vpnc_accelskip_add $vpntype
\tfi
'''
if new not in text:
    if text.count(old) != 1:
        raise SystemExit("Error: stock vpn_core acceleration block not found exactly once")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY

# Native registry contract.
grep -q 'TYPE = "netbirdvpn"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'TYPE_ID = "5"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'local schema = { proto = PROTO }' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'table.insert(schema, { key = key })' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_CFG_TBL\[TYPE\] = netbird_config' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TBL\[TYPE\] = schema' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'native.install()' "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
grep -Fq 'if [ "$vpntype" != "netbirdvpn" ]; then' "$VPN_CORE"

# Native runtime invariants.
cmp -s "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh" || { echo "Error: packaged native NetBird runtime drifted" >&2; exit 1; }
grep -q '^nb_runtime_connect()' "$R/lib/netbird/netbird-runtime.sh"
grep -q '^nb_runtime_is_connected()' "$R/lib/netbird/netbird-runtime.sh"
grep -q -- '--wireguard-port=' "$R/lib/netbird/netbird-runtime.sh"
grep -q 'nb_runtime_connect' "$R/lib/netifd/proto/netbird.sh"
if grep -q '/sbin/netbird-ctl' "$R/lib/netifd/proto/netbird.sh"; then
  echo "Error: netifd NetBird protocol still depends on netbird-ctl" >&2
  exit 1
fi
if grep -q 'proto_set_available' "$R/lib/netifd/proto/netbird.sh"; then
  echo "Error: transient NetBird connection failure changes protocol availability" >&2
  exit 1
fi
test ! -e "$R/etc/rc.d/S99netbird" || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }

# Final frontend contract: stock CRUD/base form, protocol-only su-* subform.
zcat "$R/www/webpages/js/update-store-DQkZxaRI.js.gz" | grep -Fq 'e.Netbird="netbirdvpn"'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'new URL(n).hostname'
zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const existing = !!(value && (value.key || value.id))'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const creating = ref(true)'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'stockComponent(this, "su-form")'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'stockComponent(this, "su-checkbox")'

if zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'value.type === "netbirdvpn"'; then
  echo "Error: NetBird Add/Edit still inferred from VPN type instead of persisted key/id" >&2
  exit 1
fi
if zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'a.value=_nb.concat(e)'; then
  echo "Error: synthetic NetBird list bridge still present" >&2
  exit 1
fi
if zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}'; then
  echo "Error: dedicated NetBird connected-status bridge still present" >&2
  exit 1
fi

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"
echo "### NetBird native TP-Link VPN registration complete ###"
