#!/usr/bin/env python3
"""Hermetic source checks for the stock-owned NetBird frontend integration.

The firmware adds one provider. TP-Link keeps generic list/ADD/EDIT/Save/toggle,
DELETE and connected-status. NetBird-specific frontend code is limited to
provider discovery, protocol fields, transient setup_key and serialization.
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
        'stockComponent(this, "su-form-item")', 'stockComponent(this, "su-input")',
        'stockComponent(this, "su-password")', 'stockComponent(this, "su-checkbox")',
        'setup_key: setupKey.value || ""',
        'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
        'return _h(SuSpin, { spinning: this.busy }, { default: () => items })',
        'Permitir roteamento da LAN',
    )
    for token in (
        'stockComponent(this, "su-form")', 'async function enroll()', 'async function afterStockSave()',
        'value.type === "netbirdvpn"', 'value.type === "netbird"', 'const creating = ref(false)',
        'NETBIRD_CSS', 'type: "checkbox"', 'class: "netbird-input"', 'Anunciar rede local',
        'Já existe um perfil NetBird', 'enable: s.enable === "1" ? "on" : "off"',
    ):
        assert token not in form, f"generic/singleton field leaked into provider form: {token!r}"

    require(
        web,
        'e.Netbird="netbirdvpn"', 'assert_stock_model_untouched',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
        'case it.Netbird:return VpnServerNetbirdForm', 'VpnServerNetbirdForm-NB.js?v=',
        'hashlib.sha256', 'generic TP-Link VPN CRUD remains stock',
    )

    require(
        finalizer,
        'NATIVE_SERIALIZER =', 'k=e.key||t()', 'key:k,profile_key:k',
        'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname', 'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE',
        'STOCK_LIST', 'STOCK_SAVE', 'expected clean stock model input',
        'setup_key travels in', 'backend provider callback',
    )

    for guarded in (
        'key:e.key||"netbird"', 'function nbSettingsSet(', 'function nbControl(',
        'function nbDelete(', 'operation:"profile_delete"', 'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)', 'window.__netbirdSaveDraft',
        '__netbirdSaveListener', 'stopImmediatePropagation',
    ):
        assert finalizer.count(guarded) == 1, f"forbidden frontend token escaped guard-only usage: {guarded!r}"

    for token in ('PROVIDER_DELETE =', 'DELETE_HELPER =', 'await nbDelete('):
        assert token not in finalizer, f"non-stock frontend bridge leaked into finalizer: {token!r}"

    # afterStockSave is intentionally named once inside the finalizer's forbidden
    # token list so the generated page/form is rejected if that retired bridge
    # ever reappears. It must not exist as executable finalizer logic.
    assert finalizer.count('afterStockSave') == 1, \
        "afterStockSave escaped guard-only usage in finalizer"
    assert 'async function afterStockSave()' not in form

    require(
        factory,
        'TP-Link generic VPN list/add/edit/save/toggle/delete/status semantics remain stock',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
    )
    assert 'def patch_model()' not in factory
    assert 'def patch_page()' not in factory

    subprocess.run(["node", "--input-type=module", "--check"], input=form.encode(), check=True)
    print("netbird provider-only frontend with stock Save + transient setup key ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
