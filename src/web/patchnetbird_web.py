#!/usr/bin/env python3
"""Add NetBird as a fifth TP-Link VPN Client provider with minimal patching.

This stage intentionally does NOT replace TP-Link's generic VPN list, ADD/EDIT,
Save, toggle, delete or connected-status paths. It only teaches the stock SPA
about one extra provider:

* enum/value: netbirdvpn
* localized display name: NetBird
* provider selector entry
* dynamic protocol subform mapping
* authored NetBird protocol form module

Provider-specific enrollment/diagnostics remain outside the generic CRUD path.
The final native adapter/serializer is validated by patchnetbird_native_crud.py.

Run: python3 patchnetbird_web.py <rootfs-dir>
"""
from __future__ import annotations

import gzip
import hashlib
import io
import os
import re
import subprocess
import sys

JS = "www/webpages/js"

UPDATE_STORE = [
    (
        'e.Pptp="pptpvpn",e.L2tp="l2tpvpn",e.Wireguard="wireguard",e',
        'e.Pptp="pptpvpn",e.L2tp="l2tpvpn",e.Wireguard="wireguard",e.Netbird="netbirdvpn",e',
        1,
    ),
    (
        'typeWireguard:"WireGuard",typeAuto:"Auto"',
        'typeWireguard:"WireGuard",typeNetbird:"NetBird",typeAuto:"Auto"',
        1,
    ),
]

UTIL = [
    (
        '[t.L2tp,a("vpnClient.typeL2TP")],[t.Wireguard,a("vpnClient.typeWireguard")]',
        '[t.L2tp,a("vpnClient.typeL2TP")],[t.Netbird,a("vpnClient.typeNetbird")],[t.Wireguard,a("vpnClient.typeWireguard")]',
        1,
    ),
]

STOCK_CONNECTED_STATUS = 'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}'
STOCK_UPDATE = 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
STOCK_DELETE = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
STOCK_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
STOCK_SAVE = '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'


def gzip_roundtrip(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def read_js(path: str, is_gzip: bool) -> str:
    data = open(path, "rb").read()
    return gzip.decompress(data).decode("utf-8") if is_gzip else data.decode("utf-8")


def write_js(path: str, is_gzip: bool, text: str) -> None:
    payload = gzip_roundtrip(text.encode("utf-8")) if is_gzip else text.encode("utf-8")
    with open(path, "wb") as fh:
        fh.write(payload)


def check_js(name: str, text: str) -> None:
    result = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode(),
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(f"node --check failed for {name}:\n{result.stderr.decode()[:2000]}")


def patch_text(text: str, patches: list[tuple[str, str, int]], name: str) -> str:
    for old, new, count in patches:
        if new in text:
            continue
        got = text.count(old)
        if got != count:
            raise RuntimeError(f"{name}: expected {count} occurrence(s) of {old!r}, found {got}")
        text = text.replace(old, new, count)
    return text


def apply_file(root: str, rel: str, is_gzip: bool, patches: list[tuple[str, str, int]]) -> None:
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        raise RuntimeError(f"missing {path}")
    text = read_js(path, is_gzip)
    text = patch_text(text, patches, rel)
    check_js(rel, text)
    write_js(path, is_gzip, text)
    print(f"  patched {rel} ({len(text)} bytes)")


def patch_vpn_page(root: str, module_spec: str) -> None:
    rel = f"{JS}/index-DTNtPvwx.js.gz"
    path = os.path.join(root, rel)
    text = read_js(path, True)

    desired_import = f'import{{default as VpnServerNetbirdForm}}from"{module_spec}";'
    existing_import = re.compile(
        r'import\{default as VpnServerNetbirdForm\}from"\./VpnServerNetbirdForm-NB\.js(?:\?v=[0-9a-f]+)?";'
    )
    if existing_import.search(text):
        text = existing_import.sub(desired_import, text, count=1)
    elif desired_import not in text:
        marker = 'import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"'
        if text.count(marker) != 1:
            raise RuntimeError("VPN page: stock update-store import marker not unique")
        text = text.replace(marker, desired_import + marker, 1)

    stock_filter = '.filter((e=>ut.supportVpnClientType(e)))'
    provider_filter = '.filter((e=>e===it.Netbird||ut.supportVpnClientType(e)))'
    if provider_filter not in text:
        if text.count(stock_filter) != 1:
            raise RuntimeError("VPN page: stock provider filter marker not unique")
        text = text.replace(stock_filter, provider_filter, 1)

    stock_switch = 'case it.Wireguard:return en;default:return null'
    provider_switch = 'case it.Wireguard:return en;case it.Netbird:return VpnServerNetbirdForm;default:return null'
    if provider_switch not in text:
        if text.count(stock_switch) != 1:
            raise RuntimeError("VPN page: stock dynamic-form switch marker not unique")
        text = text.replace(stock_switch, provider_switch, 1)

    # This stage must not replace any generic TP-Link CRUD/list logic.
    for token in (STOCK_LIST, STOCK_SAVE):
        if token not in text:
            raise RuntimeError(f"VPN page: stock flow token missing after provider injection: {token}")
    forbidden = (
        'a.value=_nb.concat(e)',
        'it.Netbird===i.type?await Nbs(i)',
        'window.__netbirdSaveDraft',
        '__netbirdSaveListener',
        'stopImmediatePropagation',
    )
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("VPN page contains retired NetBird CRUD interception: " + ", ".join(leaked))

    check_js(rel, text)
    write_js(path, True, text)
    print(f"  patched {rel} ({len(text)} bytes)")


def assert_stock_model_untouched(root: str) -> None:
    rel = f"{JS}/model-CI6Gt3Hz.js.gz"
    text = read_js(os.path.join(root, rel), True)
    required = (STOCK_CONNECTED_STATUS, STOCK_UPDATE, STOCK_DELETE)
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("generic TP-Link VPN model was not stock before native finalization: " + ", ".join(missing))
    forbidden = (
        'const nb="/admin/netbird"',
        'operation:"settings_set"',
        'function nbSettingsSet(',
        'function nbControl(',
        'function nbDelete(',
        'e==="netbird"?a.request("/admin/netbird"',
    )
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("generic TP-Link VPN model contains a retired NetBird bridge: " + ", ".join(leaked))


def apply_locales(root: str) -> None:
    loc = os.path.join(root, "www/webpages/locale")
    patched = 0
    for dirname in sorted(os.listdir(loc)):
        dp = os.path.join(loc, dirname)
        if not os.path.isdir(dp):
            continue
        gz_files = [name for name in os.listdir(dp) if name.endswith(".js.gz")]
        if not gz_files:
            continue
        path = os.path.join(dp, gz_files[0])
        text = gzip.decompress(open(path, "rb").read()).decode("utf-8")
        if "typeNetbird" not in text:
            if text.count('typeWireguard:"') != 1:
                raise RuntimeError(f"{path}: typeWireguard count != 1")
            text = re.sub(r'(typeWireguard:"[^"]*")', r'\1,typeNetbird:"NetBird"', text, count=1)
            check_js(path, text)
            with open(path, "wb") as fh:
                fh.write(gzip_roundtrip(text.encode("utf-8")))
        patched += 1
    print(f"  patched {patched} locale bundles")


def main() -> None:
    root = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
    print(f"Adding native NetBird provider to TP-Link VPN Client bundles under {root} ...")

    source = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VpnServerNetbirdForm-NB.js")
    form = open(source, encoding="utf-8").read()
    check_js("VpnServerNetbirdForm-NB.js", form)
    digest = hashlib.sha256(form.encode("utf-8")).hexdigest()[:12]
    module_spec = f"./VpnServerNetbirdForm-NB.js?v={digest}"

    apply_file(root, f"{JS}/update-store-DQkZxaRI.js.gz", True, UPDATE_STORE)
    apply_file(root, f"{JS}/util-JEiJiY0O.js", False, UTIL)
    assert_stock_model_untouched(root)
    patch_vpn_page(root, module_spec)

    dst = os.path.join(root, JS, "VpnServerNetbirdForm-NB.js.gz")
    with open(dst, "wb") as fh:
        fh.write(gzip_roundtrip(form.encode("utf-8")))
    print(f"  installed VpnServerNetbirdForm-NB.js.gz ({len(form)} bytes; cache key {digest})")

    apply_locales(root)
    print("Frontend provider injection complete: generic TP-Link VPN CRUD remains stock.")


if __name__ == "__main__":
    main()
