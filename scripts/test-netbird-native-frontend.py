#!/usr/bin/env python3
"""Hermetic offline checks for the native NetBird frontend/finalizer contract.

This test intentionally does not read rootfs/. `make firmware` recreates rootfs
from the selected STOCK image only after the offline test target runs, so using a
mutable repository rootfs here made the gate depend on leftovers from an older
build. Final generated bundles are validated later by the pre-repack checks.
"""
from __future__ import annotations

import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
FORM = ROOT / "src" / "web" / "VpnServerNetbirdForm-NB.js"
PATCHER = ROOT / "src" / "web" / "patchnetbird_native_crud.py"


def main() -> int:
    form = FORM.read_text(encoding="utf-8")
    patcher = PATCHER.read_text(encoding="utf-8")

    required_form = [
        'const creating = ref(true)',
        'const existing = !!(value && (value.key || value.id))',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
        'stockComponent(this, "su-button")',
        's.advertise_lan === "1" && s.disable_server_routes !== "0"',
        'if (key === "advertise_lan" && value === "1") draft.value.disable_server_routes = "0"',
    ]
    for token in required_form:
        assert token in form, f"authored final form missing {token!r}"

    forbidden_form = [
        'value.type === "netbirdvpn"',
        'value.type === "netbird"',
        'const creating = ref(false)',
        "NETBIRD_CSS",
        'type: "checkbox"',
        'class: "netbird-input"',
    ]
    for token in forbidden_form:
        assert token not in form, f"legacy/type-derived form token leaked: {token!r}"

    required_patcher = [
        'e.Netbird="netbirdvpn"',
        'new URL(n).hostname',
        'const existing = !!(value && (value.key || value.id))',
        'const creating = ref(true)',
        'function nbDelete(){return a.request(nb,{operation:"profile_delete"}',
        'DELETE_HELPER =',
        'strip_hybrid_helpers',
        'operation:"settings_set"',
        'function nbSettingsSet(',
    ]
    for token in required_patcher:
        assert token in patcher, f"native finalizer missing {token!r}"

    # settings_set/control helpers may exist only as intermediate strings that
    # the finalizer removes. assert_native must reject them in the final bundle.
    assert "forbidden = [" in patcher
    assert "'operation:\"settings_set\"'" in patcher
    assert "'function nbSettingsSet('" in patcher
    assert "'function nbControl('" in patcher

    subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=form.encode(),
        check=True,
    )

    print("netbird hermetic authored-form/finalizer frontend contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
