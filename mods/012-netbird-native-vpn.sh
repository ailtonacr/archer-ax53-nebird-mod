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
PROFILE_HELPER="$PROJECT_ROOT/src/init/netbird-profiles.sh"
PROFILE_MIGRATE_INIT="$PROJECT_ROOT/src/init/netbird-profile-migrate.init"
BYTECODE_VERIFIER="$PROJECT_ROOT/scripts/verify-tplink-vpn-bytecode.py"
VPN_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/vpn.lua"
VPN_CORE="$R/lib/vpn/vpn_core.sh"
NB_AUX_CONTROLLER="$R/usr/lib/lua/luci/controller/admin/netbird.lua"

for f in "$NATIVE_MODEL" "$NATIVE_CONTROLLER" "$NATIVE_PATCHER" "$NATIVE_RUNTIME" "$PROFILE_HELPER" "$PROFILE_MIGRATE_INIT" "$BYTECODE_VERIFIER" "$VPN_CONTROLLER" "$VPN_CORE" "$NB_AUX_CONTROLLER"; do
  [ -f "$f" ] || { echo "Error: missing native NetBird input: $f" >&2; exit 1; }
done

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"

mkdir -p "$R/usr/lib/lua/luci/model" "$R/usr/lib/lua/luci/controller/admin" "$R/lib/netbird" "$R/etc/init.d" "$R/etc/rc.d"
cp "$NATIVE_MODEL" "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua"
cp "$NATIVE_CONTROLLER" "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua"
cp "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"
cp "$PROFILE_MIGRATE_INIT" "$R/etc/init.d/netbird-profile-migrate"
chmod 0644 "$R/usr/lib/lua/luci/model/netbird_vpn_native.lua" \
    "$R/usr/lib/lua/luci/controller/admin/netbird_native.lua" \
    "$R/lib/netbird/netbird-runtime.sh"
chmod 0755 "$R/etc/init.d/netbird-profile-migrate"

if command -v luac >/dev/null 2>&1; then
  luac -p "$NATIVE_MODEL" "$NATIVE_CONTROLLER"
fi

python3 "$NATIVE_PATCHER" "$R"

# vpnc/netifd is the only normal boot/start owner. The migration service is a
# one-shot config/identity adoption step and never starts the NetBird daemon.
rm -f "$R/etc/rc.d/S99netbird"
ln -sfn "../init.d/netbird-profile-migrate" "$R/etc/rc.d/S89netbird-profile-migrate"

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

# Native registry contract. A profile_key option is persisted after ADD so the
# runtime can select the exact per-row identity; no fixed synthetic key exists.
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

# Auxiliary endpoint is profile-scoped and read-only for normal profile fields.
# Stock CRUD owns configuration; /admin/netbird owns only identity/runtime extras.
if grep -Fq 'elseif op == "settings_set"' "$NB_AUX_CONTROLLER"; then
  echo "Error: auxiliary /admin/netbird still exposes writable settings_set" >&2
  exit 1
fi
grep -q 'requested_profile_key' "$NB_AUX_CONTROLLER" || {
  echo "Error: auxiliary NetBird operations are not keyed to a stock profile" >&2; exit 1;
}
grep -q 'profile_key:e' <(zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz") || {
  echo "Error: stock DELETE does not pass the deleted profile key to NetBird cleanup" >&2; exit 1;
}

# Profile-scoped persistence + legacy adoption must be present. The one-shot
# migration guarantees a historical installed client becomes a real vpn.server
# row in the stock list instead of a synthetic frontend-only row.
cmp -s "$PROFILE_HELPER" "$R/lib/netbird/netbird-profiles.sh" || { echo "Error: packaged profile helper drifted" >&2; exit 1; }
cmp -s "$PROFILE_MIGRATE_INIT" "$R/etc/init.d/netbird-profile-migrate" || { echo "Error: packaged profile migration init drifted" >&2; exit 1; }
grep -q '^nb_profile_select()' "$R/lib/netbird/netbird-profiles.sh"
grep -q '^nb_legacy_profile_adopt()' "$R/lib/netbird/netbird-profiles.sh"
grep -Fq 'vpn.$section.type=netbirdvpn' "$R/lib/netbird/netbird-profiles.sh"
grep -Fq 'profile_key=$section' "$R/lib/netbird/netbird-profiles.sh"
[ -L "$R/etc/rc.d/S89netbird-profile-migrate" ] || { echo "Error: legacy NetBird adoption boot link missing" >&2; exit 1; }
[ "$(readlink "$R/etc/rc.d/S89netbird-profile-migrate")" = "../init.d/netbird-profile-migrate" ] || { echo "Error: legacy NetBird adoption link target incorrect" >&2; exit 1; }

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
if grep -Ev '^[[:space:]]*#' "$R/lib/netifd/proto/netbird.sh" | grep -q '/sbin/netbird-ctl'; then
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

# Final frontend contract: stock CRUD/base form, protocol-only su-* subform,
# stock-generated row keys, and profile-scoped auxiliary cleanup.
zcat "$R/www/webpages/js/update-store-DQkZxaRI.js.gz" | grep -Fq 'e.Netbird="netbirdvpn"'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'new URL(n).hostname'
zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" | grep -Fq 'function nbDelete(e){return a.request(nb,{operation:"profile_delete",profile_key:e}'
zcat "$R/www/webpages/js/index-DTNtPvwx.js.gz" | grep -Fq 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const existing = !!(value && (value.key || value.id))'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'const profileKey = ref("")'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'profile_key: profileKey.value'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'stockComponent(this, "su-form")'
zcat "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" | grep -Fq 'Permitir roteamento da LAN'

for forbidden in 'key:e.key||"netbird"' 'Já existe um perfil NetBird' 'a.value=_nb.concat(e)' 'operation:"settings_set"' 'function nbSettingsSet(' 'value.type === "netbirdvpn"' '"label-width": { span: 10 }'; do
  if zcat "$R/www/webpages/js/model-CI6Gt3Hz.js.gz" "$R/www/webpages/js/index-DTNtPvwx.js.gz" "$R/www/webpages/js/VpnServerNetbirdForm-NB.js.gz" 2>/dev/null | grep -Fq "$forbidden"; then
    echo "Error: singleton/hybrid NetBird frontend token remains: $forbidden" >&2
    exit 1
  fi
done

python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"
echo "### NetBird native TP-Link VPN registration complete ###"
