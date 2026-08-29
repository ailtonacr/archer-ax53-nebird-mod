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
        'vpn.VPN_TBL[TYPE] = schema',
        'vpn.VPN_CFG_TBL[TYPE] = netbird_config',
        'vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID',
        'vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME',
        'proto = PROTO',
        'connectable = cfg.connect or "1"',
        'nb_model.set_settings(settings)',
    )
    require(loader, 'require "luci.model.netbird_vpn_native"', 'native.install()')
    assert "debug.getupvalue" not in native
    assert "debug.setupvalue" not in native


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
        "expected stock TP-Link Lua bytecode",
        'native.install()',
        'e.Netbird=\\"netbirdvpn\\"',
        'synthetic NetBird list bridge still present',
    )
    require(
        finalizer,
        'e.Netbird="netbirdvpn"',
        'stock_status =',
        'native_serializer =',
        'stock_list =',
        'dedicated CRUD bridge remains after native migration',
        '/admin/vpn?form=server',
    )
    require(
        makefile,
        'python3 -m py_compile src/web/patchnetbird_native_crud.py',
        'native NetBird VPN type registration missing',
        'native NetBird VPN type id is not 5',
        'VPN_TYPE_TBL NetBird registration missing',
        'VPN_TYPE_NAME_TBL NetBird registration missing',
        'VPN_TBL NetBird schema registration missing',
        'stock list/add/modify/toggle/delete/connected-status path',
        'cmp -s src/init/netbird-proto.sh rootfs/lib/netifd/proto/netbird.sh',
    )


def check_frontend_transition() -> None:
    # 010 still builds the previously hardware-tested hybrid UI first. 012 is a
    # deterministic finalizer that removes only the CRUD/list/status bridges.
    # /admin/netbird remains intentionally available for enrollment/log/payload
    # and other NetBird-specific actions that do not belong to generic VPN CRUD.
    hybrid = text("src/web/patchnetbird_web.py")
    finalizer = text("src/web/patchnetbird_native_crud.py")
    form = text("src/web/VpnServerNetbirdForm-NB.js")
    require(hybrid, 'Netbird="netbird"', 'DEDICATED_LIST', 'DEDICATED_SAVE')
    require(finalizer, 'Netbird="netbirdvpn"', 'a.value=_nb.concat(e)', 'it.Netbird===i.type?await Nbs(i)')
    require(form, 'const NB = "/admin/netbird"', 'nbReq("enroll"', 'nbReq("restart")', 'nbReq("log"')


def check_no_forbidden_ci_changes() -> None:
    # Repository policy: native firmware work must not depend on GitHub Actions.
    workflows = ROOT / ".github" / "workflows"
    if workflows.exists():
        # Existing vendor/project workflows may exist historically; this test
        # merely ensures the native NetBird build itself never references them.
        native_files = [
            text("mods/012-netbird-native-vpn.sh"),
            text("src/web/patchnetbird_native_crud.py"),
            text("src/web-backend/model/netbird_vpn_native.lua"),
        ]
        assert all(".github/workflows" not in body for body in native_files)


def main() -> None:
    check_native_registry()
    check_netifd()
    check_runtime_preserved()
    check_build_pipeline()
    check_frontend_transition()
    check_no_forbidden_ci_changes()
    print("netbird native TP-Link VPN registry/CRUD/netifd/build contracts ok")


if __name__ == "__main__":
    main()
