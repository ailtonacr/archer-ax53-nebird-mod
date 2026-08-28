#!/usr/bin/env python3
"""Offline frontend bundle patcher for native NetBird VPN Client integration.

NetBird is presented as a real VPN Client type, but CRUD stays on TP-Link's
native /admin/vpn?form=server flow.  The dedicated /admin/netbird endpoint is
used only by the custom form for NetBird-specific runtime/diagnostic actions
(status, enrollment and logs).

The patcher also removes the older synthetic-row/CRUD-bypass implementation
when rebuilding an already patched rootfs.

Run:  python3 patchnetbird_web.py <rootfs-dir>
"""
import gzip
import io
import os
import re
import subprocess
import sys

JS = "www/webpages/js"

UPDATE_STORE = [
    ('e.Pptp="pptpvpn",e.L2tp="l2tpvpn",e.Wireguard="wireguard",e',
     'e.Pptp="pptpvpn",e.L2tp="l2tpvpn",e.Wireguard="wireguard",e.Netbird="netbird",e', 1),
    ('typeWireguard:"WireGuard",typeAuto:"Auto"',
     'typeWireguard:"WireGuard",typeNetbird:"NetBird",typeAuto:"Auto"', 1),
]

UTIL = [
    ('[t.L2tp,a("vpnClient.typeL2TP")],[t.Wireguard,a("vpnClient.typeWireguard")]',
     '[t.L2tp,a("vpnClient.typeL2TP")],[t.Netbird,a("vpnClient.typeNetbird")],[t.Wireguard,a("vpnClient.typeWireguard")]', 1),
]

# ---------------------------------------------------------------------------
# Migration away from the old parallel CRUD route.
# ---------------------------------------------------------------------------
STOCK_UPDATE = 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
LEGACY_UPDATE = 'async function W(e,n){if(e.type===u.Netbird||n.type===u.Netbird){await nbControl(n.enable?"start":"stop");return}await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
STOCK_DELETE = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
LEGACY_DELETE = 'async function J(e,n){if(e==="netbird"){await nbControl("clean");return}await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'
LEGACY_NB_EXPORT_PREFIX = 'const nb="/admin/netbird";function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}function nbSettingsSet(e){return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}function nbEnroll(e,t){return a.request(nb,{operation:"enroll",setup_key:e,management_url:t},{preventSuccess:!0,preventError:!0})}function nbControl(e){return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbLog(e){return a.request(nb,{operation:"log",lines:e},{preventSuccess:!0,preventError:!0})}'

STOCK_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'
LEGACY_LIST_CURRENT = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")){let _server=b.settings.management_url||"";try{_server=new URL(_server).host}catch(e){_server=_server.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"")}const _tr=b.traffic||{};_nb=[{key:"netbird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:b.settings.enable==="1",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:_server,uploadSpeed:Number(_tr.uploadSpeed)||0,downloadSpeed:Number(_tr.downloadSpeed)||0}]}}catch(e){}a.value=_nb.concat(e),l.value=t}'
LEGACY_LIST_OLD = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting"))_nb=[{key:"netbird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:b.settings.enable==="1",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:b.netbird.netbirdIp||b.settings.management_url||"",uploadSpeed:"",downloadSpeed:""}]}catch(e){}a.value=_nb.concat(e),l.value=t}'

STOCK_SAVE = '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
LEGACY_SAVE = 'it.Netbird===i.type?window.__netbirdSaveDraft?await window.__netbirdSaveDraft():(()=>{throw new Error("NetBird form unavailable")})():"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
LEGACY_SAVE_SKIP = 'it.Netbird!==i.type&&("add"===n.type?await Ce(i):await ne(i,n.tableItem))'


def migrate_model(text):
    text = text.replace(LEGACY_UPDATE, STOCK_UPDATE)
    text = text.replace(LEGACY_DELETE, STOCK_DELETE)
    text = text.replace(LEGACY_NB_EXPORT_PREFIX + 'export{_ as A', 'export{_ as A')
    text = text.replace('j as z,nbStatus as nbA,nbSettingsSet as nbB,nbEnroll as nbC,nbControl as nbD,nbLog as nbE};', 'j as z};')
    return text


def migrate_vpn_page(text):
    # Remove imports used only by the synthetic /admin/netbird CRUD bridge.
    text = text.replace(
        'X as ze,nbA as Nbt,nbB as Nbs,nbC as Nbe,nbD as Nbc,nbE as Nbl}from"./model-CI6Gt3Hz.js"',
        'X as ze}from"./model-CI6Gt3Hz.js"',
    )

    for legacy in (LEGACY_LIST_CURRENT, LEGACY_LIST_OLD,
                   LEGACY_LIST_OLD.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings&&b.settings.enrolled==="1"'),
                   LEGACY_LIST_OLD.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings')):
        text = text.replace(legacy, STOCK_LIST)

    text = text.replace(LEGACY_SAVE, STOCK_SAVE)
    text = text.replace(LEGACY_SAVE_SKIP, STOCK_SAVE)
    return text


VPNPAGE = [
    ('import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"',
     'import{default as VpnServerNetbirdForm}from"./VpnServerNetbirdForm-NB.js";import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"', 1),
    ('.filter((e=>ut.supportVpnClientType(e)))',
     '.filter((e=>e===it.Netbird||ut.supportVpnClientType(e)))', 1),
    ('case it.Wireguard:return en;default:return null',
     'case it.Wireguard:return en;case it.Netbird:return VpnServerNetbirdForm;default:return null', 1),
]


def patch_text(text, patches, name):
    for old, new, count in patches:
        if new in text:
            continue
        got = text.count(old)
        if got != count:
            raise RuntimeError(f"{name}: expected {count} occurrence(s) of {old!r}, found {got}")
        text = text.replace(old, new)
    return text


def check_js(path, text):
    r = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"node --check failed for {path}:\n" + r.stderr.decode()[:2000])


def gzip_roundtrip(data):
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def read_js(path, is_gzip):
    data = open(path, "rb").read()
    return gzip.decompress(data).decode("utf-8") if is_gzip else data.decode("utf-8")


def write_js(path, is_gzip, text):
    payload = gzip_roundtrip(text.encode("utf-8")) if is_gzip else text.encode("utf-8")
    open(path, "wb").write(payload)


def apply_file(root, rel, is_gzip, patches, migrate=None):
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        raise RuntimeError(f"missing {path}")
    text = read_js(path, is_gzip)
    if migrate:
        text = migrate(text)
    text = patch_text(text, patches, rel)
    check_js(rel, text)
    write_js(path, is_gzip, text)
    print(f"  patched {rel} ({len(text)} bytes)")


def apply_locales(root):
    loc = os.path.join(root, "www/webpages/locale")
    patched = 0
    for d in sorted(os.listdir(loc)):
        dp = os.path.join(loc, d)
        if not os.path.isdir(dp):
            continue
        gz = [f for f in os.listdir(dp) if f.endswith(".js.gz")]
        if not gz:
            continue
        path = os.path.join(dp, gz[0])
        data = gzip.decompress(open(path, "rb").read()).decode("utf-8")
        if "typeNetbird" not in data:
            if data.count('typeWireguard:"') != 1:
                raise RuntimeError(f"{path}: typeWireguard count != 1")
            data = re.sub(r'(typeWireguard:"[^"]*")', r'\1,typeNetbird:"NetBird"', data, count=1)
            check_js(path, data)
            open(path, "wb").write(gzip_roundtrip(data.encode("utf-8")))
        patched += 1
    print(f"  patched {patched} locale bundles")


def assert_native_crud(root):
    model_path = os.path.join(root, JS, "model-CI6Gt3Hz.js.gz")
    page_path = os.path.join(root, JS, "index-DTNtPvwx.js.gz")
    model = read_js(model_path, True)
    page = read_js(page_path, True)

    forbidden = ["nbControl(", "nbSettingsSet", "window.__netbirdSaveDraft", "_nb.concat(e)"]
    combined = model + "\n" + page
    leaked = [token for token in forbidden if token in combined]
    if leaked:
        raise RuntimeError("legacy parallel NetBird CRUD hooks remain: " + ", ".join(leaked))

    if STOCK_UPDATE not in model or STOCK_DELETE not in model:
        raise RuntimeError("stock VPN update/delete paths were not restored")
    if STOCK_LIST not in page or STOCK_SAVE not in page:
        raise RuntimeError("stock VPN list/save paths were not restored")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
    print(f"Patching frontend bundles under {root} ...")
    apply_file(root, f"{JS}/update-store-DQkZxaRI.js.gz", True, UPDATE_STORE)
    apply_file(root, f"{JS}/util-JEiJiY0O.js", False, UTIL)
    apply_file(root, f"{JS}/model-CI6Gt3Hz.js.gz", True, [], migrate=migrate_model)
    apply_file(root, f"{JS}/index-DTNtPvwx.js.gz", True, VPNPAGE, migrate=migrate_vpn_page)

    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VpnServerNetbirdForm-NB.js")
    text = open(src).read()
    check_js("VpnServerNetbirdForm-NB.js", text)
    dst = os.path.join(root, JS, "VpnServerNetbirdForm-NB.js.gz")
    open(dst, "wb").write(gzip_roundtrip(text.encode("utf-8")))
    print(f"  installed VpnServerNetbirdForm-NB.js.gz ({len(text)} bytes)")

    apply_locales(root)
    assert_native_crud(root)
    print("Frontend patching complete: NetBird CRUD uses the native VPN route.")


if __name__ == "__main__":
    main()
