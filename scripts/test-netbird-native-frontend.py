#!/usr/bin/env python3
"""Hermetic source checks for the stock-owned NetBird frontend integration.

The firmware adds one provider. TP-Link keeps generic list/ADD/EDIT/Save/toggle,
DELETE and connected-status. NetBird-specific frontend code is limited to
provider discovery, its protocol subform and field serialization.
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

    # Finalizer may add only the provider serializer. Generic TP-Link operations
    # remain exact stock functions, including DELETE.
    require(
        finalizer,
        'NATIVE_SERIALIZER =', 'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname', 'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE',
        'STOCK_LIST', 'STOCK_SAVE',
        'Generic operations must still be byte-for-byte stock at this boundary.',
        'expected clean stock model input',
        'leaked = [token for token in forbidden if token in text]',
        'leaked = [token for token in forbidden if token in combined]',
    )

    # Retired bridge strings intentionally occur in the finalizer only as
    # forbidden-token guards. They must occur exactly once there; a second
    # occurrence would mean the old implementation escaped back into executable
    # patching logic.
    for guarded in (
        'key:e.key||"netbird"',
        'function nbSettingsSet(',
        'function nbControl(',
        'function nbDelete(',
        'operation:"profile_delete"',
        'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)',
        'window.__netbirdSaveDraft',
        '__netbirdSaveListener',
        'stopImmediatePropagation',
    ):
        assert finalizer.count(guarded) == 1, f"forbidden frontend token escaped guard-only usage: {guarded!r}"

    # These names have no legitimate guard-only helper definition and therefore
    # must not occur at all.
    for token in ('PROVIDER_DELETE =', 'DELETE_HELPER =', 'await nbDelete('):
        assert token not in finalizer, f"non-stock frontend bridge leaked into finalizer: {token!r}"

    # Factory-semantics stage is a pure guard, not a mutator.
    require(
        factory,
        'TP-Link generic VPN list/add/edit/save/toggle/delete/status semantics remain stock',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
    )
    assert 'def patch_model()' not in factory
    assert 'def patch_page()' not in factory

    subprocess.run(["node", "--input-type=module", "--check"], input=form.encode(), check=True)

    print("netbird provider-only frontend with fully stock generic VPN flow ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
