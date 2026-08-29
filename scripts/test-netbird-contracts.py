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
    require(
        native,
        'TYPE = "netbirdvpn"', 'TYPE_ID = "5"', 'TYPE_NAME = "NetBird"', 'PROTO = "netbird"',
        'local vpn = require "luci.controller.admin.vpn"',
        'local schema = { proto = PROTO }', 'table.insert(schema, { key = key })',
        'vpn.VPN_TBL[TYPE] = schema', 'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID', 'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'local function value_or_current(cfg, current, key, fallback)',
        'if connect == nil then',
        'if not server or server == "" then server = management_host(updated.management_url) end',
    )
    assert "field = FIELDS" not in native
    assert "debug.getupvalue" not in native and "debug.setupvalue" not in native
    require(loader, 'require "luci.model.netbird_vpn_native"', 'native.install()')


def check_auxiliary_boundary() -> None:
    controller = text("src/web-backend/controller/admin/netbird.lua")
    require(
        controller,
        'local NATIVE_TYPE = "netbirdvpn"',
        'local function native_profile()', 'uci:foreach("vpn", "server", function(section)',
        'local function native_profile_active()',
        'local function sync_settings_from_native_profile()',
        'local expected_enable = active and "1" or "0"',
        'patch.enable = expected_enable',
        'local synced, sync_err = sync_settings_from_native_profile()',
        'local out, rc = model.control("enroll", tmp)',
        'if native_profile_exists() then', 'result = "skipped"',
        'local clean_out, clean_rc = model.control("clean")',
        'sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")',
        'elseif op == "restart" then return op_restart()',
    )
    reconcile = between(controller, "local function reconcile_runtime", "local function read_number")
    assert 'patch.enable = "1"' not in reconcile, "daemon status must not resurrect native enable state"
    delete_block = between(controller, "local function op_profile_delete()", "local function op_enroll")
    assert 'model.control("stop")' not in delete_block, "delete cleanup must not materialize payload through stop"
    assert delete_block.index("native_profile_exists()") < delete_block.index('model.control("clean")')
    restart_block = between(controller, "local function op_restart()", "local function op_clean")
    assert 'model.control("restart")' not in restart_block


def check_runtime_library() -> None:
    base = text("src/init/netbird.sh")
    runtime = text("src/init/netbird-runtime.sh")
    require(base, 'NB_BIN="/tmp/netbird"', 'NB_CONFIG_DIR="/tp_data/netbird"', 'nb_materialize()', 'nb_payload_status()')
    require(
        runtime,
        'nb_up_flags()', '"--wireguard-port=${wg_port}"',
        'nb_daemon_ping()', 'nb_status_json()', 'nb_runtime_is_connected()',
        'management="$(printf', 'grep -q \'"connected":true\'',
        'nb_runtime_connect()', 'nb_runtime_disconnect()', 'nb_runtime_stop()', 'nb_runtime_restart()',
        'nb_runtime_apply_firewall()', 'nb_runtime_remove_firewall()',
        'nb_enroll()', 'nb_runtime_connect "$keyfile"',
        'nb_clean()', 'nb_set "$NB_SETTINGS_FILE" enable 0',
    )
    assert "/sbin/netbird-ctl" not in runtime, "shared runtime must never depend on controller facade"
    connect = between(runtime, "nb_runtime_connect()", "nb_runtime_disconnect()")
    assert connect.count('"$NB_BIN" up') == 2, "connect has exactly key/no-key command branches"
    assert connect.count("$(nb_up_flags)") == 2, "all connect branches use the one canonical flag builder"
    disconnect = between(runtime, "nb_runtime_disconnect()", "nb_runtime_stop()")
    assert "nb_materialize" not in disconnect, "disconnect/cleanup must never download payload"


def check_ctl_is_facade() -> None:
    ctl = text("src/init/netbird-ctl")
    require(
        ctl,
        '. /lib/netbird/netbird-runtime.sh',
        'nb_daemon_ping', 'nb_runtime_connect "$keyfile"', 'nb_runtime_disconnect',
        'nb_runtime_stop', 'nb_runtime_restart', 'nb_clean', 'nb_status_json',
    )
    forbidden_impl = ["iptables -I", "service_start", "service_stop", "nb_runtime_up_flags()", '"$NB_BIN" up']
    for token in forbidden_impl:
        assert token not in ctl, f"netbird-ctl must remain a facade, found {token!r}"


def check_netifd_owner() -> None:
    proto = text("src/init/netbird-proto.sh")
    require(
        proto,
        '. /lib/netbird/netbird.sh', '. /lib/netbird/netbird-runtime.sh',
        'proto_netbird_init_config()', 'proto_netbird_setup()', 'proto_netbird_teardown()',
        'NB_IFNAME="wt0"', 'nb_runtime_connect', 'nb_runtime_is_connected', 'nb_runtime_stop',
        'proto_init_update "$NB_IFNAME" 1 1', 'proto_send_update "$config"', 'add_protocol netbird',
    )
    assert "/sbin/netbird-ctl" not in proto, "netifd must call shared runtime directly"
    assert 'grep -q \'"connected"' not in proto, "connected-state parsing belongs in shared runtime"


def check_compat_init() -> None:
    init = text("src/init/netbird.init")
    require(
        init,
        'netbird_native_active()',
        '/etc/init.d/vpnc restart', '/etc/init.d/vpnc stop',
        'nb_runtime_stop', 'not the active native VPN Client profile',
    )
    assert "/sbin/netbird-ctl up" not in init
    assert "/sbin/netbird-ctl stop" not in init


def check_build_pipeline() -> None:
    mod = text("mods/012-netbird-native-vpn.sh")
    verifier = text("scripts/verify-tplink-vpn-bytecode.py")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    require(
        mod,
        'NATIVE_RUNTIME="$PROJECT_ROOT/src/init/netbird-runtime.sh"',
        'cp "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"',
        'cmp -s "$NATIVE_RUNTIME" "$R/lib/netbird/netbird-runtime.sh"',
        'if grep -q \'/sbin/netbird-ctl\' "$R/lib/netifd/proto/netbird.sh"',
        'rm -f "$R/etc/rc.d/S99netbird"',
        'if [ "$vpntype" != "netbirdvpn" ]; then',
        'python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"',
    )
    require(
        verifier,
        'EXPECTED_HEADER = bytes.fromhex("1b4c75615100010404040804")',
        'OP_SETGLOBAL = 2', '"VPN_TBL"', '"VPN_CFG_TBL"', '"VPN_TYPE_TBL"', '"VPN_TYPE_NAME_TBL"',
        'STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}',
    )
    require(
        finalizer,
        'e.Netbird="netbirdvpn"', 'new URL(n).hostname',
        'native_delete =', 'await nbDelete()', 'value.type === "netbirdvpn"',
        'stock_list =', '/admin/vpn?form=server',
    )
    assert 'e==="netbird"&&await nbDelete()' not in finalizer


def check_frontend_source_vs_final_contract() -> None:
    source_test = text("src/web/VpnServerNetbirdForm-NB.test.mjs")
    integration = text("scripts/test-netbird-native-frontend.py")
    require(source_test, 'type: "netbird"')
    require(
        integration,
        'patchnetbird_native_crud.py',
        'e.Netbird="netbirdvpn"', 'type: "netbirdvpn", proto: "netbird"',
        'value.type === "netbirdvpn"',
        'a.value=_nb.concat(e)', 'new URL(n).hostname',
        'await nbDelete()',
    )


def check_no_forbidden_ci_changes() -> None:
    workflows = ROOT / ".github" / "workflows"
    if workflows.exists():
        bodies = [
            text("mods/012-netbird-native-vpn.sh"), text("src/init/netbird-runtime.sh"),
            text("scripts/test-netbird-contracts.py"),
        ]
        assert all(".github/workflows" not in body for body in bodies)


def main() -> None:
    check_native_registry()
    check_auxiliary_boundary()
    check_runtime_library()
    check_ctl_is_facade()
    check_netifd_owner()
    check_compat_init()
    check_build_pipeline()
    check_frontend_source_vs_final_contract()
    check_no_forbidden_ci_changes()
    print("netbird native TP-Link VPN end-to-end structural contracts ok")


if __name__ == "__main__":
    main()
