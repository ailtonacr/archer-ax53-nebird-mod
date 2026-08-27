#!/usr/bin/env python3
"""Offline frontend bundle patcher for NetBird VPN Client integration.

Decompresses each target bundle, applies exact (old -> new) replacements with
strict occurrence checks, recompresses deterministically, and re-validates the
patched JavaScript syntax with node --input-type=module --check.

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

MODEL = [
    ('export{_ as A',
      'const nb="/admin/netbird";function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}function nbSettingsSet(e){return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}function nbEnroll(e,t){return a.request(nb,{operation:"enroll",setup_key:e,management_url:t},{preventSuccess:!0,preventError:!0})}function nbControl(e){return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbLog(e){return a.request(nb,{operation:"log",lines:e},{preventSuccess:!0,preventError:!0})}export{_ as A', 1),
    ('j as z};',
     'j as z,nbStatus as nbA,nbSettingsSet as nbB,nbEnroll as nbC,nbControl as nbD,nbLog as nbE};', 1),
]

VPNPAGE = [
    ('import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"',
     'import{default as VpnServerNetbirdForm}from"./VpnServerNetbirdForm-NB.js";import{f as lt,V as it,i as rt,u as st,as as ot}from"./update-store-DQkZxaRI.js"', 1),
    ('X as ze}from"./model-CI6Gt3Hz.js"',
     'X as ze,nbA as Nbt,nbB as Nbs,nbC as Nbe,nbD as Nbc,nbE as Nbl}from"./model-CI6Gt3Hz.js"', 1),
    ('.filter((e=>ut.supportVpnClientType(e)))',
     '.filter((e=>e===it.Netbird||ut.supportVpnClientType(e)))', 1),
    ('case it.Wireguard:return en;default:return null',
     'case it.Wireguard:return en;case it.Netbird:return VpnServerNetbirdForm;default:return null', 1),
    # A live daemon is authoritative even if a stale pre-fix settings file still
    # says enrolled=0. The backend repairs it, while this keeps the list visible
    # during that first refresh.
    ('i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
     'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];try{const b=await Nbt();if(b&&b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting"))_nb=[{key:"netbird",description:"NetBird",type:it.Netbird,vendor:te.Manual,enable:b.settings.enable==="1",status:"connected"===b.code?we.Connected:"connecting"===b.code?we.Connecting:we.Disconnected,server:b.netbird.netbirdIp||b.settings.management_url||"",uploadSpeed:"",downloadSpeed:""}]}catch(e){}a.value=_nb.concat(e),l.value=t}', 1),
    # The stock footer is the only Save button. NetBird owns persistence through
    # its backend, so bridge the parent save action to the mounted sub-form.
    ('"add"===n.type?await Ce(i):await ne(i,n.tableItem)',
     'it.Netbird===i.type?window.__netbirdSaveDraft?await window.__netbirdSaveDraft():(()=>{throw new Error("NetBird form unavailable")})():"add"===n.type?await Ce(i):await ne(i,n.tableItem)', 1),
]


def patch_text(text, patches, name):
    for old, new, count in patches:
        if new in text:
            continue
        got = text.count(old)

        # Upgrade known older NetBird injections in-place. This is needed when
        # rebuilding from a previously patched rootfs rather than pristine stock.
        legacy_candidates = []
        if 'b.settings&&(b.settings.enrolled===' in new:
            legacy_candidates.extend([
                new.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings&&b.settings.enrolled==="1"'),
                new.replace('b.settings&&(b.settings.enrolled==="1"||b.code==="connected"||b.code==="connecting")', 'b.settings'),
            ])
        if 'window.__netbirdSaveDraft' in new:
            legacy_candidates.append('it.Netbird!==i.type&&("add"===n.type?await Ce(i):await ne(i,n.tableItem))')

        replaced = False
        if got == 0:
            for legacy in legacy_candidates:
                if legacy != new and text.count(legacy) == count:
                    text = text.replace(legacy, new)
                    replaced = True
                    break
        if replaced:
            continue
        if got != count:
            raise RuntimeError(f"{name}: expected {count} occurrence(s) of {old!r}, found {got}")
        text = text.replace(old, new)
    return text


def check_js(path, text):
    r = subprocess.run(["node", "--input-type=module", "--check"],
                       input=text.encode(), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"node --check failed for {path}:\n" + r.stderr.decode()[:2000])


def gzip_roundtrip(data):
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def apply_file(root, rel, is_gzip, patches, new_chunk=False):
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        raise RuntimeError(f"missing {path}")
    data = open(path, "rb").read()
    if is_gzip:
        text = gzip.decompress(data).decode("utf-8")
    else:
        text = data.decode("utf-8")
    text = patch_text(text, patches, rel)
    check_js(rel, text)
    if is_gzip:
        open(path, "wb").write(gzip_roundtrip(text.encode("utf-8")))
    else:
        open(path, "wb").write(text.encode("utf-8"))
    print(f"  patched {rel} ({len(text)} bytes)")


def apply_locales(root):
    loc = os.path.join(root, "www/webpages/locale")
    for d in sorted(os.listdir(loc)):
        dp = os.path.join(loc, d)
        if not os.path.isdir(dp):
            continue
        gz = [f for f in os.listdir(dp) if f.endswith(".js.gz")]
        if not gz:
            continue
        path = os.path.join(dp, gz[0])
        data = gzip.decompress(open(path, "rb").read()).decode("utf-8")
        if "typeNetbird" in data:
            continue
        if data.count('typeWireguard:"') != 1:
            raise RuntimeError(f"{path}: typeWireguard count != 1")
        data = re.sub(r'(typeWireguard:"[^"]*")',
                      r'\1,typeNetbird:"NetBird"', data, count=1)
        check_js(path, data)
        open(path, "wb").write(gzip_roundtrip(data.encode("utf-8")))
    print(f"  patched {sum(1 for d in os.listdir(loc) if os.path.isdir(os.path.join(loc,d)))} locale bundles")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
    print(f"Patching frontend bundles under {root} ...")

    apply_file(root, f"{JS}/update-store-DQkZxaRI.js.gz", True, UPDATE_STORE)
    apply_file(root, f"{JS}/util-JEiJiY0O.js", False, UTIL)
    apply_file(root, f"{JS}/model-CI6Gt3Hz.js.gz", True, MODEL)
    apply_file(root, f"{JS}/index-DTNtPvwx.js.gz", True, VPNPAGE)

    src = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "VpnServerNetbirdForm-NB.js")
    text = open(src).read()
    check_js("VpnServerNetbirdForm-NB.js", text)
    dst = os.path.join(root, JS, "VpnServerNetbirdForm-NB.js.gz")
    open(dst, "wb").write(gzip_roundtrip(text.encode("utf-8")))
    print(f"  installed VpnServerNetbirdForm-NB.js.gz ({len(text)} bytes)")

    apply_locales(root)
    print("Frontend patching complete.")


if __name__ == "__main__":
    main()
