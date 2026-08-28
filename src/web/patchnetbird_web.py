#!/usr/bin/env python3
"""Offline frontend bundle patcher for NetBird VPN Client integration.

Hardware validation on AX53 Build 3 proved that TP-Link's compiled
/admin/vpn?form=server dispatcher does not invoke replacement Lua handlers.
NetBird therefore remains visually integrated in the stock VPN Client page, but
its profile/list actions use the explicit /admin/netbird controller. Built-in
VPN types continue through TP-Link's untouched native CRUD path.

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

# Stock model functions used by list-level toggle/delete for built-in VPNs.
STOCK_UPDATE = 'async function W(e,n){await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
STOCK_DELETE = 'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'

# Older experiments used the same dedicated endpoint but depended on a fragile
# global Save bridge. Remove those shapes when rebuilding an already-patched
# rootfs and install the deterministic bridge below instead.
LEGACY_UPDATE = 'async function W(e,n){if(e.type===u.Netbird||n.type===u.Netbird){await nbControl(n.enable?"start":"stop");return}await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
LEGACY_DELETE = 'async function J(e,n){if(e==="netbird"){await nbControl("clean");return}await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'

DEDICATED_UPDATE = 'async function W(e,n){if(e.type===u.Netbird||n.type===u.Netbird){const t=n.enable===!0||n.enable==="on"||n.enable==="1";await nbControl(t?"start":"stop");return}await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
DEDICATED_DELETE = 'async function J(e,n){if(e==="netbird"){await nbDelete();return}await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n)}'

NB_HELPERS = 'const nb="/admin/netbird";function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}function nbSettingsSet(e){return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}function nbControl(e){return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbDelete(){return a.request(nb,{operation:"profile_delete"},{preventSuccess:!0,preventError:!0})}'

# Native serializer from the abandoned adapter strategy. NetBird must no longer
# reach update-store/native /admin/vpn at all.
R_MARKER = 'function R(e){'
R_NATIVE = 'function R(e){if(e&&e.type===u.Netbird)return{...e,key:e.key||"netbird",type:u.Netbird,server:e.management_url||e.server||""};'

STOCK_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}'

# Include every editable setting in the synthetic native-looking row. This is
# essential because clicking Edit passes the row into the dynamic form's
# setForm() before its status poll completes.
DEDICATED_LIST = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.profileExists){const s=b.settings||{},_tr=b.traffic||{};let _server=s.management_url||"";try{_server=new URL(_server).host}catch(e){_server=_server.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"")}_nb=[{key:"netbird",id:"netbird",name:"NetBird",des:"NetBird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:s.enable==="1",enabled:s.enable==="1",enrolled:s.enrolled||"0",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:_server,management_url:s.management_url||"",hostname:s.hostname||"",disable_dns:s.disable_dns||"1",disable_firewall:s.disable_firewall||"1",disable_client_routes:s.disable_client_routes||"1",disable_server_routes:s.disable_server_routes||"1",disable_ipv6:s.disable_ipv6||"1",network_monitor:s.network_monitor||"0",advertise_lan:s.advertise_lan||"0",advertise_cidr:s.advertise_cidr||"",wireguard_port:s.wireguard_port||"51820",uploadSpeed:Number(_tr.uploadSpeed)||0,downloadSpeed:Number(_tr.downloadSpeed)||0}]}}catch(e){}a.value=_nb.concat(e),l.value=t}'

# Historical synthetic rows accepted during migration.
LEGACY_LIST_CURRENT = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")){let _server=b.settings.management_url||"";try{_server=new URL(_server).host}catch(e){_server=_server.replace(/^https?:\\/\\//,"").replace(/\\/.*$/,"")}const _tr=b.traffic||{};_nb=[{key:"netbird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:b.settings.enable==="1",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:_server,uploadSpeed:Number(_tr.uploadSpeed)||0,downloadSpeed:Number(_tr.downloadSpeed)||0}]}}catch(e){}a.value=_nb.concat(e),l.value=t}'
LEGACY_LIST_OLD = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting"))_nb=[{key:"netbird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:b.settings.enable==="1",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:b.netbird.netbirdIp||b.settings.management_url||"",uploadSpeed:"",downloadSpeed:""}]}catch(e){}a.value=_nb.concat(e),l.value=t}'

STOCK_SAVE = '"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
DEDICATED_SAVE = 'it.Netbird===i.type?await Nbs(i):"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
LEGACY_SAVE = 'it.Netbird===i.type?window.__netbirdSaveDraft?await window.__netbirdSaveDraft():(()=>{throw new Error("NetBird form unavailable")})():"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
LEGACY_SAVE_SKIP = 'it.Netbird!==i.type&&("add"===n.type?await Ce(i):await ne(i,n.tableItem))'


def patch_text(text, patches, name):
    for old, new, count in patches:
        if new in text:
            continue
        got = text.count(old)
        if got != count:
            raise RuntimeError(f"{name}: expected {count} occurrence(s) of {old!r}, found {got}")
        text = text.replace(old, new)
    return text


def patch_model(text, name):
    # Migrate either stock/current-native or older dedicated experiments into a
    # single explicit /admin/netbird bridge.
    text = text.replace(R_NATIVE, R_MARKER)
    text = text.replace(LEGACY_UPDATE, DEDICATED_UPDATE)
    text = text.replace(STOCK_UPDATE, DEDICATED_UPDATE)
    text = text.replace(LEGACY_DELETE, DEDICATED_DELETE)
    text = text.replace(STOCK_DELETE, DEDICATED_DELETE)

    # Remove previous helper/export variants before installing the canonical
    # four-function bridge.
    old_prefix = 'const nb="/admin/netbird";function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}function nbSettingsSet(e){return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}function nbEnroll(e,t){return a.request(nb,{operation:"enroll",setup_key:e,management_url:t},{preventSuccess:!0,preventError:!0})}function nbControl(e){return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbLog(e){return a.request(nb,{operation:"log",lines:e},{preventSuccess:!0,preventError:!0})}'
    text = text.replace(old_prefix, "")
    text = text.replace(NB_HELPERS, "")

    # Normalize exports from previous variants.
    text = text.replace('j as z,nbStatus as nbA,nbSettingsSet as nbB,nbEnroll as nbC,nbControl as nbD,nbLog as nbE};', 'j as z};')
    text = text.replace('j as z,nbStatus as nbA,nbSettingsSet as nbB,nbControl as nbD,nbDelete as nbF};', 'j as z};')

    marker = 'export{_ as A'
    if text.count(marker) != 1:
        raise RuntimeError(f"{name}: expected one model export marker")
    text = text.replace(marker, NB_HELPERS + marker, 1)
    if text.count('j as z};') != 1:
        raise RuntimeError(f"{name}: expected one model export tail")
    text = text.replace('j as z};', 'j as z,nbStatus as nbA,nbSettingsSet as nbB,nbControl as nbD,nbDelete as nbF};', 1)
    return text


def patch_vpn_page(text, name):
    # Canonical import from model bundle.
    text = text.replace(
        'X as ze,nbA as Nbt,nbB as Nbs,nbC as Nbe,nbD as Nbc,nbE as Nbl}from"./model-CI6Gt3Hz.js"',
        'X as ze,nbA as Nbt,nbB as Nbs}from"./model-CI6Gt3Hz.js"',
    )
    text = text.replace(
        'X as ze}from"./model-CI6Gt3Hz.js"',
        'X as ze,nbA as Nbt,nbB as Nbs}from"./model-CI6Gt3Hz.js"',
    )

    for old in (
        STOCK_LIST,
        LEGACY_LIST_CURRENT,
        LEGACY_LIST_OLD,
        LEGACY_LIST_OLD.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings&&b.settings.enrolled==="1"'),
        LEGACY_LIST_OLD.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings'),
    ):
        text = text.replace(old, DEDICATED_LIST)

    text = text.replace(LEGACY_SAVE, DEDICATED_SAVE)
    text = text.replace(LEGACY_SAVE_SKIP, DEDICATED_SAVE)
    text = text.replace(STOCK_SAVE, DEDICATED_SAVE)

    if DEDICATED_LIST not in text:
        raise RuntimeError(f"{name}: dedicated NetBird list bridge was not installed")
    if DEDICATED_SAVE not in text:
        raise RuntimeError(f"{name}: dedicated NetBird save bridge was not installed")
    return text


VPNPAGE = [
    ('import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"',
     'import{default as VpnServerNetbirdForm}from"./VpnServerNetbirdForm-NB.js";import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"', 1),
    ('.filter((e=>ut.supportVpnClientType(e)))',
     '.filter((e=>e===it.Netbird||ut.supportVpnClientType(e)))', 1),
    ('case it.Wireguard:return en;default:return null',
     'case it.Wireguard:return en;case it.Netbird:return VpnServerNetbirdForm;default:return null', 1),
]


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


def apply_file(root, rel, is_gzip, patches, transform=None):
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        raise RuntimeError(f"missing {path}")
    text = read_js(path, is_gzip)
    if transform:
        text = transform(text, rel)
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


def assert_dedicated_crud(root):
    model = read_js(os.path.join(root, JS, "model-CI6Gt3Hz.js.gz"), True)
    page = read_js(os.path.join(root, JS, "index-DTNtPvwx.js.gz"), True)
    combined = model + "\n" + page

    required = [NB_HELPERS, DEDICATED_UPDATE, DEDICATED_DELETE, DEDICATED_LIST, DEDICATED_SAVE]
    missing = [token[:80] for token in required if token not in combined]
    if missing:
        raise RuntimeError("dedicated NetBird CRUD bridge incomplete: " + ", ".join(missing))

    forbidden = [R_NATIVE, "window.__netbirdSaveDraft", 'it.Netbird!==i.type&&(']
    leaked = [token for token in forbidden if token in combined]
    if leaked:
        raise RuntimeError("obsolete NetBird CRUD path remains: " + ", ".join(leaked))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
    print(f"Patching frontend bundles under {root} ...")
    apply_file(root, f"{JS}/update-store-DQkZxaRI.js.gz", True, UPDATE_STORE)
    apply_file(root, f"{JS}/util-JEiJiY0O.js", False, UTIL)
    apply_file(root, f"{JS}/model-CI6Gt3Hz.js.gz", True, [], transform=patch_model)
    apply_file(root, f"{JS}/index-DTNtPvwx.js.gz", True, VPNPAGE, transform=patch_vpn_page)

    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "VpnServerNetbirdForm-NB.js")
    text = open(src).read()
    check_js("VpnServerNetbirdForm-NB.js", text)
    dst = os.path.join(root, JS, "VpnServerNetbirdForm-NB.js.gz")
    open(dst, "wb").write(gzip_roundtrip(text.encode("utf-8")))
    print(f"  installed VpnServerNetbirdForm-NB.js.gz ({len(text)} bytes)")

    apply_locales(root)
    assert_dedicated_crud(root)
    print("Frontend patching complete: NetBird uses dedicated CRUD inside the stock VPN Client UI.")


if __name__ == "__main__":
    main()
