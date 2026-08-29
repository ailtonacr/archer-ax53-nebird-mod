#!/usr/bin/env python3
"""Offline contract checks for the AX53 native NetBird VPN integration."""
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


def check_native_registry() -> None:
    native = text("src/web-backend/model/netbird_vpn_native.lua")
    loader = text("src/web-backend/controller/admin/netbird_native.lua")
    require(
        native,
        'TYPE = "netbirdvpn"',
        'TYPE_ID = "5"',
        'TYPE_NAME = "NetBird"',
        'PROTO = "netbird"',
        'local vpn = require "luci.controller.admin.vpn"',
        'local schema = { proto = PROTO }',
        'table.insert(schema, { key = key })',
        'vpn.VPN_TBL[TYPE] = schema',
        'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID',
        'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'local function management_host(url)',
        'local function value_or_current(cfg, current, key, fallback)',
        'nb_model.get_settings',
        'if connect == nil then',
        'if not server or server == "" then server = management_host(updated.management_url) end',
        'server = server',
        'connectable = cfg.connect or "1"',
        'nb_model.set_settings(settings)',
    )
    assert "field = FIELDS" not in native, "non-stock VPN_TBL schema shape leaked into native registry"
    require(loader, 'require "luci.model.netbird_vpn_native"', 'native.install()')
    assert "debug.getupvalue" not in native
    assert "debug.setupvalue" not in native


def check_auxiliary_native_boundary() -> None:
    controller = text("src/web-backend/controller/admin/netbird.lua")
    require(
        controller,
        'local uci    = require("luci.model.uci").cursor()',
        'local NATIVE_TYPE = "netbirdvpn"',
        'local function native_profile()',
        'uci:foreach("vpn", "server", function(section)',
        'if section.type == NATIVE_TYPE then',
        'local function native_profile_exists()',
        'local function sync_settings_from_native_profile()',
        'profileExists = native_profile_exists()',
        'local synced, sync_err = sync_settings_from_native_profile()',
        'local out, rc = model.control("enroll", tmp)',
        'local clean_out, clean_rc = model.control("clean")',
        'profileExists = native_profile_exists()',
    )
    delete_block = controller.split('local function op_profile_delete()', 1)[1].split('local function op_enroll', 1)[0]
    assert 'model.control("stop")' not in delete_block, "native post-delete cleanup must not materialize payload via explicit stop"


def check_netifd() -> None:
    proto = text("src/init/netbird-proto.sh")
    require(
        proto,
        'proto_netbird_init_config()',
        'proto_netbird_setup()',
        'proto_netbird_teardown()',
        'NB_IFNAME="wt0"',
        'netbird_runtime_connected()',
        'proto_init_update "$NB_IFNAME" 1 1',
        'proto_send_update "$config"',
        'add_protocol netbird',
        'netbird|netbirdvpn',
    )


def check_runtime_preserved() -> None:
    runtime = text("src/init/netbird.sh")
    ctl = text("src/init/netbird-ctl")
    require(
        runtime,
        'NB_BIN="/tmp/netbird"',
        'NB_CONFIG_DIR="/tp_data/netbird"',
        'NB_PAYLOAD_XZ_SHA256=',
        'NB_EXPECTED_SHA256=',
        'nb_materialize()',
        'nb_payload_status()',
        'nb_payload_verify()',
    )
    require(
        ctl,
        'nb_fw_prioritize_lan()',
        'iptables -I FORWARD 1 -i wt0',
        'run up --daemon-addr',
        '"--wireguard-port=${wg_port}"',
    )


def check_build_pipeline() -> None:
    mod010 = text("mods/010-netbird.sh")
    mod012 = text("mods/012-netbird-native-vpn.sh")
    makefile = text("Makefile")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    verifier = text("scripts/verify-tplink-vpn-bytecode.py")

    require(
        mod010,
        'netbird-proto.sh',
        '$R/lib/netifd/proto/netbird.sh',
        'restoring/verifying untouched TP-Link VPN controller',
    )
    require(
        mod012,
        'netbird_vpn_native.lua',
        'netbird_native.lua',
        'patchnetbird_native_crud.py',
        'verify-tplink-vpn-bytecode.py',
        'python3 "$BYTECODE_VERIFIER" "$VPN_CONTROLLER"',
        'local schema = { proto = PROTO }',
        'table.insert(schema, { key = key })',
        'native.install()',
        'e.Netbird=\\"netbirdvpn\\"',
        'new URL(n).hostname',
        'synthetic NetBird list bridge still present',
        'rm -f "$R/etc/rc.d/S99netbird"',
        'if [ "$vpntype" != "netbirdvpn" ]; then',
        'fw vpnc_access_accel_handle $vpntype',
        'fw vpnc_accelskip_add $vpntype',
        'stock vpn_core acceleration block not found exactly once',
    )
    require(
        finalizer,
        'e.Netbird="netbirdvpn"',
        'stock_status =',
        'native_serializer =',
        'new URL(n).hostname',
        'native_delete =',
        'e==="netbird"&&await nbDelete()',
        'stock_list =',
        'dedicated CRUD bridge remains after native migration',
        '/admin/vpn?form=server',
    )
    require(
        verifier,
        'EXPECTED_HEADER = bytes.fromhex("1b4c75615100010404040804")',
        'OP_SETGLOBAL = 2',
        '"VPN_TBL"',
        '"VPN_CFG_TBL"',
        '"VPN_TYPE_TBL"',
        '"VPN_TYPE_NAME_TBL"',
        'STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}',
        'native NetBird cannot safely extend this vpn.lua',
    )
    require(
        makefile,
        'python3 -m py_compile src/web/patchnetbird_native_crud.py scripts/verify-tplink-vpn-bytecode.py',
        'python3 scripts/verify-tplink-vpn-bytecode.py rootfs/usr/lib/lua/luci/controller/admin/vpn.lua',
        'native NetBird VPN type registration missing',
        'native NetBird VPN type id is not 5',
        'VPN_TYPE_TBL NetBird registration missing',
        'VPN_TYPE_NAME_TBL NetBird registration missing',
        'VPN_TBL NetBird schema registration missing',
        'stock list/add/modify/toggle/delete/connected-status path',
        'cmp -s src/init/netbird-proto.sh rootfs/lib/netifd/proto/netbird.sh',
        'standalone NetBird boot lifecycle still enabled',
    )


def check_frontend_transition() -> None:
    # 010 still builds the previously hardware-tested hybrid UI first. 012 is a
    # deterministic finalizer that removes normal CRUD/list/status bridges.
    # /admin/netbird remains for enrollment/log/payload and post-delete identity
    # cleanup that cannot be represented by generic TP-Link VPN CRUD.
    hybrid = text("src/web/patchnetbird_web.py")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    form = text("src/web/VpnServerNetbirdForm-NB.js")
    require(hybrid, 'Netbird="netbird"', 'DEDICATED_LIST', 'DEDICATED_SAVE')
    require(finalizer, 'Netbird="netbirdvpn"', 'a.value=_nb.concat(e)', 'it.Netbird===i.type?await Nbs(i)')
    require(form, 'const NB = "/admin/netbird"', 'nbReq("enroll"', 'nbReq("restart")', 'nbReq("log"')


def check_no_forbidden_ci_changes() -> None:
    workflows = ROOT / ".github" / "workflows"
    if workflows.exists():
        native_files = [
            text("mods/012-netbird-native-vpn.sh"),
            text("src/web/patchnetbird_native_crud.py"),
            text("src/web-backend/model/netbird_vpn_native.lua"),
            text("scripts/verify-tplink-vpn-bytecode.py"),
        ]
        assert all(".github/workflows" not in body for body in native_files)


def main() -> None:
    check_native_registry()
    check_auxiliary_native_boundary()
    check_netifd()
    check_runtime_preserved()
    check_build_pipeline()
    check_frontend_transition()
    check_no_forbidden_ci_changes()
    print("netbird native TP-Link VPN registry/CRUD/netifd/build/runtime-boundary contracts ok")


if __name__ == "__main__":
    main()
