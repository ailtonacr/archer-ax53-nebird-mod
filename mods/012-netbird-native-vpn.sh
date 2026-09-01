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
NB_AUX_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/netbird.lua"

for f in "$NATIVE_MODEL" "$NATIVE_CONTROLLER" "$NATIVE_PATCHER" "$NATIVE_RUNTIME" "$BYTECODE_VERIFIER" "$VPN_CONTROLLER" "$VPN_CORE" "$NB_AUX_CONTROLLER"; do
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

# Auxiliary endpoint is read-only for profile settings. Native stock CRUD owns
# all normal settings writes; /admin/netbird may only expose diagnostics,
# enrollment, restart/recovery and idempotent identity cleanup.
if grep -Fq 'elseif op == "settings_set"' "$NB_AUX_CONTROLLER"; then
  echo "Error: auxiliary /admin/netbird still exposes writable settings_set" >&2
  exit 1
fi
grep -q 'result = "noop"' "$NB_AUX_CONTROLLER" || {
  echo "Error: NetBird profile cleanup is not idempotent for stock-profile delete" >&2
  exit 1
}

# Native runtime invariants.
cmp -s "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh" || { echo "Error: packaged native NetBird runtime drifted" >&2; exit 1; }
grep -q '^nb_runtime_connect()' "$R/lib/netbird/netbird-runtime.sh"
grep -q '^nb_runtime_is_connected()' "$R/lib/netbird/netbird-runtime.sh"
grep -q '^nb_runtime_validate_settings()' "$R/lib/netbird/netbird-runtime.sh"
grep -q 'NB_FW_STATE="/tmp/netbird-firewall.state"' "$R/lib/netbird/netbird-runtime.sh"
grep -q 'LAN routing requires server routes to be enabled' "$R/lib/netbird/netbird-runtime.sh"
grep -q 'LAN routing requires NetBird firewall policy enforcement' "$R/lib/netbird/netbird-runtime.sh"
grep -q -- '--wireguard-port=' "$R/lib/netbird/netbird-runtime.sh"
if grep -Eq 'iptables[[:space:]].*(-I|--insert)[[:space:]]+FORWARD' "$R/lib/netbird/netbird-runtime.sh"; then
  echo "Error: runtime contains a priority FORWARD bypass ahead of NetBird Route ACLs" >&2
  exit 1
fi
if grep -q 'nb_fw_prioritize_lan' "$R/lib/netbird/netbird-runtime.sh"; then
  echo "Error: retired NetBird Route ACL bypass helper remains" >&2
  exit 1
fi
grep -q 'nb_runtime_connect' "$R/lib/netifd/proto/netbird.sh"
if grep -q '/sbin/netbird-ctl' "$R/lib/netifd/proto/netbird.sh"; then
  echo "Error: netifd NetBird protocol still depends on netbird-ctl" >&2
  exit 1
fi
if grep -q 'proto_set_available' "$R/lib/netifd/proto/netbird.sh"; then
  echo "Error: transient NetBird connection failure changes protocol availability" >&2
  exit 1
fi
PROTO_SETUP="$(sed -n '/^proto_netbird_setup()/,/^proto_netbird_teardown()/p' "$R/lib/netifd/proto/netbird.sh")"
[ "$(printf '%s\n' "$PROTO_SETUP" | grep -c 'nb_runtime_stop')" -ge 2 ] || {
  echo "Error: netifd NetBird setup does not rollback both immediate failure and timeout" >&2
  exit 1
}
test ! -e "$R/etc/rc.d/S99netbird" || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }

# Canonical firewall must preserve NetBird v0.77.1 Route ACL ordering.
grep -q '# NetBird v4 CIDR-scoped/applied-state' "$R/lib/firewall/tpcmd.sh" || {
  echo "Error: ACL-safe canonical NetBird firewall source missing" >&2
  exit 1
}
if grep -Fq 'fw_s_add 4 f FORWARD ACCEPT 1 {' "$R/lib/firewall/tpcmd.sh"; then
  echo "Error: TP-Link NetBird FORWARD rule is inserted ahead of NetBird Route ACLs" >&2
  exit 1
fi
grep -Fq 'fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }' "$R/lib/firewall/tpcmd.sh" || {
  echo "Error: ACL-safe appended wt0 -> LAN rule missing" >&2
  exit 1
}

# Final frontend contract: stock CRUD/base form, protocol-only su-* subform.
zcat "$R/www/webpages/js/update-store-DQkZxaRI.js.gz" | grep -Fq 'e.Netbird="netbirdvpn"'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'new URL(n).hostname'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function nbDelete(){return a.request(nb,{operation:"profile_delete"}'
zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const existing = !!(value && (value.key || value.id))'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const creating = ref(true)'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'stockComponent(this, "su-form")'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'stockComponent(this, "su-checkbox")'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 's.advertise_lan === "1" && s.disable_server_routes !== "0"'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 's.advertise_lan === "1" && s.disable_firewall !== "0"'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'Permitir roteamento da LAN'

if zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'value.type === "netbirdvpn"'; then
  echo "Error: NetBird Add/Edit still inferred from VPN type instead of persisted key/id" >&2
  exit 1
fi
if zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'Anunciar rede local'; then
  echo "Error: UI still claims the router announces a NetBird management resource" >&2
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
if zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'operation:"settings_set"'; then
  echo "Error: writable hybrid NetBird settings helper remains in final bundle" >&2
  exit 1
fi
if zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function nbSettingsSet('; then
  echo "Error: nbSettingsSet helper remains in final native model bundle" >&2
  exit 1
fi

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"
echo "### NetBird native TP-Link VPN registration complete ###"
