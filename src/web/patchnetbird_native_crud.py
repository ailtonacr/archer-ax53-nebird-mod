#!/usr/bin/env python3
"""Finalize NetBird as a native TP-Link VPN Client CRUD type.

The stock base form owns profile identity fields (description/type/vendor/key).
The NetBird subform owns protocol-specific fields only. A saved row is identified
by its persisted key/id; VPN type alone must never be used to distinguish Add
from Edit because both modes legitimately use type=netbirdvpn.
"""
from __future__ import annotations

import gzip
import io
import os
import re
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
JS = os.path.join(ROOT, "www/webpages/js")


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
    p = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
    if p.returncode:
        raise RuntimeError(f"node --check failed for {name}:\n{p.stderr.decode()[:2000]}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)


def patch_update_store() -> None:
    name = "update-store-DQkZxaRI.js.gz"
    text = read_gz(name)
    text = replace_once(text, 'e.Netbird="netbird"', 'e.Netbird="netbirdvpn"', "native NetBird enum")
    check_js(name, text)
    write_gz(name, text)


def patch_model() -> None:
    name = "model-CI6Gt3Hz.js.gz"
    text = read_gz(name)
    dedicated_status = 'function f(e){return e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"},{preventSuccess:!0}):a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
    stock_status = 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
    text = text.replace(dedicated_status, stock_status)

    text, n = re.subn(
        r'async function W\(e,n\)\{if\(e\.type===u\.Netbird\|\|n\.type===u\.Netbird\).*?await function\(e,n,t\)\{return a\.update\(y,\{key:e\},n,t,\{preventSuccess:!0\}\)\}\(e\.key,R\(e\),R\(n\)\)\}',
        'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}',
        text,
        count=1,
    )
    if n != 1 and 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}' not in text:
        raise RuntimeError("native update: dedicated NetBird toggle path not found")

    old_delete = 'async function J(e,n){if(e==="netbird"){await nbDelete();return}await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
    key_delete = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),e==="netbird"&&await nbDelete()}'
    native_delete = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete()}'
    if old_delete in text:
        text = text.replace(old_delete, native_delete, 1)
    elif key_delete in text:
        text = text.replace(key_delete, native_delete, 1)
    elif native_delete not in text:
        stock_delete = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
        if stock_delete in text:
            text = text.replace(stock_delete, native_delete, 1)
        else:
            raise RuntimeError("native delete: stock/dedicated delete path not found")

    native_serializer = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"";try{n=new URL(n).hostname}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"").replace(/:\\d+$/,"")}return{...e,key:e.key||"netbird",type:u.Netbird,server:n,management_url:e.management_url||""};}'
    old_serializer = 'function R(e){if(e&&e.type===u.Netbird){let n=e.management_url||e.server||"";try{n=new URL(n).host}catch(t){n=n.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"")}return{...e,key:e.key||"netbird",type:u.Netbird,server:n,management_url:e.management_url||""};}'
    marker = 'function R(e){'
    if old_serializer in text:
        text = text.replace(old_serializer, native_serializer, 1)
    elif native_serializer not in text:
        if text.count(marker) != 1:
            raise RuntimeError("native serializer: stock R(e) marker not unique")
        text = text.replace(marker, native_serializer, 1)

    check_js(name, text)
    write_gz(name, text)


def patch_page() -> None:
    name = "index-DTNtPvwx.js.gz"
    text = read_gz(name)
    stock_list = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
    if stock_list not in text:
        pattern = re.compile(r'i=async\(\)=>\{const\{data:e,maxRules:t\}=await J\(\);(?:globalThis\.__nbActiveStockVpn=.*?;)?let _nb=\[\];try\{.*?\}catch\(e\)\{\}a\.value=_nb\.concat\(e\),l\.value=t\}')
        text, n = pattern.subn(stock_list, text, count=1)
        if n != 1:
            raise RuntimeError("native list: synthetic NetBird row path not found")

    text = text.replace('it.Netbird===i.type?await Nbs(i):(i&&(i.enable===!0||i.enable==="on"||i.enable==="1"||i.enabled===!0)&&await NbStop(),"add"===n.type?await Ce(i):await ne(i,n.tableItem))', '"add"===n.type?await Ce(i):await ne(i,n.tableItem)')
    text = text.replace('it.Netbird===i.type?await Nbs(i):"add"===n.type?await Ce(i):await ne(i,n.tableItem)', '"add"===n.type?await Ce(i):await ne(i,n.tableItem)')
    text = text.replace('X as ze,nbA as Nbt,nbB as Nbs,nbG as NbStop}from"./model-CI6Gt3Hz.js"', 'X as ze}from"./model-CI6Gt3Hz.js"')
    text = text.replace('X as ze,nbA as Nbt,nbB as Nbs}from"./model-CI6Gt3Hz.js"', 'X as ze}from"./model-CI6Gt3Hz.js"')
    check_js(name, text)
    write_gz(name, text)


def patch_form() -> None:
    name = "VpnServerNetbirdForm-NB.js.gz"
    text = read_gz(name)
    target = 'const existing = !!(value && (value.key || value.id));'
    historical = (
        'const existing = !!(value && (value.type === "netbirdvpn" || value.type === "netbird" || value.key === "netbird" || value.id === "netbird"));',
        'const existing = !!(value && (value.key === "netbird" || value.id === "netbird"));',
    )
    for old in historical:
        text = text.replace(old, target)
    text = text.replace('const creating = ref(false);', 'const creating = ref(true);')
    if target not in text or 'const creating = ref(true);' not in text:
        raise RuntimeError("native form: CREATE/EDIT persisted-key contract not installed")
    check_js(name, text)
    write_gz(name, text)


def assert_native(root: str) -> None:
    update = read_gz("update-store-DQkZxaRI.js.gz")
    model = read_gz("model-CI6Gt3Hz.js.gz")
    page = read_gz("index-DTNtPvwx.js.gz")
    form = read_gz("VpnServerNetbirdForm-NB.js.gz")
    combined = update + "\n" + model + "\n" + page + "\n" + form
    required = [
        'e.Netbird="netbirdvpn"',
        'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}',
        'type:u.Netbird,server:n,management_url:e.management_url||""',
        'new URL(n).hostname',
        'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete()}',
        'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
        'const existing = !!(value && (value.key || value.id))',
        'const creating = ref(true)',
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
    ]
    missing = [x for x in required if x not in combined]
    if missing:
        raise RuntimeError("native NetBird CRUD/form contract incomplete: " + ", ".join(missing))
    forbidden = [
        'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}',
        'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)',
        'if(e==="netbird"){await nbDelete();return}',
        'e==="netbird"&&await nbDelete()',
        'new URL(n).host}',
        'value.type === "netbirdvpn"',
        "netbirdvpn-new",
        "NETBIRD_CSS",
        'type: "checkbox"',
        'class: "netbird-input"',
    ]
    leaked = [x for x in forbidden if x in combined]
    if leaked:
        raise RuntimeError("dedicated/custom NetBird path remains after native migration: " + ", ".join(leaked))


def main() -> None:
    patch_update_store()
    patch_model()
    patch_page()
    patch_form()
    assert_native(ROOT)
    print("Native NetBird finalization complete: stock CRUD/base form + key-based Add/Edit protocol subform")


if __name__ == "__main__":
    main()
