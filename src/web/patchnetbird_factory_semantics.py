#!/usr/bin/env python3
"""Post-patch the AX53 VPN Client bundles with factory-compatible semantics.

TP-Link documents the classic VPN Client as allowing multiple saved profiles but
only one active profile at a time. NetBird uses a dedicated backend, so the
frontend bridge must explicitly preserve that invariant across NetBird and the
stock VPN profiles.

This pass also keeps the NetBird profile description as real persisted metadata
instead of hard-coding "NetBird" in the synthetic row/form.
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
    list_factory = 'i=async()=>{const{data:e,maxRules:t}=await J();globalThis.__nbActiveStockVpn=e.find((e=>e&&e.enable))||null;let _nb=[];'
    text = replace_once(text, list_prefix, list_factory, "stock active profile tracking")

    old_meta = 'key:"netbird",id:"netbird",name:"NetBird",des:"NetBird",description:"NetBird",type:it.Netbird'
    new_meta = 'key:"netbird",id:"netbird",name:s.description||"NetBird",des:s.description||"NetBird",description:s.description||"NetBird",type:it.Netbird'
    text = replace_once(text, old_meta, new_meta, "NetBird description list metadata")

    old_save = 'it.Netbird===i.type?await Nbs(i):"add"===n.type?await Ce(i):await ne(i,n.tableItem)'
    new_save = 'it.Netbird===i.type?await Nbs(i):(i&&(i.enable===!0||i.enable==="on"||i.enable==="1"||i.enabled===!0)&&await nbStopIfEnabled(),"add"===n.type?await Ce(i):await ne(i,n.tableItem))'
    # nbStopIfEnabled is exported by the model post-patch. Add it to the page import.
    old_import = 'X as ze,nbA as Nbt,nbB as Nbs}from"./model-CI6Gt3Hz.js"'
    new_import = 'X as ze,nbA as Nbt,nbB as Nbs,nbG as NbStop}from"./model-CI6Gt3Hz.js"'
    # The main patcher does not know this export yet; use a local alias by replacing
    # the save expression with the imported alias below after export injection.
    text = replace_once(text, old_import, new_import, "single-active page import")
    new_save = new_save.replace("nbStopIfEnabled()", "NbStop()")
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


def patch_form() -> None:
    name = "VpnServerNetbirdForm-NB.js.gz"
    text = read_gz(name)

    old_norm = 'enrolled: as01(v.enrolled, base.enrolled || "0"),\n    management_url:'
    new_norm = 'enrolled: as01(v.enrolled, base.enrolled || "0"),\n    description: v.description !== undefined ? String(v.description || "") : (base.description || "NetBird"),\n    management_url:'
    text = replace_once(text, old_norm, new_norm, "description normalization")

    old_stock = 'name: "NetBird",\n    des: "NetBird",\n    description: "NetBird",'
    new_stock = 'name: s.description || "NetBird",\n    des: s.description || "NetBird",\n    description: s.description || "NetBird",'
    text = replace_once(text, old_stock, new_stock, "description stock form")

    old_validate = 'const s = draft.value || settings.value || {};\n      if (!validManagementUrl(s.management_url)) {'
    new_validate = 'const s = draft.value || settings.value || {};\n      if (!String(s.description || "").trim()) {\n        error.value = "Informe uma descrição para o perfil.";\n        return false;\n      }\n      if (!validManagementUrl(s.management_url)) {'
    text = replace_once(text, old_validate, new_validate, "description validation")

    old_fields = 'const serverFields = [field("URL de gerenciamento", _h("input", {'
    new_fields = 'const serverFields = [field("Descrição", _h("input", {\n        type: "text", value: s.description || "", disabled: props.disabled || busy.value,\n        class: "netbird-input", maxlength: "64", onInput: function (ev) { updateDraft("description", ev.target.value); },\n      })), field("URL de gerenciamento", _h("input", {'
    text = replace_once(text, old_fields, new_fields, "description field")

    check_js(name, text)
    write_gz(name, text)


def main() -> None:
    patch_model()
    patch_model_export()
    patch_page()
    patch_form()
    print("Factory VPN single-active + NetBird description semantics patched")


if __name__ == "__main__":
    main()
