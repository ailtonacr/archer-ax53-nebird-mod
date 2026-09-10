#!/bin/bash -e
# Finalize NetBird as a fifth native TP-Link VPN Client type while preserving
# the vendor vpn.lua bytecode and generic VPN Client semantics.
#
# Allowed custom surface:
#   - register type=netbirdvpn in the stock controller registries
#   - provider-specific frontend subform/serialization
#   - netifd proto=netbird + runtime
#   - profile-scoped enrollment/identity/diagnostics
#   - provider-state orphan garbage collection
#
# Generic list/ADD/EDIT/Save/toggle/DELETE/connected-status remain stock.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R="${ROOTFS_DIR:-$PROJECT_ROOT/rootfs}"
case "$R" in /*) ;; *) R="$PROJECT_ROOT/$R" ;; esac

NATIVE_MODEL="$PROJECT_ROOT/src/web-backend/model/netbird_vpn_native.lua"
NATIVE_CONTROLLER="$PROJECT_ROOT/src/web-backend/controller/admin/netbird_native.lua"
NATIVE_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_native_crud.py"
NATIVE_RUNTIME="$PROJECT_ROOT/src/init/netbird-runtime.sh"
PROFILE_HELPER="$PROJECT_ROOT/src/init/netbird-profiles.sh"
PROFILE_GC_INIT="$PROJECT_ROOT/src/init/netbird-profile-gc.init"
BYTECODE_VERIFIER="$PROJECT_ROOT/scripts/verify-tplink-vpn-bytecode.py"
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
VPN_CORE="$R/lib/vpn/vpn_core.sh"
NB_AUX_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/netbird.lua"

for f in "$NATIVE_MODEL" "$NATIVE_CONTROLLER" "$NATIVE_PATCHER" "$NATIVE_RUNTIME" "$PROFILE_HELPER" "$PROFILE_GC_INIT" "$BYTECODE_VERIFIER" "$VPN_CONTROLLER" "$VPN_CORE" "$NB_AUX_CONTROLLER"; do
  [ -f "$f" ] || { echo "Error: missing native NetBird input: $f" >&2; exit 1; }
done

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"

mkdir -p "$R/usr/lib/lua/luci/model" "$R/usr/lib/lua/luci/controller/admin" "$R/lib/netbird" "$R/etc/init.d" "$R/etc/rc.d"
cp "$NATIVE_MODEL" "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
cp "$NATIVE_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
cp "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"
cp "$PROFILE_GC_INIT" "$R/etc/init.d/netbird-profile-gc"
chmod 0644 "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua" \
    "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua" \
    "$R/lib/netbird/netbird-runtime.sh"
chmod 0755 "$R/etc/init.d/netbird-profile-gc"

if command -v luac >/dev/null 2>&1; then
  luac -p "$NATIVE_MODEL" "$NATIVE_CONTROLLER"
fi

python3 "$NATIVE_PATCHER" "$R"

# vpnc/netifd is the only normal boot/start owner. This one-shot service only
# garbage-collects orphaned provider state and never starts/stops the daemon.
rm -f "$R/etc/rc.d/S99netbird"
ln -sfn "../init.d/netbird-profile-gc" "$R/etc/rc.d/S89netbird-profile-gc"

# Vendor acceleration hooks only know the original protocol families. Preserve
# them untouched for stock types and skip them only for our new native provider.
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

# Native registry contract: extend the stock registries instead of replacing the
# controller or adding a parallel profile manager.
grep -q 'TYPE = "netbirdvpn"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'TYPE_ID = "5"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q '"profile_key"' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'local schema = { proto = PROTO }' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'table.insert(schema, { key = key })' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_CFG_TBL\[TYPE\] = netbird_config' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_TBL\[TYPE\] = TYPE_ID' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TYPE_NAME_TBL\[TYPE\] = TYPE_NAME' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'vpn.VPN_TBL\[TYPE\] = schema' "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
grep -q 'native.install()' "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
grep -Fq 'if [ "$vpntype" != "netbirdvpn" ]; then' "$VPN_CORE"

# /admin/netbird may expose only provider-specific operations. Generic writable
# profile configuration and generic CRUD/status must never be duplicated there.
if grep -Fq 'elseif op == "settings_set"' "$NB_AUX_CONTROLLER"; then
  echo "Error: auxiliary /admin/netbird still exposes writable settings_set" >&2
  exit 1
fi
grep -q 'requested_profile_key' "$NB_AUX_CONTROLLER" || {
  echo "Error: auxiliary NetBird operations are not keyed to a stock profile" >&2; exit 1;
}
grep -q 'local function op_enroll' "$NB_AUX_CONTROLLER" || {
  echo "Error: profile-scoped NetBird enrollment endpoint missing" >&2; exit 1;
}

# Profile-scoped persistence only. There is no singleton identity. TP-Link owns
# deletion; orphaned provider state is garbage-collected independently.
cmp -s "$PROFILE_HELPER" "$R/lib/netbird/netbird-profiles.sh" || { echo "Error: packaged profile helper drifted" >&2; exit 1; }
cmp -s "$PROFILE_GC_INIT" "$R/etc/init.d/netbird-profile-gc" || { echo "Error: packaged profile GC init drifted" >&2; exit 1; }
grep -q '^nb_profile_select()' "$R/lib/netbird/netbird-profiles.sh"
grep -q '^nb_profile_stock_exists()' "$R/lib/netbird/netbird-profiles.sh"
grep -q '^nb_profile_gc_orphans()' "$R/lib/netbird/netbird-profiles.sh"
grep -q '^nb_profile_clear_context()' "$R/lib/netbird/netbird-profiles.sh"
grep -Fq 'NB_PROFILES_ROOT="${NB_PROFILES_ROOT:-$NB_ROOT/profiles}"' "$R/lib/netbird/netbird-profiles.sh"
grep -Fq 'nb_profile_gc_orphans' "$R/etc/init.d/netbird-profile-gc"
[ -L "$R/etc/rc.d/S89netbird-profile-gc" ] || { echo "Error: NetBird profile GC boot link missing" >&2; exit 1; }
[ "$(readlink "$R/etc/rc.d/S89netbird-profile-gc")" = "../init.d/netbird-profile-gc" ] || { echo "Error: NetBird profile GC link target incorrect" >&2; exit 1; }

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
grep -q 'proto_config_add_string "profile_key"' "$R/lib/netifd/proto/netbird.sh"
grep -q 'nb_profile_select "$profile_key"' "$R/lib/netifd/proto/netbird.sh"
grep -Fq 'if [ "$vpntype" != "netbirdvpn" ]; then' "$R/lib/netifd/proto/netbird.sh"
if grep -Ev '^[[:space:]]*#' "$R/lib/netifd/proto/netbird.sh" | grep -q '/sbin/netbird-ctl'; then
  echo "Error: netifd NetBird protocol still depends on netbird-ctl" >&2
  exit 1
fi
if grep -q 'proto_set_available' "$R/lib/netifd/proto/netbird.sh"; then
  echo "Error: transient NetBird failure changes protocol availability" >&2
  exit 1
fi
PROTO_SETUP="$(sed -n '/^proto_netbird_setup()/,/^proto_netbird_teardown()/p' "$R/lib/netifd/proto/netbird.sh")"
[ "$(printf '%s\n' "$PROTO_SETUP" | grep -c 'nb_runtime_stop')" -ge 2 ] || {
  echo "Error: netifd NetBird setup does not rollback both immediate failure and timeout" >&2
  exit 1
}
test ! -e "$R/etc/rc.d/S99netbird" || { echo "Error: standalone NetBird boot lifecycle still enabled" >&2; exit 1; }

# Canonical firewall must preserve NetBird v0.77.1 Route ACL ordering.
NB_FW_CANONICAL="$(sed -n '/# NetBird v4 CIDR-scoped\/applied-state/,$p' "$R/lib/firewall/tpcmd.sh")"
[ -n "$NB_FW_CANONICAL" ] || { echo "Error: ACL-safe canonical NetBird firewall source missing" >&2; exit 1; }
if printf '%s\n' "$NB_FW_CANONICAL" | grep -Fq 'fw_s_add 4 f FORWARD ACCEPT 1 {'; then
  echo "Error: canonical TP-Link NetBird FORWARD rule is inserted ahead of NetBird Route ACLs" >&2
  exit 1
fi
printf '%s\n' "$NB_FW_CANONICAL" | grep -Fq 'fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }' || {
  echo "Error: ACL-safe appended wt0 -> LAN rule missing from canonical NetBird firewall section" >&2
  exit 1
}

# Final frontend contract: provider injection/serialization only. Every generic
# TP-Link function remains unchanged.
UPDATE_JS="$(zcat "$R/www/webpages/js/update-store-DQkZxaRI.js.gz")"
MODEL_JS="$(zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz")"
PAGE_JS="$(zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz")"
FORM_JS="$(zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz")"

printf '%s' "$UPDATE_JS" | grep -Fq 'e.Netbird="netbirdvpn"'
printf '%s' "$MODEL_JS" | grep -Fq 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
printf '%s' "$MODEL_JS" | grep -Fq 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
printf '%s' "$MODEL_JS" | grep -Fq 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
printf '%s' "$MODEL_JS" | grep -Fq 'new URL(n).hostname'
printf '%s' "$PAGE_JS" | grep -Fq 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
printf '%s' "$PAGE_JS" | grep -Fq '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
printf '%s' "$PAGE_JS" | grep -Fq 'case it.Netbird:return VpnServerNetbirdForm'
printf '%s' "$PAGE_JS" | grep -Fq 'VpnServerNetbirdForm-NB.js?v='
printf '%s' "$FORM_JS" | grep -Fq 'const existing = !!(value && (value.key || value.id))'
printf '%s' "$FORM_JS" | grep -Fq 'const profileKey = ref("")'
printf '%s' "$FORM_JS" | grep -Fq 'profile_key: profileKey.value'
printf '%s' "$FORM_JS" | grep -Fq 'stockComponent(this, "su-form")'
printf '%s' "$FORM_JS" | grep -Fq 'Permitir roteamento da LAN'

for forbidden in \
  'key:e.key||"netbird"' \
  'Já existe um perfil NetBird' \
  'a.value=_nb.concat(e)' \
  'const nb="/admin/netbird"' \
  'operation:"settings_set"' \
  'operation:"profile_delete"' \
  'function nbSettingsSet(' \
  'function nbControl(' \
  'function nbDelete(' \
  'value.type === "netbirdvpn"' \
  '"label-width": { span: 10 }' \
  '__nbActiveStockVpn' \
  'window.__netbirdSaveDraft' \
  '__netbirdSaveListener'
do
  if printf '%s\n%s\n%s\n' "$MODEL_JS" "$PAGE_JS" "$FORM_JS" | grep -Fq "$forbidden"; then
    echo "Error: non-stock/singleton NetBird frontend token remains: $forbidden" >&2
    exit 1
  fi
done

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"
echo "### NetBird native TP-Link VPN registration complete: generic flow fully stock ###"
