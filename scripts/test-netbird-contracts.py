#!/usr/bin/env python3
"""Offline structural contracts for the AX53 native NetBird integration.

Architectural rule: TP-Link owns every generic VPN Client operation it already
implements. NetBird adds only a fifth provider, its protocol fields/runtime and
profile-scoped enrollment/diagnostics. Provider persistence maintenance must not
intercept generic CRUD. No compatibility/migration path from older NetBird
implementations is part of the current firmware.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    p = ROOT / path
    assert p.is_file(), f"missing required file: {path}"
    return p.read_text(encoding="utf-8")


def shell_code(body: str) -> str:
    return "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("#"))


def require(body: str, *tokens: str) -> None:
    for token in tokens:
        assert token in body, f"contract missing {token!r}"


def check_native_registry() -> None:
    native = text("src/web-backend/model/netbird_vpn_native.lua")
    loader = text("src/web-backend/controller/admin/netbird_native.lua")
    require(
        native,
        'TYPE = "netbirdvpn"', 'TYPE_ID = "5"', 'TYPE_NAME = "NetBird"', 'PROTO = "netbird"',
        'local vpn = require "luci.controller.admin.vpn"',
        'local schema = { proto = PROTO }', 'table.insert(schema, { key = key })',
        'vpn.VPN_TBL[TYPE] = schema', 'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID', 'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'local profile_key = profile_key_from_config(cfg)',
        'if profile_key ~= "" then vpn.profile_key = profile_key end',
    )
    assert 'key = "netbird"' not in native
    assert 'legacy_identity' not in native
    assert "debug.getupvalue" not in native and "debug.setupvalue" not in native

    index_body = loader.split("function index()", 1)[1]
    require(index_body, 'local native = require "luci.model.netbird_vpn_native"', 'native.install()')
    assert 'local native = require "luci.model.netbird_vpn_native"\n\nfunction index()' not in loader


def check_stock_frontend_boundary() -> None:
    web = text("src/web/patchnetbird_web.py")
    factory = text("src/web/patchnetbird_factory_semantics.py")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    form = text("src/web/VpnServerNetbirdForm-NB.js")

    stock_tokens = ("STOCK_CONNECTED_STATUS", "STOCK_UPDATE", "STOCK_DELETE", "STOCK_LIST", "STOCK_SAVE")
    require(web, *stock_tokens)
    require(factory, *stock_tokens)
    require(finalizer, *stock_tokens)

    require(
        web,
        'e.Netbird="netbirdvpn"', 'case it.Netbird:return VpnServerNetbirdForm',
        'VpnServerNetbirdForm-NB.js?v=', 'hashlib.sha256', 'generic TP-Link VPN CRUD remains stock',
    )
    require(
        finalizer,
        'NATIVE_SERIALIZER =',
        'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname',
        'Generic operations must be stock before and after provider finalization.',
    )
    for token in ('DELETE_HELPER =', 'PROVIDER_DELETE =', 'await nbDelete(', 'operation:"profile_delete"'):
        assert token not in finalizer, f"generic delete interception leaked into finalizer: {token!r}"
    assert "def patch_model()" not in factory and "def patch_page()" not in factory

    require(
        form,
        'const creating = ref(true)', 'const existing = !!(value && (value.key || value.id))',
        'const profileKey = ref("")', 'if (!profileKey.value || creating.value || statusRequestPending) return',
        'Return protocol-specific fields only',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")', 'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")', 'stockComponent(this, "su-checkbox")',
        'profile_key: profileKey.value',
    )
    for token in (
        'value.type === "netbirdvpn"', 'value.type === "netbird"', 'key:e.key||"netbird"',
        'Já existe um perfil NetBird', 'a.value=_nb.concat(e)', 'operation:"settings_set"',
        'function nbSettingsSet(', 'enable: s.enable === "1" ? "on" : "off"',
        '"label-width": { span: 10 }',
    ):
        assert token not in form, f"generic/singleton behavior leaked into provider form: {token!r}"


def check_auxiliary_boundary() -> None:
    controller = text("src/web-backend/controller/admin/netbird.lua")
    model = text("src/web-backend/model/netbird.lua")
    require(
        controller,
        'local NATIVE_TYPE = "netbirdvpn"', 'local function requested_profile_key(body, required)',
        'local function native_profile(profile_key)', 'name == profile_key and section.type == NATIVE_TYPE',
        'local function native_profile_active(profile_key)', 'local function op_status(body)',
        'local function op_enroll(body)', 'model.control("enroll", profile_key, tmp)',
        'local function op_restart(body)', 'sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")',
        'local function op_log(body)', 'local function op_payload_status()',
    )
    dispatch = controller.split("function dispatch(body)", 1)[1]
    for op in ("settings_set", "settings_get", "connected_status", "profile_delete", "clean"):
        assert f'op == "{op}"' not in dispatch, f"auxiliary endpoint shadows stock/generic operation {op}"

    require(
        model,
        'ROOT     = "/tp_data/netbird"', 'PROFILES = ROOT .. "/profiles"',
        'cur.advertise_lan == "1" and cur.disable_server_routes ~= "0"',
        'server routes must be enabled when LAN routing is enabled',
        'cur.advertise_lan == "1" and cur.disable_firewall ~= "0"',
        'NetBird firewall must be enabled when LAN routing is enabled',
        'valid_profile_key', 'profile_dir', 'function status(profile_key)', 'function control(op, profile_key, keyfile)',
        'if not valid_profile_key(profile_key) then return nil, "invalid profile key" end',
    )
    for token in ('SETTINGS = ROOT .. "/settings"', 'LEGACY_ADOPTION =', 'function connected_status(', 'function remove_profile_state(', 'mark_legacy_profile_deleted'):
        assert token not in model, f"obsolete singleton/delete helper remains in provider model: {token!r}"


def check_profile_authority() -> None:
    profiles = text("src/init/netbird-profiles.sh")
    gc_init = text("src/init/netbird-profile-gc.init")
    profile_test = text("scripts/test-netbird-profiles.sh")
    require(
        profiles,
        'NB_ROOT=', 'NB_PROFILES_ROOT=', 'nb_profile_clear_context()', 'nb_profile_key_valid()',
        'nb_profile_select()', 'nb_profile_stock_exists()', 'vpn.$key.type',
        '[ "$section_type" = "server" ] && [ "$profile_type" = "netbirdvpn" ]',
        'nb_profile_gc_orphans()', 'NB_CONFIG_DIR=""', 'NB_SETTINGS_FILE=""',
        'there is intentionally no singleton/default profile context',
    )
    for token in ('NB_LEGACY', 'nb_legacy', 'legacy_identity', 'migrate-profile', 'legacy-adoption'):
        assert token not in profiles, f"migration token remains in profile helper: {token!r}"
    assert not (ROOT / "src/init/netbird-profile-migrate.init").exists(), "obsolete profile migration init still exists"

    require(gc_init, 'nb_profile_gc_orphans', 'never creates profiles', 'never starts or')
    gc_code = shell_code(gc_init)
    for token in ('nb_runtime_connect', 'netbird-ctl up', 'service_start', 'uci set'):
        assert token not in gc_code, f"profile GC exceeded maintenance boundary: {token}"

    require(
        profile_test,
        'root-level profile context survived helper load',
        'deleting B damaged A',
        'root-level identity was created',
        'obsolete migration token remains',
    )


def check_runtime_library() -> None:
    base = text("src/init/netbird.sh")
    runtime = text("src/init/netbird-runtime.sh")
    ctl = text("src/init/netbird-ctl")
    proto = text("src/init/netbird-proto.sh")
    recovery = text("src/init/netbird-recovery")

    require(base, 'NB_BIN="/tmp/netbird"', 'nb_materialize()', 'nb_payload_status()', 'nb_daemon_start()', 'nb_daemon_stop()', 'nb_fw_access()', 'nb_fw_block()')
    require(
        runtime,
        'nb_up_flags()', '"--wireguard-port=${wg_port}"', 'nb_runtime_validate_settings()',
        'LAN routing requires server routes to be enabled', 'LAN routing requires NetBird firewall policy enforcement',
        'NB_FW_STATE="/tmp/netbird-firewall.state"',
        'nb_runtime_connect()', 'nb_runtime_disconnect()', 'nb_runtime_stop()', 'nb_runtime_restart()',
    )
    runtime_code = shell_code(runtime)
    assert "/sbin/netbird-ctl" not in runtime_code
    assert not re.search(r'iptables\s+.*(?:-I|--insert)\s+FORWARD', runtime_code)
    assert "nb_fw_prioritize_lan" not in runtime

    require(
        ctl,
        '. /lib/netbird/netbird-profiles.sh', '--profile-key', 'nb_profile_select "$profile_key"',
        'no active native NetBird profile; use --profile-key KEY', '. /lib/netbird/netbird-runtime.sh',
    )
    for token in ('migrate-profile', 'nb_profile_use_legacy', 'nb_legacy_profile_adopt'):
        assert token not in ctl, f"obsolete CLI migration path remains: {token!r}"

    require(
        proto,
        '. /lib/netbird/netbird-profiles.sh', 'proto_config_add_string "profile_key"',
        'nb_profile_select "$profile_key"', 'nb_runtime_connect', 'nb_runtime_is_connected', 'nb_runtime_stop',
        'if [ "$vpntype" != "netbirdvpn" ]; then', 'add_protocol netbird',
    )
    assert 'netbirdvpn|netbird' not in proto
    assert "/sbin/netbird-ctl" not in shell_code(proto)
    assert "proto_set_available" not in proto

    require(recovery, 'nb_recovery_native_active()', 'nb_profile_select_active', '/etc/init.d/vpnc restart')
    assert "nb_runtime_connect" not in shell_code(recovery)


def check_firewall_source() -> None:
    fw = text("src/init/netbird_firewall.inc")
    mod = text("mods/010-netbird.sh")
    require(
        fw,
        '# NetBird v4 CIDR-scoped/applied-state firewall integration.',
        'NetBird v0.77.1 owns route authorization through NETBIRD-RT-FWD-* chains',
        'fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }',
        'fw_s_add 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }',
    )
    assert 'fw_s_add 4 f FORWARD ACCEPT 1 {' not in fw
    require(mod, 'FIREWALL_SRC="$RUNTIME_SRC/netbird_firewall.inc"', 'cat "$FIREWALL_SRC" >> "$R/lib/firewall/tpcmd.sh"')


def check_build_gates() -> None:
    mod010 = text("mods/010-netbird.sh")
    mod012 = text("mods/012-netbird-native-vpn.sh")
    makefile = text("Makefile")
    verifier = text("scripts/verify-tplink-vpn-bytecode.py")
    require(
        mod012,
        'Generic list/ADD/EDIT/Save/toggle/DELETE/connected-status remain stock.',
        'python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"',
        'function f(e){return a.request(y,{operation:"connected_status",key:e}',
        'async function W(e,n){await function(e,n,t){return a.update(y,{key:e}',
        'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n}',
        'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
        '"add"===n.type?await Ce(i):await ne(i,n.tableItem)',
        'VpnServerNetbirdForm-NB.js?v=', 'nb_profile_gc_orphans',
        'PROFILE_GC_INIT=', 'netbird-profile-gc', 'generic flow fully stock',
    )
    for token in ('PROFILE_MIGRATE_INIT', 'nb_legacy_profile_adopt', 'S89netbird-profile-migrate'):
        assert token not in mod012 or token == 'S89netbird-profile-migrate', f"obsolete migration implementation remains: {token!r}"
    require(mod012, 'rm -f "$R/etc/init.d/netbird-profile-migrate"', 'obsolete NetBird migration token remains')
    require(mod010, 'for generic_op in', "'profile_delete'", "'connected_status'", "'settings_get'")
    require(
        verifier,
        '"VPN_TBL"', '"VPN_CFG_TBL"', '"VPN_TYPE_TBL"', '"VPN_TYPE_NAME_TBL"',
        'STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}',
    )
    require(
        makefile,
        'test-netbird:', 'src/init/netbird-profile-gc.init', 'scripts/test-netbird-profiles.sh',
        'scripts/test-netbird-recovery.sh', 'obsolete NetBird profile migration service remains',
        'independent profile identities + orphan GC; no migration path',
    )
    assert 'src/init/netbird-profile-migrate.init' not in makefile


def main() -> None:
    check_native_registry()
    check_stock_frontend_boundary()
    check_auxiliary_boundary()
    check_profile_authority()
    check_runtime_library()
    check_firewall_source()
    check_build_gates()
    print("netbird provider-only TP-Link stock-flow structural contracts ok")


if __name__ == "__main__":
    main()
