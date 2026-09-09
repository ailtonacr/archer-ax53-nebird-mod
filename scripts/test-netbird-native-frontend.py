#!/usr/bin/env python3
"""Hermetic source checks for the stock-owned NetBird frontend integration.

The firmware adds one provider. TP-Link keeps generic list/ADD/EDIT/Save/toggle
and connected-status. DELETE keeps its exact stock remove call and may append
only the provider credential cleanup required after that stock remove succeeds.
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
        'value.type === "netbirdvpn"', 'value.type === "netbird"', 'const creating = ref(false)',
        'NETBIRD_CSS', 'type: "checkbox"', 'class: "netbird-input"', 'Anunciar rede local',
        'Já existe um perfil NetBird', 'enable: s.enable === "1" ? "on" : "off"',
    ):
        assert token not in form, f"generic/singleton field leaked into provider form: {token!r}"

    # Initial injection touches provider discovery/rendering only and requires the
    # generic model to still be stock at that stage.
    require(
        web,
        'e.Netbird="netbirdvpn"', 'assert_stock_model_untouched',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
        'case it.Netbird:return VpnServerNetbirdForm', 'VpnServerNetbirdForm-NB.js?v=',
        'hashlib.sha256', 'generic TP-Link VPN CRUD remains stock',
    )

    # Finalizer adds provider serialization plus exactly one post-stock-delete
    # credential cleanup hook. The stock remove expression must remain intact and
    # occur before nbDelete().
    require(
        finalizer,
        'NATIVE_SERIALIZER =', 'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname', 'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE',
        'PROVIDER_DELETE =', 'DELETE_HELPER =', 'STOCK_LIST', 'STOCK_SAVE',
        'VpnServerNetbirdForm-NB.js?v=', 'key:e.key||"netbird"',
        'function nbSettingsSet(', 'function nbControl(',
        'a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete(e)',
        'operation:"profile_delete",profile_key:e',
    )
    assert finalizer.index('a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete(e)') \
        < finalizer.index('required = (STOCK_CONNECTED_STATUS'), "post-delete contract must be installed before validation"
    assert 'native_delete =' not in finalizer
    assert 'a.value=_nb.concat(e)' not in finalizer

    # The historical factory-semantics stage is now a pure pre-finalizer guard,
    # not a mutator of generic TP-Link behavior.
    require(
        factory,
        'TP-Link generic VPN list/add/edit/save/toggle/delete/status semantics remain stock',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
    )
    assert 'def patch_model()' not in factory
    assert 'def patch_page()' not in factory

    subprocess.run(["node", "--input-type=module", "--check"], input=form.encode(), check=True)

    print("netbird provider-only frontend + post-stock-delete cleanup contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
