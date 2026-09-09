#!/usr/bin/env python3
"""Fail-fast guard that NetBird did not replace TP-Link VPN Client semantics.

Historical revisions of this stage rewrote generic toggle/save/list behavior to
special-case NetBird. That is intentionally retired. The native architecture
keeps TP-Link as the owner of generic profile semantics and this stage now only
verifies that those stock paths are still present after provider injection.
"""
from __future__ import annotations

import gzip
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
JS = os.path.join(ROOT, "www/webpages/js")

STOCK_CONNECTED_STATUS = 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
STOCK_UPDATE = 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
STOCK_DELETE = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
STOCK_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
STOCK_SAVE = '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'


def read_gz(name: str) -> str:
    with gzip.open(os.path.join(JS, name), "rt", encoding="utf-8") as fh:
        return fh.read()


def check_js(name: str, text: str) -> None:
    result = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode(),
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(f"node --check failed for {name}:\n{result.stderr.decode()[:2000]}")


def main() -> None:
    model = read_gz("model-CI6Gt3Hz.js.gz")
    page = read_gz("index-DTNtPvwx.js.gz")
    form = read_gz("VpnServerNetbirdForm-NB.js.gz")

    required_model = (STOCK_CONNECTED_STATUS, STOCK_UPDATE, STOCK_DELETE)
    missing_model = [token for token in required_model if token not in model]
    if missing_model:
        raise RuntimeError("TP-Link generic VPN model was intercepted: " + ", ".join(missing_model))

    required_page = (STOCK_LIST, STOCK_SAVE)
    missing_page = [token for token in required_page if token not in page]
    if missing_page:
        raise RuntimeError("TP-Link generic VPN page flow was intercepted: " + ", ".join(missing_page))

    forbidden = (
        'a.value=_nb.concat(e)',
        'operation:"settings_set"',
        'function nbSettingsSet(',
        'function nbControl(',
        'function nbDelete(',
        'it.Netbird===i.type?await Nbs(i)',
        'window.__netbirdSaveDraft',
        '__netbirdSaveListener',
        'stopImmediatePropagation',
        '__nbActiveStockVpn',
    )
    combined = model + "\n" + page
    leaked = [token for token in forbidden if token in combined]
    if leaked:
        raise RuntimeError("retired NetBird generic-flow interception remains: " + ", ".join(leaked))

    required_form = (
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
        'const creating = ref(true)',
        'const existing = !!(value && (value.key || value.id))',
        'Permitir roteamento da LAN',
    )
    missing_form = [token for token in required_form if token not in form]
    if missing_form:
        raise RuntimeError("native NetBird provider form contract incomplete: " + ", ".join(missing_form))

    check_js("model-CI6Gt3Hz.js.gz", model)
    check_js("index-DTNtPvwx.js.gz", page)
    check_js("VpnServerNetbirdForm-NB.js.gz", form)
    print("TP-Link generic VPN list/add/edit/save/toggle/delete/status semantics remain stock")


if __name__ == "__main__":
    main()
