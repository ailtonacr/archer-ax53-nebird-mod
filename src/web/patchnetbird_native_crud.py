#!/usr/bin/env python3
"""Finalize NetBird as a native TP-Link VPN Client provider.

TP-Link remains the owner of generic list, ADD, EDIT, Save/Cancel, toggle and
connected-status. DELETE also executes TP-Link's stock remove first; only after
that succeeds we run the one provider-specific post-hook the stock firmware
cannot know about: removal of the corresponding NetBird identity/credentials.

No synthetic row, fixed key, custom Save bridge or alternate CRUD path is
permitted here.
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
PROVIDER_DELETE = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete(e)}'
STOCK_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
STOCK_SAVE = '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
DELETE_HELPER = 'const nb="/admin/netbird";function nbDelete(e){return a.request(nb,{operation:"profile_delete",profile_key:e},{preventSuccess:!0,preventError:!0})}'

NATIVE_SERIALIZER = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"";try{n=new URL(n).hostname}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"").replace(/:\\d+$/,"")}return{...e,type:u.Netbird,server:n,management_url:e.management_url||""};}'
SYNTHETIC_KEY_SERIALIZER = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"";try{n=new URL(n).hostname}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"").replace(/:\\d+$/,"")}return{...e,key:e.key||"netbird",type:u.Netbird,server:n,management_url:e.management_url||""};}'
OLD_HOST_SERIALIZER = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"";try{n=new URL(n).host}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"")}return{...e,key:e.key||"netbird",type:u.Netbird,server:n,management_url:e.management_url||""};}'


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
    text = text.replace('e.Netbird="netbird"', 'e.Netbird="netbirdvpn"')
    if 'e.Netbird="netbirdvpn"' not in text:
        raise RuntimeError("native NetBird enum netbirdvpn is missing")
    check_js(name, text)
    write_gz(name, text)


def patch_model() -> None:
    name = "model-CI6Gt3Hz.js.gz"
    text = read_gz(name)

    # Before the provider post-hook is installed, every generic function must
    # still be exactly the stock implementation.
    for token in (STOCK_CONNECTED_STATUS, STOCK_UPDATE):
        if token not in text:
            raise RuntimeError("TP-Link generic VPN model flow changed before NetBird finalization: " + token)
    if STOCK_DELETE not in text and PROVIDER_DELETE not in text:
        raise RuntimeError("TP-Link stock DELETE body is not present")

    # Provider-specific serialization only; TP-Link still allocates/owns keys.
    if SYNTHETIC_KEY_SERIALIZER in text:
        text = text.replace(SYNTHETIC_KEY_SERIALIZER, NATIVE_SERIALIZER, 1)
    elif OLD_HOST_SERIALIZER in text:
        text = text.replace(OLD_HOST_SERIALIZER, NATIVE_SERIALIZER, 1)
    elif NATIVE_SERIALIZER not in text:
        marker = 'function R(e){'
        if text.count(marker) != 1:
            raise RuntimeError("native serializer: stock R(e) marker not unique")
        text = text.replace(marker, NATIVE_SERIALIZER, 1)

    # Keep the stock remove call byte-for-byte and append only provider identity
    # cleanup after it succeeds. This is not an alternate delete implementation.
    if PROVIDER_DELETE not in text:
        text = text.replace(STOCK_DELETE, PROVIDER_DELETE, 1)
    if DELETE_HELPER not in text:
        marker = 'export{_ as A'
        if text.count(marker) != 1:
            raise RuntimeError("model export marker not unique for provider cleanup helper")
        text = text.replace(marker, DELETE_HELPER + marker, 1)

    required = (STOCK_CONNECTED_STATUS, STOCK_UPDATE, PROVIDER_DELETE, DELETE_HELPER)
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("final native provider model incomplete: " + ", ".join(missing))

    # No custom list/save/toggle/status path and no fixed profile identity.
    forbidden = (
        'function nbStatus(',
        'function nbSettingsSet(',
        'function nbControl(',
        'operation:"settings_set"',
        'e==="netbird"?a.request("/admin/netbird"',
        'key:e.key||"netbird"',
    )
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("custom NetBird bridge leaked into generic TP-Link model: " + ", ".join(leaked))
    if text.count('const nb="/admin/netbird"') != 1 or text.count('operation:"profile_delete"') != 1:
        raise RuntimeError("provider cleanup must be the only /admin/netbird helper in the generic model")

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
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
        'profile_key: profileKey.value',
        'Permitir roteamento da LAN',
    )
    missing_form = [token for token in required_form if token not in form]
    if missing_form:
        raise RuntimeError("native NetBird form contract incomplete: " + ", ".join(missing_form))

    combined = page + "\n" + form
    forbidden = (
        'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)',
        'window.__netbirdSaveDraft',
        '__netbirdSaveListener',
        'stopImmediatePropagation',
        'Já existe um perfil NetBird',
        'value.type === "netbirdvpn"',
        '"label-width": { span: 10 }',
    )
    leaked = [token for token in forbidden if token in combined]
    if leaked:
        raise RuntimeError("singleton/hybrid NetBird frontend path remains: " + ", ".join(leaked))

    check_js("index-DTNtPvwx.js.gz", page)
    check_js("VpnServerNetbirdForm-NB.js.gz", form)


def main() -> None:
    patch_update_store()
    patch_model()
    assert_page_and_form()
    print("Native NetBird finalized: TP-Link CRUD retained; provider adds serializer + post-delete identity cleanup only")


if __name__ == "__main__":
    main()
