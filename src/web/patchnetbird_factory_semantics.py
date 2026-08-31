#!/usr/bin/env python3
"""Post-patch AX53 VPN Client bundles with factory-compatible exclusivity.

This pass touches only TP-Link's shared model/page bundles. The NetBird subform
itself is authored with the complete native form contract in
VpnServerNetbirdForm-NB.js and must not be rewritten through brittle string
substitutions after installation.
"""
from __future__ import annotations

import gzip
import io
import os
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


def patch_model() -> None:
    name = "model-CI6Gt3Hz.js.gz"
    text = read_gz(name)

    old_helpers = 'const nb="/admin/netbird";function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}function nbSettingsSet(e){return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}function nbControl(e){return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbDelete(){return a.request(nb,{operation:"profile_delete"},{preventSuccess:!0,preventError:!0})}'
    new_helpers = 'const nb="/admin/netbird";function nbEnabled(e){return!!(e&&(e.enable===!0||e.enable==="on"||e.enable==="1"||e.enabled===!0))}function nbStatus(e){return a.request(nb,{operation:"status",...e},{preventSuccess:!0,preventError:!0})}async function nbDisableStockActive(){const e=globalThis.__nbActiveStockVpn;if(!e)return;const n={...e,enable:!1,enabled:!1};await a.update(y,{key:e.key},R(n),R(e),{preventSuccess:!0});globalThis.__nbActiveStockVpn=null}async function nbStopIfEnabled(){const e=await nbStatus();e&&e.profileExists&&e.settings&&e.settings.enable==="1"&&await nbControl("stop")}async function nbSettingsSet(e){nbEnabled(e)&&await nbDisableStockActive();return a.request(nb,{operation:"settings_set",...e},{preventSuccess:!0,preventError:!0})}async function nbControl(e){e==="start"&&await nbDisableStockActive();return a.request(nb,{operation:e},{preventSuccess:!0,preventError:!0})}function nbDelete(){return a.request(nb,{operation:"profile_delete"},{preventSuccess:!0,preventError:!0})}'
    text = replace_once(text, old_helpers, new_helpers, "model helpers")

    old_update = 'async function W(e,n){if(e.type===u.Netbird||n.type===u.Netbird){const t=e.enable===!0||e.enable==="on"||e.enable==="1";await nbControl(t?"start":"stop");return}await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
    new_update = 'async function W(e,n){if(e.type===u.Netbird||n.type===u.Netbird){const t=nbEnabled(e);await nbControl(t?"start":"stop");return}nbEnabled(e)&&await nbStopIfEnabled();await function(e,n,t){return a.update(y,{key:e},n,t,{preventSuccess:!0})}(e.key,R(e),R(n))}'
    text = replace_once(text, old_update, new_update, "single-active toggle")

    check_js(name, text)
    write_gz(name, text)


def patch_page() -> None:
    name = "index-DTNtPvwx.js.gz"
    text = read_gz(name)

    list_prefix = 'i=async()=>{const{data:e,maxRules:t}=await J();let _nb=[];'
    list_factory = 'i=async()=>{const{data:e,maxRules:t}=await J();globalThis.__nbActiveStockVpn=e.find((e=>e&&(e.enable===!0||e.enable==="on"||e.enable==="1"||e.enabled===!0)))||null;let _nb=[];'
    text = replace_once(text, list_prefix, list_factory, "stock active profile tracking")

    old_meta = 'key:"netbird",id:"netbird",name:"NetBird",des:"NetBird",description:"NetBird",type:it.Netbird'
    new_meta = 'key:"netbird",id:"netbird",name:s.description||"NetBird",des:s.description||"NetBird",description:s.description||"NetBird",type:it.Netbird'
    text = replace_once(text, old_meta, new_meta, "NetBird description list metadata")

    old_save = 'it.Netbird===i.type?await Nbs(i):"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
    new_save = 'it.Netbird===i.type?await Nbs(i):(i&&(i.enable===!0||i.enable==="on"||i.enable==="1"||i.enabled===!0)&&await NbStop(),"add"===n.type?await Ce(i):await ne(i,n.tableItem))'
    old_import = 'X as ze,nbA as Nbt,nbB as Nbs}from"./model-CI6Gt3Hz.js"'
    new_import = 'X as ze,nbA as Nbt,nbB as Nbs,nbG as NbStop}from"./model-CI6Gt3Hz.js"'
    text = replace_once(text, old_import, new_import, "single-active page import")
    text = replace_once(text, old_save, new_save, "single-active stock save")

    check_js(name, text)
    write_gz(name, text)


def patch_model_export() -> None:
    name = "model-CI6Gt3Hz.js.gz"
    text = read_gz(name)
    old = 'nbControl as nbD,nbDelete as nbF};'
    new = 'nbControl as nbD,nbDelete as nbF,nbStopIfEnabled as nbG};'
    text = replace_once(text, old, new, "model exclusivity export")
    check_js(name, text)
    write_gz(name, text)


def check_native_form_source() -> None:
    name = "VpnServerNetbirdForm-NB.js.gz"
    text = read_gz(name)
    required = [
        'context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })',
        'stockComponent(this, "su-form")',
        'stockComponent(this, "su-form-item")',
        'stockComponent(this, "su-input")',
        'stockComponent(this, "su-checkbox")',
        'stockComponent(this, "su-button")',
        'stockComponent(this, "su-alert")',
        'const creating = ref(true)',
        'const existing = !!(value && (value.key || value.id))',
        's.advertise_lan === "1" && s.disable_server_routes !== "0"',
    ]
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("native NetBird form source incomplete: " + ", ".join(missing))
    forbidden = [
        "NETBIRD_CSS", 'type: "checkbox"', 'class: "netbird-input"', "syncNativeSaveButton",
        'value.type === "netbirdvpn"', 'value.type === "netbird"', "const creating = ref(false)",
    ]
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("legacy/type-derived NetBird UI leaked: " + ", ".join(leaked))
    check_js(name, text)


def main() -> None:
    patch_model()
    patch_model_export()
    patch_page()
    check_native_form_source()
    print("Factory VPN exclusivity patched; final NetBird stock-component form preserved")


if __name__ == "__main__":
    main()
