#!/usr/bin/env python3
"""Offline structural contracts for the AX53 native NetBird integration.

Architectural rule: TP-Link owns every generic VPN Client operation it already
implements. NetBird adds only a fifth provider, protocol fields/runtime and
profile-scoped diagnostics. The Setup Key is staged through the provider
endpoint; stock Save carries only an opaque enrollment token.
"""
from __future__ import annotations

import ast
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


def python_tree(body: str) -> ast.AST:
    return ast.parse(body)


def python_function_names(body: str) -> set[str]:
    return {node.name for node in ast.walk(python_tree(body)) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def python_assignment_string(body: str, name: str) -> str:
    for node in ast.walk(python_tree(body)):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            value = node.value
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return value.value
    raise AssertionError(f"python string assignment {name!r} missing")


def python_named_literal_values(body: str, name: str) -> set[str]:
    values: set[str] = set()
    for node in ast.walk(python_tree(body)):
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            continue
        if isinstance(node.value, (ast.Tuple, ast.List, ast.Set)):
            for item in node.value.elts:
                if isinstance(item, ast.Constant) and isinstance(item.value, str):
                    values.add(item.value)
    return values


def check_native_registry() -> None:
    native = text("src/web-backend/model/netbird_vpn_native.lua")
    loader = text("src/web-backend/controller/admin/netbird_native.lua")
    require(
        native,
        'TYPE = "netbirdvpn"', 'TYPE_ID = "5"', 'TYPE_NAME = "NetBird"', 'PROTO = "netbird"',
        'local vpn = require "luci.controller.admin.vpn"',
        'local schema = { proto = PROTO }',
        'table.insert(schema, { key = key })',
        'vpn.VPN_TBL[TYPE] = schema', 'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID', 'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'local profile_key = profile_key_from_config(cfg)',
        'if profile_key == "" then', 'stock VPN profile key missing',
        'profile_key = profile_key,',
        'disable_dns = "1"',
        'disable_client_routes = "0"',
        'local enrollment_token = tostring(cfg.enrollment_token or "")',
        'nb_model.staged_setup_key_path(enrollment_token)',
        'if enrollment_token ~= "" then vpn.enrollment_token = enrollment_token end',
        'enrollment token required for unenrolled profile',
    )
    assert 'field = { key }' not in native and 'canbe_empty = true' not in native, "retired inferred VPN_TBL rule shape returned"
    fields = native.split('local FIELDS = {', 1)[1].split('}', 1)[0]
    assert '"setup_key",' not in fields, "setup_key must never be a VPN_TBL field"
    assert '"enrollment_token",' in fields, "opaque enrollment token must reach protocol staging"
    assert 'cfg.setup_key' not in native, "native stock callback must never receive the secret"
    assert 'nb_model.control("enroll"' not in native, "stock Save callback must never block on enrollment"
    assert 'enroll_transient(' not in native, "enrollment must be owned by netifd lifecycle"
    assert 'key = "netbird"' not in native
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
        'VpnServerNetbirdForm-NB.js?v=', 'hashlib.sha256',
        'assert_stock_model_untouched(root)', 'patch_vpn_page(root, module_spec)',
    )
    require(
        finalizer,
        'NATIVE_SERIALIZER =', 'k=e.key||t()', 'key:k,des:e.description,type:e.type,enable:i(e.enable),server:n,profile_key:k',
        'management_url:e.management_url||""', 'enrollment_token:e.enrollment_token||""',
        'new URL(n).hostname',
        'required = (STOCK_CONNECTED_STATUS, STOCK_UPDATE, STOCK_DELETE, NATIVE_SERIALIZER)',
        'text = text.replace(marker, NATIVE_SERIALIZER, 1)',
        'def patch_model_import_cache_key() -> None:',
        'digest = hashlib.sha256(model.encode("utf-8")).hexdigest()[:12]',
        'desired = f\'from"./model-CI6Gt3Hz.js?v={digest}"\'',
    )

    guarded_tokens = {
        'key:e.key||"netbird"', 'function nbSettingsSet(', 'function nbControl(',
        'function nbDelete(', 'operation:"profile_delete"', 'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)', 'window.__netbirdSaveDraft',
        '__netbirdSaveListener', 'stopImmediatePropagation',
        'async function afterStockSave()', 'async function enroll()', 'setup_key:e.setup_key',
    }
    guard_literals = python_named_literal_values(finalizer, "forbidden")
    missing_guards = guarded_tokens - guard_literals
    assert not missing_guards, f"finalizer guard list missing retired tokens: {sorted(missing_guards)!r}"

    serializer = python_assignment_string(finalizer, "NATIVE_SERIALIZER")
    leaked_serializer = [token for token in guarded_tokens if token in serializer]
    assert not leaked_serializer, f"retired bridge leaked into injected serializer: {leaked_serializer!r}"

    finalizer_functions = python_function_names(finalizer)
    assert "patch_page" not in finalizer_functions, "finalizer must not patch the generic VPN page"
    assert "nbDelete" not in finalizer_functions and "afterStockSave" not in finalizer_functions
    factory_functions = python_function_names(factory)
    assert "patch_model" not in factory_functions and "patch_page" not in factory_functions

    require(
        form,
        'const creating = ref(true)', 'const existing = !!(value && (value.key || value.id))',
        'const profileKey = ref("")', 'if (!profileKey.value || creating.value || statusRequestPending) return',
        'enrollment_token: enrollmentToken.value || ""', 'stage_setup_key',
        'if (!creating.value && hasIdentity === null && profileKey.value)',
        'const showSetupKey = this.creating || this.identityPresent === false;',
        'if (showSetupKey) {',
        'A Setup Key será usada uma única vez para enrollment e nunca será armazenada no perfil.',
        'const enrollmentHandedOff = ref(false)',
        'draft.value.disable_client_routes = "0"',
        'DNS do NetBird fica desabilitado no AX53',
        'if (enrollmentToken.value) enrollmentHandedOff.value = true',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")', 'stockComponent(this, "su-form-item")', 'stockComponent(this, "su-input")',
        'stockComponent(this, "su-password")', '"onUpdate:modelValue": onSetupKey', 'onInput: onSetupKey', 'stockComponent(this, "su-checkbox")',
        '_h(SuForm, { model: s }, { default: () => items })',
    )
    assert '["Habilitar DNS do NetBird", "disable_dns"' not in form, "AX53 must not expose NetBird DNS toggle"

    for token in (
        '"label-width": { span: 10 }', '"content-width": { span: 14 }', 'async function enroll()', 'async function afterStockSave()',
        'value.type === "netbirdvpn"', 'value.type === "netbird"', 'key:e.key||"netbird"',
        'Já existe um perfil NetBird', 'a.value=_nb.concat(e)', 'operation:"settings_set"',
        'function nbSettingsSet(', 'enable: s.enable === "1" ? "on" : "off"',
    ):
        assert token not in form, f"generic/singleton behavior leaked into provider form: {token!r}"


def check_auxiliary_boundary() -> None:
    controller = text("src/web-backend/controller/admin/netbird.lua")
    model = text("src/web-backend/model/netbird.lua")
    require(
        controller,
        'local NATIVE_TYPE = "netbirdvpn"', 'local function requested_profile_key(body, required)',
        'local function native_profile(profile_key)', 'section.key == profile_key and section.type == NATIVE_TYPE',
        'local function native_profile_active(profile_key)', 'local function op_status(body)',
        'local function auth_requires_enrollment(status)',
        'no peer auth method provided',
        'ds == "Connected" and mgmt.connected == true',
        'local function op_restart(body)', 'sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")',
        'local function op_log(body)', 'model.log(profile_key, tonumber(n) or 100)',
        'local function op_payload_status()', 'function dispatch(body)',
    )
    dispatch = controller.split("function dispatch(body)", 1)[1]
    for op in ("enroll", "settings_set", "settings_get", "connected_status", "profile_delete", "clean"):
        assert f'op == "{op}"' not in dispatch, f"auxiliary endpoint shadows stock/provider-save operation {op}"
    assert 'local function op_enroll' not in controller
    assert 'ds == "Connected" or ds == "Connecting" or ds == "Restarting" then patch.enrolled = "1"' not in controller, (
        "connecting/restarting must never be treated as proof of enrollment"
    )
    require(controller, 'local function op_stage_setup_key(body)', 'model.stage_setup_key(setup_key)', 'op == "stage_setup_key"')
    require(model, 'SETUP_STAGE_PREFIX = "/tmp/netbird-setup-stage-"', 'function stage_setup_key(setup_key)',
            'function staged_setup_key_path(token)', 'function discard_staged_setup_key(token)')


    require(
        model,
        'ROOT     = "/tp_data/netbird"', 'PROFILES = ROOT .. "/profiles"',
        'cur.advertise_lan == "1" and cur.disable_client_routes ~= "0"',
        'client routes must be enabled when LAN gateway mode is enabled',
        'cur.advertise_lan == "1" and cur.disable_server_routes ~= "0"',
        'server routes must be enabled when LAN routing is enabled',
        'cur.advertise_lan == "1" and cur.disable_firewall ~= "0"',
        'NetBird firewall must be enabled when LAN routing is enabled',
        'valid_profile_key', 'profile_dir', 'function status(profile_key)', 'function control(op, profile_key, keyfile)',
        'if not valid_profile_key(profile_key) then return nil, "invalid profile key" end',
    )
    assert 'SETTINGS = ROOT .. "/settings"' not in model
    assert 'function connected_status(' not in model
    assert 'function remove_profile_state(' not in model
    identity_fn = model.split("function identity_present(profile_key)", 1)[1].split("\nend", 1)[0]
    assert 'settings.enrolled == "1"' in identity_fn, "Lua identity must use authenticated enrollment metadata"
    assert "default.json" not in identity_fn and "fs.readfile" not in identity_fn, (
        "Lua identity must not infer enrollment from config-file existence"
    )


def check_profile_authority() -> None:
    profiles = text("src/init/netbird-profiles.sh")
    gc_init = text("src/init/netbird-profile-gc.init")
    profile_test = text("scripts/test-netbird-profiles.sh")
    require(
        profiles,
        'NB_ROOT=', 'NB_PROFILES_ROOT=', 'nb_profile_clear_context()', 'nb_profile_key_valid()',
        'nb_enrollment_token_valid()', 'nb_staged_setup_key_path()', 'nb_discard_staged_setup_key()',
        'nb_profile_clear_enrollment_token()',
        'nb_profile_select()', 'nb_profile_identity_present()', '[ "$(nb_get "$NB_SETTINGS_FILE" enrolled "0")" = "1" ]',
        'nb_profile_stock_exists()', 'vpn.@server[$idx].key',
        '[ "$row_key" = "$key" ] && [ "$row_type" = "netbirdvpn" ]',
        'nb_profile_gc_orphans()', 'NB_CONFIG_DIR=""', 'NB_SETTINGS_FILE=""',
        'nb_profile_clear_context',
    )
    require(gc_init, '. /lib/netbird/netbird-profiles.sh', 'nb_profile_gc_orphans')
    gc_code = shell_code(gc_init)
    for token in ('nb_runtime_connect', 'netbird-ctl up', 'service_start', 'uci set'):
        assert token not in gc_code, f"profile GC exceeded maintenance boundary: {token}"

    require(
        profile_test,
        'root-level profile context survived helper load',
        'deleting B damaged A',
        'root-level identity was created',
        'root-level settings were created',
        'root-level state directory was created',
    )


def check_runtime_library() -> None:
    base = text("src/init/netbird.sh")
    runtime = text("src/init/netbird-runtime.sh")
    ctl = text("src/init/netbird-ctl")
    proto = text("src/init/netbird-proto.sh")
    recovery = text("src/init/netbird-recovery")

    require(
        base,
        'NB_CONFIG_DIR=""', 'NB_CONFIG_FILE=""', 'NB_SETTINGS_FILE=""',
        'nb_require_profile_context()', '/tp_data/netbird/profiles/*',
        'NB_BIN="/tmp/netbird"', 'nb_materialize()', 'nb_payload_status()',
        'nb_daemon_start()', 'nb_daemon_stop()', 'nb_fw_access()', 'nb_fw_block()',
        'NB_WG_KERNEL_DISABLED=true', 'NB_FORCE_USERSPACE_FIREWALL=true',
        'NB_FORCE_USERSPACE_ROUTER=true', 'NB_DISABLE_EBPF_WG_PROXY=true',
    )
    require(
        runtime,
        'nb_up_flags()', '"--disable-dns=true"', '"--wireguard-port=${wg_port}"', '"--hostname=${hostname}"', 'nb_runtime_validate_settings()',
        'LAN gateway mode requires client routes to be enabled',
        'LAN routing requires server routes to be enabled', 'LAN routing requires NetBird firewall policy enforcement',
        'NB_FW_STATE="/tmp/netbird-firewall.state"',
        'nb_runtime_connect()', '[ "$rc" -eq 0 ] && [ -n "$keyfile" ]',
        'nb_set "$NB_SETTINGS_FILE" enrolled 1',
        'nb_runtime_disconnect()', 'nb_runtime_stop()', 'nb_runtime_restart()',
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
    require(
        proto,
        '. /lib/netbird/netbird-profiles.sh', 'proto_config_add_string "profile_key"',
        'proto_config_add_string "enrollment_token"', 'nb_profile_select "$profile_key"',
        'nb_staged_setup_key_path "$enrollment_token"', 'nb_profile_identity_present',
        'nb_runtime_connect "$keyfile"', 'nb_discard_staged_setup_key "$enrollment_token"',
        'nb_profile_clear_enrollment_token "$NB_PROFILE_KEY"',
        'nb_runtime_is_connected', 'nb_runtime_stop',
        'if [ "$vpntype" != "netbirdvpn" ]; then', 'add_protocol netbird',
    )
    assert 'netbirdvpn|netbird' not in proto
    assert "/sbin/netbird-ctl" not in shell_code(proto)
    assert "proto_set_available" not in proto

    require(recovery, 'nb_recovery_native_active()', 'nb_profile_select_active', '/etc/init.d/vpnc restart')
    assert 'netbirdvpn|netbird' not in recovery
    assert "nb_runtime_connect" not in shell_code(recovery)


def check_firewall_source() -> None:
    fw = text("src/init/netbird_firewall.inc")
    mod = text("mods/010-netbird.sh")
    require(
        fw,
        '# NetBird v4 CIDR-scoped/applied-state firewall integration.',
        'NetBird owns route authorization. On AX53 that authorization is forced into',
        'fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }',
        'fw_s_add 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }',
        'fw_s_add 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }',
    )
    assert 'fw_s_add 4 f FORWARD ACCEPT 1 {' not in fw
    require(mod, 'FIREWALL_SRC="$RUNTIME_SRC/netbird_firewall.inc"', 'cat "$FIREWALL_SRC" >> "$R/lib/firewall/tpcmd.sh"')


def check_build_gates() -> None:
    mod010 = text("mods/010-netbird.sh")
    mod012 = text("mods/012-netbird-native-vpn.sh")
    makefile = text("Makefile")
    verifier = text("scripts/verify-tplink-vpn-bytecode.py")
    router_validator = text("scripts/validate-netbird-native-router.sh")
    require(
        mod010,
        'is_stock_vpn "$VPN_CONTROLLER"',
        '# NetBird owns its own route table and DNS behavior.',
        'ip route flush table vpn',
        'for forbidden_op in', "'enroll'", "'settings_set'", "'profile_delete'", "'connected_status'", "'settings_get'",
        'stage_setup_key',
    )
    require(
        mod012,
        'python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"',
        'function f(e){return a.request(y,{operation:"connected_status",key:e}',
        'async function W(e,n){await function(e,n,t){return a.update(y,{key:e}',
        'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n}',
        'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
        '"add"===n.type?await Ce(i):await ne(i,n.tableItem)',
        'VpnServerNetbirdForm-NB.js?v=', 'nb_profile_gc_orphans',
        'PROFILE_GC_INIT=', 'netbird-profile-gc',
        "grep -Fq 'table.insert(schema, { key = key })'",
        "if grep -Fq 'field = { key }'",
        'enrollment_token: enrollmentToken.value || ""',
    )
    require(
        verifier,
        '"VPN_TBL"', '"VPN_CFG_TBL"', '"VPN_TYPE_TBL"', '"VPN_TYPE_NAME_TBL"',
        'STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}',
    )
    require(
        makefile,
        'test-netbird:', 'src/init/netbird-profile-gc.init', 'scripts/test-netbird-profiles.sh',
        'scripts/test-netbird-recovery.sh', 'python3 scripts/test-netbird-contracts.py .',
        'python3 scripts/test-netbird-native-frontend.py',
    )
    require(
        router_validator,
        'PROFILE_KEY="$(uci -q get network.vpn.profile_key 2>/dev/null || true)"',
        'PROFILE_SETTINGS="/tp_data/netbird/profiles/$PROFILE_KEY/settings"',
    )
    assert '/tp_data/netbird/settings' not in router_validator, (
        "hardware validator must not use retired singleton settings path"
    )

    # Make recipes are parsed once by make and again by bash -c. Literal shell
    # variables in grep contracts therefore need \\$$ in the Makefile source:
    # make turns $$ into $, leaving \\$ for bash so the variable is not expanded.
    require(
        makefile,
        'nb_staged_setup_key_path \\"\\$$enrollment_token\\"',
        'nb_runtime_connect \\"\\$$keyfile\\"',
        'nb_profile_clear_enrollment_token \\"\\$$NB_PROFILE_KEY\\"',
    )
    for stale in (
        '[$]enrollment_token', '[$]keyfile', '[$]NB_PROFILE_KEY',
        'if (existing && hasIdentity === null)',
        'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
    ):
        assert stale not in makefile + "\n" + mod010 + "\n" + mod012, (
            f"stale/mis-escaped build gate remains: {stale!r}"
        )


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
