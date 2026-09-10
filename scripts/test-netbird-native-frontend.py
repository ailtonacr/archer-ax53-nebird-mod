#!/usr/bin/env python3
"""Hermetic source checks for the stock-owned NetBird frontend integration.

The firmware adds one provider. TP-Link keeps generic list/ADD/EDIT/Save/toggle,
DELETE and connected-status. NetBird-specific frontend code is limited to
provider discovery, protocol fields, transient setup-key staging and serialization.
"""
from __future__ import annotations

import ast
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


def python_tree(body: str) -> ast.AST:
    return ast.parse(body)


def python_function_names(body: str) -> set[str]:
    return {node.name for node in ast.walk(python_tree(body)) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def python_assignment_string(body: str, name: str) -> str:
    for node in ast.walk(python_tree(body)):
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            value = node.value
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                return value.value
    raise AssertionError(f"python string assignment {name!r} missing")


def python_named_literal_values(body: str, name: str) -> set[str]:
    values: set[str] = set()
    for node in ast.walk(python_tree(body)):
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            continue
        if isinstance(node.value, (ast.Tuple, ast.List, ast.Set)):
            for item in node.value.elts:
                if isinstance(item, ast.Constant) and isinstance(item.value, str):
                    values.add(item.value)
    return values


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
        'stockComponent(this, "su-form")', 'stockComponent(this, "su-form-item")', 'stockComponent(this, "su-input")',
        'stockComponent(this, "su-password")', 'stockComponent(this, "su-checkbox")',
        'enrollment_token: enrollmentToken.value || ""', 'stage_setup_key',
        'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
        '_h(SuForm, { model: s }, { default: () => items })',
        'Permitir roteamento da LAN',
    )
    for token in (
        '"label-width": { span: 10 }', '"content-width": { span: 14 }', 'async function enroll()', 'async function afterStockSave()',
        'value.type === "netbirdvpn"', 'value.type === "netbird"', 'const creating = ref(false)',
        'NETBIRD_CSS', 'type: "checkbox"', 'class: "netbird-input"', 'Anunciar rede local',
        'Já existe um perfil NetBird', 'enable: s.enable === "1" ? "on" : "off"', 'setup_key: setupKey.value',
    ):
        assert token not in form, f"generic/singleton field leaked into provider form: {token!r}"

    require(
        web,
        'e.Netbird="netbirdvpn"', 'assert_stock_model_untouched',
        'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE', 'STOCK_LIST', 'STOCK_SAVE',
        'case it.Netbird:return VpnServerNetbirdForm', 'VpnServerNetbirdForm-NB.js?v=',
        'hashlib.sha256', 'patch_vpn_page(root, module_spec)',
    )

    require(
        finalizer,
        'NATIVE_SERIALIZER =', 'k=e.key||t()', 'key:k,des:e.description,type:e.type,enable:i(e.enable),server:n,profile_key:k',
        'management_url:e.management_url||""', 'enrollment_token:e.enrollment_token||""',
        'new URL(n).hostname', 'STOCK_CONNECTED_STATUS', 'STOCK_UPDATE', 'STOCK_DELETE',
        'STOCK_LIST', 'STOCK_SAVE', 'text = text.replace(marker, NATIVE_SERIALIZER, 1)',
        'def patch_model_import_cache_key() -> None:',
        'hashlib.sha256(model.encode("utf-8")).hexdigest()[:12]',
        'model-CI6Gt3Hz.js?v=',
    )

    guarded_tokens = {
        'key:e.key||"netbird"', 'function nbSettingsSet(', 'function nbControl(',
        'function nbDelete(', 'operation:"profile_delete"', 'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)', 'window.__netbirdSaveDraft',
        '__netbirdSaveListener', 'stopImmediatePropagation',
        'async function afterStockSave()', 'async function enroll()', 'setup_key:e.setup_key',
    }
    guard_literals = python_named_literal_values(finalizer, "forbidden")
    missing_guards = guarded_tokens - guard_literals
    assert not missing_guards, f"finalizer guard list missing retired tokens: {sorted(missing_guards)!r}"

    serializer = python_assignment_string(finalizer, "NATIVE_SERIALIZER")
    leaked_serializer = [token for token in guarded_tokens if token in serializer]
    assert not leaked_serializer, f"retired bridge leaked into injected serializer: {leaked_serializer!r}"

    finalizer_functions = python_function_names(finalizer)
    assert "patch_page" not in finalizer_functions
    assert "afterStockSave" not in finalizer_functions and "nbDelete" not in finalizer_functions

    factory_functions = python_function_names(factory)
    assert "patch_model" not in factory_functions
    assert "patch_page" not in factory_functions

    subprocess.run(["node", "--input-type=module", "--check"], input=form.encode(), check=True)
    print("netbird provider-only frontend with stock Save + staged setup key ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
