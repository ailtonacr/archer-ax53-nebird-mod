#!/usr/bin/env python3
"""Offline structural contracts for the AX53 native NetBird integration."""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    p = ROOT / path
    assert p.is_file(), f"missing required file: {path}"
    return p.read_text(encoding="utf-8")


def require(body: str, *tokens: str) -> None:
    for token in tokens:
        assert token in body, f"contract missing {token!r}"


def between(body: str, start: str, end: str) -> str:
    assert start in body and end in body, f"unable to isolate {start!r}..{end!r}"
    return body.split(start, 1)[1].split(end, 1)[0]


def check_native_registry() -> None:
    native = text("src/web-backend/model/netbird_vpn_native.lua")
    loader = text("src/web-backend/controller/admin/netbird_native.lua")
    require(native,
        'TYPE = "netbirdvpn"', 'TYPE_ID = "5"', 'TYPE_NAME = "NetBird"', 'PROTO = "netbird"',
        'local vpn = require "luci.controller.admin.vpn"',
        'local schema = { proto = PROTO }', 'table.insert(schema, { key = key })',
        'vpn.VPN_TBL[TYPE] = schema', 'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID', 'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'local function value_or_current(cfg, current, key, fallback)', 'if connect == nil then',
        'if not server or server == "" then server = management_host(updated.management_url) end')
    assert "field = FIELDS" not in native
    assert "debug.getupvalue" not in native and "debug.setupvalue" not in native
    require(loader, 'require "luci.model.netbird_vpn_native"', 'native.install()')


def check_auxiliary_boundary() -> None:
    controller = text("src/web-backend/controller/admin/netbird.lua")
    require(controller,
        'local NATIVE_TYPE = "netbirdvpn"', 'local function native_profile()',
        'uci:foreach("vpn", "server", function(section)', 'local function native_profile_active()',
        'local expected_enable = active and "1" or "0"', 'patch.enable = expected_enable',
        'local synced, sync_err = sync_settings_from_native_profile()',
        'local out, rc = model.control("enroll", tmp)',
        'if native_profile_exists() then', 'result = "skipped"',
        'local clean_out, clean_rc = model.control("clean")',
        'sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")')
    reconcile = between(controller, "local function reconcile_runtime", "local function read_number")
    assert 'patch.enable = "1"' not in reconcile
    delete_block = between(controller, "local function op_profile_delete()", "local function op_enroll")
    assert delete_block.index("native_profile_exists()") < delete_block.index('model.control("clean")')
    assert 'model.control("stop")' not in delete_block
    restart_block = between(controller, "local function op_restart()", "local function op_clean")
    assert 'model.control("restart")' not in restart_block


def check_runtime_library() -> None:
    base = text("src/init/netbird.sh")
    runtime = text("src/init/netbird-runtime.sh")
    require(base,
        'NB_BIN="/tmp/netbird"', 'NB_CONFIG_DIR="/tp_data/netbird"',
        'nb_materialize()', 'nb_payload_status()', 'nb_daemon_start()', 'nb_daemon_stop()',
        'nb_fw_access()', 'nb_fw_block()')
    for token in ["/sbin/netbird-ctl", "nb_up_flags()", "nb_start()", "nb_stop()", "nb_enroll()", "nb_clean()"]:
        assert token not in base, f"base library leaked lifecycle/controller implementation: {token}"
    require(runtime,
        'nb_up_flags()', '"--wireguard-port=${wg_port}"', 'nb_daemon_ping()', 'nb_status_json()',
        'nb_runtime_is_connected()', 'management="$(printf', 'grep -q \'"connected":true\'',
        'nb_runtime_connect()', 'nb_runtime_disconnect()', 'nb_runtime_stop()', 'nb_runtime_restart()',
        'nb_runtime_apply_firewall()', 'nb_runtime_remove_firewall()', 'nb_enroll()',
        'nb_runtime_connect "$keyfile"', 'nb_clean()', 'nb_set "$NB_SETTINGS_FILE" enable 0')
    assert "/sbin/netbird-ctl" not in runtime
    connect = between(runtime, "nb_runtime_connect()", "nb_runtime_disconnect()")
    assert connect.count('"$NB_BIN" up') == 2
    assert connect.count("$(nb_up_flags)") == 2
    disconnect = between(runtime, "nb_runtime_disconnect()", "nb_runtime_stop()")
    assert "nb_materialize" not in disconnect


def check_ctl_is_facade() -> None:
    ctl = text("src/init/netbird-ctl")
    require(ctl, '. /lib/netbird/netbird-runtime.sh', 'nb_daemon_ping', 'nb_runtime_connect "$keyfile"',
            'nb_runtime_disconnect', 'nb_runtime_stop', 'nb_runtime_restart', 'nb_clean', 'nb_status_json')
    for token in ["iptables -I", "service_start", "service_stop", "nb_runtime_up_flags()", '"$NB_BIN" up']:
        assert token not in ctl, f"netbird-ctl must remain a facade, found {token!r}"


def check_netifd_owner() -> None:
    proto = text("src/init/netbird-proto.sh")
    require(proto, '. /lib/netbird/netbird.sh', '. /lib/netbird/netbird-runtime.sh',
            'proto_netbird_init_config()', 'proto_netbird_setup()', 'proto_netbird_teardown()',
            'NB_IFNAME="wt0"', 'nb_runtime_connect', 'nb_runtime_is_connected', 'nb_runtime_stop',
            'proto_init_update "$NB_IFNAME" 1 1', 'proto_send_update "$config"', 'add_protocol netbird',
            'proto_notify_error "$config"', 'proto_setup_failed "$config"')
    assert "/sbin/netbird-ctl" not in proto
    assert 'grep -q \'"connected"' not in proto
    assert "proto_set_available" not in proto, "transient connection failure must not disable protocol availability"


def check_compat_init() -> None:
    init = text("src/init/netbird.init")
    require(init, 'netbird_native_active()', '/etc/init.d/vpnc restart', '/etc/init.d/vpnc stop',
            'nb_runtime_stop', 'not the active native VPN Client profile')
    assert "/sbin/netbird-ctl up" not in init and "/sbin/netbird-ctl stop" not in init


def check_build_pipeline() -> None:
    mod = text("mods/012-netbird-native-vpn.sh")
    verifier = text("scripts/verify-tplink-vpn-bytecode.py")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    require(mod,
        'NATIVE_RUNTIME="$PROJECT_ROOT/src/init/netbird-runtime.sh"',
        'cp "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"',
        'cmp -s "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"',
        'if grep -q \'/sbin/netbird-ctl\' "$R/lib/netifd/proto/netbird.sh"',
        'rm -f "$R/etc/rc.d/S99netbird"', 'if [ "$vpntype" != "netbirdvpn" ]; then',
        'python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"',
        'const existing = !!(value && (value.key || value.id))',
        'const creating = ref(true)')
    require(verifier,
        'EXPECTED_HEADER = bytes.fromhex("1b4c75615100010404040804")', 'OP_SETGLOBAL = 2',
        '"VPN_TBL"', '"VPN_CFG_TBL"', '"VPN_TYPE_TBL"', '"VPN_TYPE_NAME_TBL"',
        'STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}')
    require(finalizer,
        'e.Netbird="netbirdvpn"', 'new URL(n).hostname', 'native_delete =', 'await nbDelete()',
        'const existing = !!(value && (value.key || value.id))', 'const creating = ref(true)',
        'stock_list =', '/admin/vpn?form=server')
    assert 'e==="netbird"&&await nbDelete()' not in finalizer
    assert 'value.type === "netbirdvpn"' not in finalizer


def check_frontend_tests_are_final_artifact_aligned() -> None:
    source_test = text("src/web/VpnServerNetbirdForm-NB.test.mjs")
    integration = text("scripts/test-netbird-native-frontend.py")
    require(source_test,
        'key: "arbitrary-stock-key", type: "netbirdvpn"',
        'protocol subform must not own TP-Link profile key',
        'protocol subform must not own TP-Link profile type',
        'scripts/test-netbird-native-frontend.py')
    assert "netbirdvpn-new" not in source_test
    require(integration,
        'patchnetbird_native_crud.py', 'e.Netbird="netbirdvpn"',
        'const existing = !!(value && (value.key || value.id))', 'const creating = ref(true)',
        'a.value=_nb.concat(e)', 'new URL(n).hostname', 'await nbDelete()',
        'stockComponent(this, "su-form")')
    assert 'value.type === "netbirdvpn"' in integration  # forbidden-regression assertion
    assert '"netbirdvpn-new"' in integration  # forbidden-regression assertion


def check_no_forbidden_ci_changes() -> None:
    workflows = ROOT / ".github" / "workflows"
    if workflows.exists():
        bodies = [text("mods/012-netbird-native-vpn.sh"), text("src/init/netbird-runtime.sh"), text("scripts/test-netbird-contracts.py")]
        assert all(".github/workflows" not in body for body in bodies)


def main() -> None:
    check_native_registry()
    check_auxiliary_boundary()
    check_runtime_library()
    check_ctl_is_facade()
    check_netifd_owner()
    check_compat_init()
    check_build_pipeline()
    check_frontend_tests_are_final_artifact_aligned()
    check_no_forbidden_ci_changes()
    print("netbird native TP-Link VPN end-to-end structural contracts ok")


if __name__ == "__main__":
    main()
