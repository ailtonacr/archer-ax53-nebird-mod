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
FORM_STATE_PATCHER = ROOT / "src/web/patchnetbird_form_state.py"
NATIVE_CONTRACT_PATCHER = ROOT / "src/web/patchnetbird_native_contract.py"
NATIVE_SAVE_COMPAT = ROOT / "src/web/patchnetbird_native_save.py"
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
        'hostname = "scalar"',
        'wireguard_port = "scalar"',
        'elseif op == "settings_set"',
        'elseif op == "profile_delete"',
        'elseif op == "connected_status"',
        'local function op_connected_status()',
        'return reply(model.connected_status())',
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
    require(controller, 'model.control("stop")', 'enrolled = "1", enable = "0"')


def check_model():
    model = NB_MODEL.read_text()
    require(
        model,
        'SETTINGS = "/tp_data/netbird/settings"',
        'description           = { kind = "text", default = "NetBird" }',
        'hostname              = { kind = "name", default = "" }',
        'wireguard_port        = { kind = "int",  default = "51820" }',
        'local function valid_text',
        'local function valid_name',
        'elseif spec.kind == "text"',
        'elseif spec.kind == "name"',
        'elseif spec.kind == "int"',
        'local function management_host(url)',
        'function connected_status()',
        'ping -c 1 -W 1',
        'address = host',
        'dns = ""',
    )
    assert '/profiles/' not in model


def check_frontend_bridge():
    patcher = PATCHER.read_text()
    require(
        patcher,
        'operation:"settings_set"',
        'operation:"profile_delete"',
        'STOCK_CONNECTED_STATUS =',
        'NATIVE_CONNECTED_STATUS =',
        'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}',
        'a.request(y,{operation:"connected_status",key:e}',
        'DEDICATED_UPDATE =',
        'DEDICATED_DELETE =',
        'DEDICATED_LIST =',
        'DEDICATED_SAVE =',
        'if(b&&b.profileExists)',
        'it.Netbird===i.type?await Nbs(i)',
        'await nbDelete()',
        'hostname:s.hostname||""',
        'wireguard_port:s.wireguard_port||"51820"',
    )
    assert 'const t=e.enable===!0||e.enable==="on"||e.enable==="1"' in patcher
    assert 'text = text.replace(R_NATIVE, R_MARKER)' in patcher
    assert 'text = text.replace(STOCK_CONNECTED_STATUS, NATIVE_CONNECTED_STATUS)' in patcher


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
        'field("Hostname do peer"',
        'field("Porta WireGuard"',
        'updateDraft("hostname"',
        'updateDraft("wireguard_port"',
        'function validHostname(value)',
        'function validWireGuardPort(value)',
        'Hostname inválido.',
        'Informe uma porta WireGuard entre 1 e 65535.',
        'nbStopIfEnabled as nbG',
        'def replace_one_of(',
        'old_stock_compact = \'name: "NetBird", des: "NetBird", description: "NetBird",\'',
        'old_stock_multiline = \'name: "NetBird",\\n    des: "NetBird",\\n    description: "NetBird",\'',
        'e.enable===!0||e.enable==="on"||e.enable==="1"||e.enabled===!0',
        'old_fields = \'\'\'const serverFields = [field("URL de gerenciamento"',
    )
    form = FORM.read_text()
    require(
        form,
        'const serverFields = [field("URL de gerenciamento", _h("input", {',
        'hostname: v.hostname !== undefined',
        'wireguard_port: v.wireguard_port !== undefined',
    )


def check_singleton_add_semantics():
    state = FORM_STATE_PATCHER.read_text()
    require(
        state,
        'const creating = ref(false)',
        'creating.value && profileExists.value',
        'Esta versão suporta um único perfil NetBird.',
        'Já existe um perfil NetBird neste roteador.',
        'draft.value.enrolled = "0"',
        'draft.value.enable = "0"',
        'creating.value ? {} : (settings.value || {})',
    )
    mod = MOD.read_text()
    require(
        mod,
        'FORM_STATE_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_form_state.py"',
        'python3 "$FORM_STATE_PATCHER" "$R"',
    )


def check_native_form_contract():
    native = NATIVE_CONTRACT_PATCHER.read_text()
    compat = NATIVE_SAVE_COMPAT.read_text()
    require(
        native,
        'baseFormRef.isChanged || subFormRef.isChanged',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'throw new Error(error.value)',
        'The stock base form owns description/type',
        'legacy Save interception leaked',
        'syncNativeSaveButton',
        'netbirdSaveSyncTimer',
        'data-netbird-dirty',
        'stopImmediatePropagation',
    )
    require(
        compat,
        'strategy is retired',
        'patchnetbird_native_contract.py',
    )
    assert 'addEventListener' not in compat
    assert 'stopImmediatePropagation' not in compat

    mod = MOD.read_text()
    require(
        mod,
        'NetBird subform does not expose TP-Link native isChanged contract',
        'NetBird validate() does not reject invalid state like stock forms',
        'legacy NetBird Save interception leaked into final form',
    )

    makefile = MAKEFILE.read_text()
    require(
        makefile,
        'native TP-Link NetBird isChanged contract missing',
        'legacy NetBird Save interception remains in rootfs',
        'ok native TP-Link form dirty/save contract',
    )


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
        'wg_port="$(nb_get "$NB_SETTINGS_FILE" wireguard_port "$NB_DEFAULT_PORT")"',
        '"--wireguard-port=${wg_port}"',
        'description\\|enable\\|enrolled\\|management_url\\|hostname',
    )
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
        'dedicated NetBird connected-status operation missing',
        'native NetBird connected-status model bridge missing',
        'ok native TP-Link connected-status tooltip contract',
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
    require(
        form,
        'const NB = "/admin/netbird"',
        'nbReq("status")',
        'nbReq("enroll"',
        'nbReq("restart")',
        'hostname: v.hostname !== undefined',
        'wireguard_port: v.wireguard_port !== undefined',
    )


def main():
    check_controller()
    check_model()
    check_frontend_bridge()
    check_factory_semantics()
    check_singleton_add_semantics()
    check_native_form_contract()
    check_boot_and_firewall()
    check_stock_controller_restoration()
    check_makefile_verifier()
    check_runtime_source_canonicalization()
    check_form_boundary()
    print("netbird factory-single-active/delete/native-form/connected-status/singleton-add/hostname/port/firewall contracts ok")


if __name__ == "__main__":
    main()
