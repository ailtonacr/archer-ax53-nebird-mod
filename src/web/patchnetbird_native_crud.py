#!/usr/bin/env python3
"""Finalize NetBird as a native TP-Link VPN Client provider.

TP-Link remains the owner of every generic VPN Client operation it already
implements: list, ADD, EDIT, Save/Cancel, toggle, DELETE and connected-status.
This stage adds only provider serialization. The transient setup_key travels in
the normal stock Save payload and is consumed by the backend provider callback;
it is never part of VPN_TBL/UCI persistence.
"""
from __future__ import annotations

import gzip
import io
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

# Stock serializers use the vendor key generator t() as `key:e.key||t()`.
# NetBird follows exactly that convention and mirrors the generated key into
# profile_key for provider-scoped runtime state. setup_key is copied explicitly
# so the stock request always carries the transient enrollment input; the
# backend provider callback consumes it but never returns/persists that field.
NATIVE_SERIALIZER = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"",k=e.key||t();try{n=new URL(n).hostname}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"").replace(/:\\d+$/,"")}return{...e,key:k,profile_key:k,type:u.Netbird,server:n,management_url:e.management_url||"",setup_key:e.setup_key||""};}'


def read_gz(name: str) -> str:
    with gzip.open(os.path.join(JS, name), "rt", encoding="utf-8") as fh:
        return fh.read()


def write_gz(name: str, text: str) -> None:
    path = os.path.join(JS, name)
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode("utf-8"))
    with open(path, "wb") as fh:
        fh.write(buf.getvalue())


def check_js(name: str, text: str) -> None:
    result = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode(),
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(f"node --check failed for {name}:\n{result.stderr.decode()[:2000]}")


def patch_update_store() -> None:
    name = "update-store-DQkZxaRI.js.gz"
    text = read_gz(name)
    if 'e.Netbird="netbirdvpn"' not in text:
        raise RuntimeError("native NetBird enum netbirdvpn is missing")
    check_js(name, text)
    write_gz(name, text)


def patch_model() -> None:
    name = "model-CI6Gt3Hz.js.gz"
    text = read_gz(name)
    for token in (STOCK_CONNECTED_STATUS, STOCK_UPDATE, STOCK_DELETE):
        if token not in text:
            raise RuntimeError("TP-Link generic VPN model flow changed before NetBird finalization: " + token)
    if NATIVE_SERIALIZER in text:
        raise RuntimeError("NetBird serializer already present; expected clean stock model input")

    marker = 'function R(e){'
    if text.count(marker) != 1:
        raise RuntimeError("native serializer: stock R(e) marker not unique")
    text = text.replace(marker, NATIVE_SERIALIZER, 1)

    required = (STOCK_CONNECTED_STATUS, STOCK_UPDATE, STOCK_DELETE, NATIVE_SERIALIZER)
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("final native provider model incomplete: " + ", ".join(missing))

    forbidden = (
        'const nb="/admin/netbird"', 'function nbStatus(', 'function nbSettingsSet(',
        'function nbControl(', 'function nbDelete(', 'operation:"settings_set"',
        'operation:"profile_delete"', 'e==="netbird"?a.request("/admin/netbird"',
        'key:e.key||"netbird"',
    )
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("custom NetBird bridge leaked into generic TP-Link model: " + ", ".join(leaked))

    check_js(name, text)
    write_gz(name, text)


def assert_page_and_form() -> None:
    page = read_gz("index-DTNtPvwx.js.gz")
    form = read_gz("VpnServerNetbirdForm-NB.js.gz")

    for token in (STOCK_LIST, STOCK_SAVE):
        if token not in page:
            raise RuntimeError("TP-Link generic VPN page flow changed: " + token)

    required_page = (
        'e===it.Netbird||ut.supportVpnClientType(e)',
        'case it.Netbird:return VpnServerNetbirdForm',
        'VpnServerNetbirdForm-NB.js?v=',
    )
    missing_page = [token for token in required_page if token not in page]
    if missing_page:
        raise RuntimeError("NetBird provider injection incomplete: " + ", ".join(missing_page))

    required_form = (
        'const existing = !!(value && (value.key || value.id))',
        'const creating = ref(true)',
        'const profileKey = ref("")',
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-password")',
        'stockComponent(this, "su-checkbox")',
        'setup_key: setupKey.value || ""',
        'Setup Key',
        'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
        'Permitir roteamento da LAN',
        'return _h(SuSpin, { spinning: this.busy }, { default: () => items })',
    )
    missing_form = [token for token in required_form if token not in form]
    if missing_form:
        raise RuntimeError("native NetBird form contract incomplete: " + ", ".join(missing_form))

    combined = page + "\n" + form
    forbidden = (
        'a.value=_nb.concat(e)', 'it.Netbird===i.type?await Nbs(i)',
        'window.__netbirdSaveDraft', '__netbirdSaveListener', 'stopImmediatePropagation',
        'Já existe um perfil NetBird', 'value.type === "netbirdvpn"',
        '"label-width": { span: 10 }', 'stockComponent(this, "su-form")',
        'async function afterStockSave()', 'async function enroll()',
    )
    leaked = [token for token in forbidden if token in combined]
    if leaked:
        raise RuntimeError("non-stock/singleton NetBird frontend path remains: " + ", ".join(leaked))

    check_js("index-DTNtPvwx.js.gz", page)
    check_js("VpnServerNetbirdForm-NB.js.gz", form)


def main() -> None:
    patch_update_store()
    patch_model()
    assert_page_and_form()
    print("Native NetBird finalized: stock CRUD + one-step transient setup-key enrollment")


if __name__ == "__main__":
    main()
