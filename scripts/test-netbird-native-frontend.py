#!/usr/bin/env python3
"""Hermetic source checks for the stock-owned NetBird frontend integration.

The firmware may add a NetBird provider and protocol subform, but generic
TP-Link VPN Client behavior must not be replaced. Generated rootfs bundles are
validated again during `make firmware` after mods are applied.
"""
from __future__ import annotations

import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORM = ROOT / "src" / "web" / "VpnServerNetbirdForm-NB.js"
WEB_PATCHER = ROOT / "src" / "web" / "patchnetbird_web.py"
FINALIZER = ROOT / "src" / "web" / "patchnetbird_native_crud.py"
FACTORY_GUARD = ROOT / "src" / "web" / "patchnetbird_factory_semantics.py"


def require(body: str, *tokens: str) -> None:
    for token in tokens:
        assert token in body, f"contract missing {token!r}"


def main() -> int:
    form = FORM.read_text(encoding="utf-8")
    web = WEB_PATCHER.read_text(encoding="utf-8")
    finalizer = FINALIZER.read_text(encoding="utf-8")
    factory = FACTORY_GUARD.read_text(encoding="utf-8")

    require(
        form,
        'const creating = ref(true)',
        'const existing = !!(value && (value.key || value.id))',
        'const profileKey = ref("")',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
        'profile_key: profileKey.value',
        'Permitir roteamento da LAN',
        'Return protocol-specific fields only',
    )
    for token in (
        'value.type === "netbirdvpn"',
        'value.type === "netbird"',
        'const creating = ref(false)',
        'NETBIRD_CSS',
        'type: "checkbox"',
        'class: "netbird-input"',
        'Anunciar rede local',
        'Já existe um perfil NetBird',
        'enable: s.enable === "1" ? "on" : "off"',
    ):
        assert token not in form, f"generic/singleton field leaked into provider form: {token!r}"

    # Initial provider injection is intentionally minimal and verifies the model
    # is stock before doing anything to the page.
    require(
        web,
        'e.Netbird="netbirdvpn"',
        'assert_stock_model_untouched',
        'STOCK_CONNECTED_STATUS',
        'STOCK_UPDATE',
        'STOCK_DELETE',
        'STOCK_LIST',
        'STOCK_SAVE',
        'case it.Netbird:return VpnServerNetbirdForm',
        'VpnServerNetbirdForm-NB.js?v=',
        'hashlib.sha256',
        'generic TP-Link VPN CRUD remains stock',
    )

    # Finalizer may extend only the serializer; it must retain exact stock
    # list/update/delete/status functions and reject the historical bridges.
    require(
        finalizer,
        'NATIVE_SERIALIZER =',
        'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname',
        'STOCK_CONNECTED_STATUS',
        'STOCK_UPDATE',
        'STOCK_DELETE',
        'STOCK_LIST',
        'STOCK_SAVE',
        'VpnServerNetbirdForm-NB.js?v=',
        'key:e.key||"netbird"',
        'function nbSettingsSet(',
        'function nbControl(',
        'function nbDelete(',
    )
    assert 'DELETE_HELPER =' not in finalizer
    assert 'native_delete =' not in finalizer
    assert 'await nbDelete(' not in finalizer

    # The historical factory-semantics mutator is now a pure guard.
    require(
        factory,
        'TP-Link generic VPN list/add/edit/save/toggle/delete/status semantics remain stock',
        'STOCK_CONNECTED_STATUS',
        'STOCK_UPDATE',
        'STOCK_DELETE',
        'STOCK_LIST',
        'STOCK_SAVE',
    )
    assert 'def patch_model()' not in factory
    assert 'def patch_page()' not in factory

    subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=form.encode(),
        check=True,
    )

    print("netbird provider-only frontend/stock-flow source contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
