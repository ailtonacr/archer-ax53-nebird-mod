#!/usr/bin/env python3
"""Offline contract checks for the AX53 NetBird integration.

Build 3 hardware evidence proved TP-Link's compiled /admin/vpn dispatcher is not
an extensible boundary for NetBird. These checks therefore protect the new
architecture: vendor VPN controller remains stock, NetBird CRUD is explicit on
/admin/netbird, the stock VPN Client page merges the NetBird row itself, and
runtime sources remain canonical under src/init/.
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
NB_CONTROLLER = ROOT / "src/web-backend/controller/admin/netbird.lua"
PATCHER = ROOT / "src/web/patchnetbird_web.py"
MOD = ROOT / "mods/010-netbird.sh"
FORM = ROOT / "src/web/VpnServerNetbirdForm-NB.js"
MAKEFILE = ROOT / "Makefile"


def check_controller():
    controller = NB_CONTROLLER.read_text()

    required = (
        'local SETTINGS = "/tp_data/netbird/settings"',
        "PROFILE_KEYS",
        "bool01",
        "request_settings",
        'elseif op == "settings_set"',
        'elseif op == "profile_delete"',
        "local function op_profile_delete()",
        "nixio.fs.unlink(SETTINGS)",
        "local function identity_present()",
        'lfs.readfile("/tp_data/netbird/default.json")',
        'if identity_present() and settings.enrolled ~= "1"',
    )
    for token in required:
        assert token in controller, f"dedicated controller contract missing {token!r}"

    # Stock-looking form values are on/off or booleans; the model only accepts
    # 0/1, so normalization is a hard boundary requirement.
    assert 'v == "on"' in controller and 'v == "off"' in controller
    assert 'cand.enable = bool01' in controller


def check_frontend_bridge():
    patcher = PATCHER.read_text()

    required = (
        'NB_HELPERS =',
        'operation:"settings_set"',
        'operation:"profile_delete"',
        'DEDICATED_UPDATE =',
        'DEDICATED_DELETE =',
        'DEDICATED_LIST =',
        'DEDICATED_SAVE =',
        'if(b&&b.profileExists)',
        'management_url:s.management_url||""',
        'disable_server_routes:s.disable_server_routes||"1"',
        'it.Netbird===i.type?await Nbs(i)',
        'await nbDelete()',
        'assert_dedicated_crud',
    )
    for token in required:
        assert token in patcher, f"frontend dedicated-CRUD contract missing {token!r}"

    # The abandoned native serializer/adapter path must be actively removed by
    # the patcher rather than silently coexisting with the dedicated route.
    assert 'text = text.replace(R_NATIVE, R_MARKER)' in patcher
    assert 'window.__netbirdSaveDraft' in patcher  # migration token only
    assert 'forbidden = [R_NATIVE, "window.__netbirdSaveDraft"' in patcher


def check_stock_controller_restoration():
    mod = MOD.read_text()

    required = (
        'echo "[2/8] restoring/verifying untouched TP-Link VPN controller ..."',
        'is_stock_vpn()',
        'p.read_bytes()[:4] == b\'\\x1bLua\'',
        'restored stock VPN controller from previous adapter backup',
        'rm -f "$VPN_STOCK" "$LEGACY_VPN_STOCK"',
        'is_stock_vpn "$VPN_CONTROLLER" || { echo "Error: /admin/vpn controller is not original TP-Link bytecode"',
        "grep -q 'profile_delete'",
    )
    for token in required:
        assert token in mod, f"stock-controller restoration contract missing {token!r}"

    assert "VPN_ADAPTER=" not in mod, "retired VPN adapter must not be packaged"
    assert "patch_dispatch_upvalues" not in mod, "dispatcher patching must stay retired"


def check_makefile_build4_verifier():
    makefile = MAKEFILE.read_text()

    required = (
        'VPN controller is not untouched TP-Link bytecode',
        'obsolete preserved vpn_stock.lua remains in rootfs',
        'dedicated NetBird profile delete operation missing',
        'dedicated NetBird settings operation missing',
        'dedicated NetBird API bridge missing from model bundle',
        'NetBird synthetic list bridge missing from VPN page bundle',
        'retired NetBird VPN adapter leaked into stock controller',
        'ok untouched TP-Link VPN controller bytecode',
        'ok dedicated NetBird CRUD/runtime controller',
        '$(MAKE) -C vendor/mtd-utils',
        '$(MAKE) -C vendor/squashfs',
        '$(MAKE) -C vendor/squashfs4',
    )
    for token in required:
        assert token in makefile, f"Build 4 Makefile verifier missing {token!r}"

    forbidden = (
        'NetBird VPN adapter missing from rootfs',
        'hardened NetBird dispatcher adapter missing from rootfs',
        'NetBird request-envelope parser missing from rootfs',
        'preserved stock VPN controller missing outside LuCI controller tree',
        'VPN adapter points at wrong stock-controller path',
        'ok native VPN adapter + dispatcher/request hardening',
        'ok preserved stock VPN controller outside LuCI controller tree',
    )
    for token in forbidden:
        assert token not in makefile, f"retired Build 3 verifier remains in Makefile: {token!r}"


def check_runtime_source_canonicalization():
    mod = MOD.read_text()
    assert 'RUNTIME_SRC="$PROJECT_ROOT/src/init"' in mod
    assert 'cp "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl"' in mod
    assert 'cp "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh"' in mod
    assert 'cp "$RUNTIME_SRC/netbird.init" "$R/etc/init.d/netbird"' in mod

    mirrors = (
        ROOT / "mods/010-netbird-files/sbin/netbird-ctl",
        ROOT / "mods/010-netbird-files/lib/netbird/netbird.sh",
        ROOT / "mods/010-netbird-files/etc/init.d/netbird",
    )
    for mirror in mirrors:
        assert not mirror.exists(), f"stale runtime mirror must remain removed: {mirror}"


def check_form_boundary():
    form = FORM.read_text()
    for token in ("validate", "setForm", "getForm", "resetForm", "clearValidate"):
        assert token in form, f"dynamic-form contract missing {token}"
    assert 'const NB = "/admin/netbird"' in form
    assert 'nbReq("status")' in form
    assert 'nbReq("enroll"' in form
    assert 'nbReq("restart")' in form


def main():
    check_controller()
    check_frontend_bridge()
    check_stock_controller_restoration()
    check_makefile_build4_verifier()
    check_runtime_source_canonicalization()
    check_form_boundary()
    print("netbird dedicated-crud/stock-vpn/reconciliation/build contracts ok")


if __name__ == "__main__":
    main()
