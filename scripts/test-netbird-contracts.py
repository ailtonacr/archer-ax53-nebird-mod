#!/usr/bin/env python3
"""Offline contract checks for the AX53 NetBird integration."""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
NB_CONTROLLER = ROOT / "src/web-backend/controller/admin/netbird.lua"
NB_MODEL = ROOT / "src/web-backend/model/netbird.lua"
PATCHER = ROOT / "src/web/patchnetbird_web.py"
FACTORY_PATCHER = ROOT / "src/web/patchnetbird_factory_semantics.py"
MOD = ROOT / "mods/010-netbird.sh"
FORM = ROOT / "src/web/VpnServerNetbirdForm-NB.js"
INIT = ROOT / "src/init/netbird.init"
CTL = ROOT / "src/init/netbird-ctl"
MAKEFILE = ROOT / "Makefile"


def require(text: str, *tokens: str) -> None:
    for token in tokens:
        assert token in text, f"contract missing {token!r}"


def check_controller():
    controller = NB_CONTROLLER.read_text()
    require(
        controller,
        'local SETTINGS = "/tp_data/netbird/settings"',
        'description = "scalar"',
        'elseif op == "settings_set"',
        'elseif op == "profile_delete"',
        'local function op_profile_delete()',
        'nixio.fs.unlink(SETTINGS)',
        'nixio.fs.unlink(PROFILE_CONFIG)',
        'lfs.access(PROFILE_STATE)',
        'delete_failed',
        'local function identity_present()',
        'if identity_present() and settings.enrolled ~= "1"',
    )
    assert 'v == "on"' in controller and 'v == "off"' in controller
    assert 'cand.enable = bool01' in controller
    # Enrollment registers the profile but deliberately leaves it disabled; the
    # list toggle is the single place that activates a profile and enforces the
    # same one-active-client invariant as TP-Link factory firmware.
    require(controller, 'model.control("stop")', 'enrolled = "1", enable = "0"')


def check_model():
    model = NB_MODEL.read_text()
    require(
        model,
        'description           = { kind = "text", default = "NetBird" }',
        'local function valid_text',
        'elseif spec.kind == "text"',
    )


def check_frontend_bridge():
    patcher = PATCHER.read_text()
    require(
        patcher,
        'operation:"settings_set"',
        'operation:"profile_delete"',
        'DEDICATED_UPDATE =',
        'DEDICATED_DELETE =',
        'DEDICATED_LIST =',
        'DEDICATED_SAVE =',
        'if(b&&b.profileExists)',
        'it.Netbird===i.type?await Nbs(i)',
        'await nbDelete()',
    )
    assert 'const t=e.enable===!0||e.enable==="on"||e.enable==="1"' in patcher
    assert 'text = text.replace(R_NATIVE, R_MARKER)' in patcher


def check_factory_semantics():
    factory = FACTORY_PATCHER.read_text()
    require(
        factory,
        'only one active profile at a time',
        'globalThis.__nbActiveStockVpn',
        'async function nbDisableStockActive()',
        'async function nbStopIfEnabled()',
        'nbEnabled(e)&&await nbStopIfEnabled()',
        'nbEnabled(e)&&await nbDisableStockActive()',
        'name:s.description||"NetBird"',
        'description:s.description||"NetBird"',
        'field("Descrição"',
        'updateDraft("description"',
        'Informe uma descrição para o perfil.',
        'nbStopIfEnabled as nbG',
    )
    mod = MOD.read_text()
    require(mod, 'FACTORY_PATCHER=', 'python3 "$FACTORY_PATCHER" "$R"')


def check_boot_and_firewall():
    init = INIT.read_text()
    ctl = CTL.read_text()
    require(
        init,
        'SINGLE_ACTIVE_MARKER="/tp_data/netbird/.single-active-v1"',
        'nb_set "$NB_SETTINGS_FILE" enable 0',
        '/sbin/netbird-ctl up',
        'single-active migration disabled existing profile',
    )
    require(
        ctl,
        'nb_fw_prioritize_lan()',
        'iptables -I FORWARD 1 -i wt0 -o "$NB_FW_HOMEIF"',
        'iptables -I FORWARD 2 -i "$NB_FW_HOMEIF" -o wt0',
        'iptables -t nat -I POSTROUTING 1',
        'run up --daemon-addr',
        'nb_fw_access',
        'nb_fw_prioritize_lan',
    )
    # NetBird must create its DROP/chains before our CIDR-scoped exception is
    # inserted above them. This exact ordering is the hardware-proven fix.
    up_block = ctl.split('up)\n', 1)[1].split(';;', 1)[0]
    assert up_block.index('run up --daemon-addr') < up_block.index('nb_fw_access') < up_block.index('nb_fw_prioritize_lan')


def check_stock_controller_restoration():
    mod = MOD.read_text()
    require(
        mod,
        'restoring/verifying untouched TP-Link VPN controller',
        'is_stock_vpn()',
        'rm -f "$VPN_STOCK" "$LEGACY_VPN_STOCK"',
        'profile_delete',
        'profile description persistence missing',
    )
    assert "VPN_ADAPTER=" not in mod
    assert "patch_dispatch_upvalues" not in mod


def check_makefile_verifier():
    makefile = MAKEFILE.read_text()
    require(
        makefile,
        'VPN controller is not untouched TP-Link bytecode',
        'dedicated NetBird profile delete operation missing',
        'dedicated NetBird settings operation missing',
        'ok untouched TP-Link VPN controller bytecode',
        '$(MAKE) -C vendor/mtd-utils',
        '$(MAKE) -C vendor/squashfs',
        '$(MAKE) -C vendor/squashfs4',
    )


def check_runtime_source_canonicalization():
    mod = MOD.read_text()
    require(
        mod,
        'RUNTIME_SRC="$PROJECT_ROOT/src/init"',
        'cp "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl"',
        'cp "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh"',
        'cp "$RUNTIME_SRC/netbird.init" "$R/etc/init.d/netbird"',
    )
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
    require(form, 'const NB = "/admin/netbird"', 'nbReq("status")', 'nbReq("enroll"', 'nbReq("restart")')


def main():
    check_controller()
    check_model()
    check_frontend_bridge()
    check_factory_semantics()
    check_boot_and_firewall()
    check_stock_controller_restoration()
    check_makefile_verifier()
    check_runtime_source_canonicalization()
    check_form_boundary()
    print("netbird factory-single-active/delete/description/firewall contracts ok")


if __name__ == "__main__":
    main()
