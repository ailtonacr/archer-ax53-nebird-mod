#!/usr/bin/env python3
"""Install the managed-switch SPA module and add a child under Rede/Network.

This follows the proven pattern from the native NetBird branch:
- authored module lives under www/webpages/js and imports TP-Link update-store;
- the stock SPA bundle only receives the smallest possible integration patch;
- requests therefore use TP-Link's initialized encrypted transport/session;
- no standalone page performs raw fetch() calls to LuCI.

The injected child is cloned from a real stock Network submenu item. It is
removed whenever the stock submenu is collapsed/unmounted, avoiding the stale
or top-level-looking item seen in earlier DOM-only revisions.
"""
from __future__ import annotations

import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "www/webpages/js/index-D26yCMJF.js.gz"
SOURCE = PROJECT_ROOT / "src/web/ManagedSwitchPage-AX.js"
MODULE_DST = ROOT / "www/webpages/js/ManagedSwitchPage-AX.js.gz"
MARKER = "__AX53_MANAGED_SWITCH_MENU__"
VERSION = "__AX53_MANAGED_SWITCH_MENU_V4_STOCK_CONTEXT__"
BEGIN = "/*__AX53_MANAGED_SWITCH_MENU_BEGIN__*/"
END = "/*__AX53_MANAGED_SWITCH_MENU_END__*/"


def gzip_bytes(data: bytes) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def check_js(name: str, text: str) -> None:
    result = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode("utf-8"), capture_output=True,
    )
    if result.returncode:
        raise SystemExit(f"Error: node --check failed for {name}:\n{result.stderr.decode()[:2000]}")


def install_module() -> str:
    if not SOURCE.is_file():
        raise SystemExit(f"Error: managed-switch SPA source missing: {SOURCE}")
    text = SOURCE.read_text(encoding="utf-8")
    check_js(str(SOURCE), text)
    required = (
        'import { s as api } from "./update-store-DQkZxaRI.js"',
        'api.request(API',
        'const API = "/admin/managed_switch"',
        'export function openManagedSwitch()',
    )
    missing = [x for x in required if x not in text]
    if missing:
        raise SystemExit("Error: managed-switch module is not using stock API contract: " + ", ".join(missing))
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]
    MODULE_DST.parent.mkdir(parents=True, exist_ok=True)
    MODULE_DST.write_bytes(gzip_bytes(text.encode("utf-8")))
    return f"./ManagedSwitchPage-AX.js?v={digest}"


def read_bundle() -> str:
    if not BUNDLE.is_file():
        raise SystemExit(f"Error: TP-Link main SPA bundle missing: {BUNDLE}")
    with gzip.open(BUNDLE, "rt", encoding="utf-8") as fh:
        return fh.read()


def write_bundle(text: str) -> None:
    BUNDLE.write_bytes(gzip_bytes(text.encode("utf-8")))


def strip_previous_injector(text: str) -> str:
    if BEGIN in text:
        start = text.rfind(BEGIN)
        end = text.find(END, start)
        if end < 0:
            raise SystemExit("Error: managed-switch menu BEGIN marker has no END marker")
        return (text[:start] + text[end + len(END):]).rstrip() + "\n"

    if MARKER in text:
        marker_pos = text.rfind(MARKER)
        start = text.rfind(';(()=>{"use strict";', 0, marker_pos)
        if start < 0:
            raise SystemExit("Error: found legacy managed-switch marker but cannot locate injector safely")
        return text[:start].rstrip() + "\n"
    return text


def injector(module_spec: str) -> str:
    return rf'''
{BEGIN}
;(()=>{{"use strict";
const M="{MARKER}",V="{VERSION}",ID="ax53-managed-switch-menu",MOD="{module_spec}";
if(window[M]===V)return;window[M]=V;
const norm=s=>(s||"").replace(/\s+/g," ").trim().toLowerCase();
const isNetworkLabel=s=>{{const n=norm(s);return n==="rede"||n==="network";}};
const clearActive=e=>{{if(!e||e.nodeType!==1)return;e.removeAttribute("aria-current");e.removeAttribute("aria-selected");if(e.classList)[...e.classList].forEach(c=>{{if(/active|selected|current/i.test(c))e.classList.remove(c);}});}};
const clean=e=>{{if(!e||e.nodeType!==1)return;["id","data-route","data-router-link","data-to","to","data-key"].forEach(a=>e.removeAttribute(a));clearActive(e);for(const x of e.querySelectorAll("[id],[data-route],[data-router-link],[data-to],[to],[data-key]")){{["id","data-route","data-router-link","data-to","to","data-key"].forEach(a=>x.removeAttribute(a));clearActive(x);}}}};
const networkTriggers=()=>[...document.querySelectorAll("a,button,span,div")].filter(e=>isNetworkLabel(e.textContent));
const looksLikeMenu=e=>{{if(!e||e.nodeType!==1)return false;const c=String(e.className||"").toLowerCase();return e.tagName==="UL"||e.getAttribute("role")==="menu"||/sub.?menu|children|submenu/.test(c);}};
const findSubmenu=trigger=>{{if(!trigger)return null;const controls=trigger.getAttribute&&trigger.getAttribute("aria-controls");if(controls){{const x=document.getElementById(controls);if(x)return x;}}const roots=[trigger.closest&&trigger.closest("li"),trigger.parentElement].filter(Boolean);for(const root of roots){{const inside=root.querySelector&&root.querySelector("ul,[role=menu],[class*=submenu],[class*=sub-menu],[class*=children]");if(inside&&inside!==root)return inside;let sib=root.nextElementSibling;while(sib){{if(looksLikeMenu(sib))return sib;sib=sib.nextElementSibling;}}}}return null;}};
const stockChildren=submenu=>[...submenu.children].filter(c=>c.id!==ID&&!(c.querySelector&&c.querySelector("#"+ID))&&c.querySelector&&c.querySelector("a,button,[role=menuitem]"));
const openPage=async ev=>{{if(ev){{ev.preventDefault();ev.stopPropagation();}}try{{const m=await import(MOD);const fn=m.openManagedSwitch||(m.default&&m.default.openManagedSwitch);if(typeof fn!=="function")throw new Error("módulo sem openManagedSwitch");fn();}}catch(e){{console.error("Managed Switch UI load failed",e);alert("Falha ao abrir Switch / VLAN: "+(e&&e.message||e));}}}};
const buildItem=sample=>{{const wrapper=sample.cloneNode(true);clean(wrapper);wrapper.id=ID;const controls=[...wrapper.querySelectorAll("a,button,[role=menuitem]")];const ctl=controls[0]||wrapper;clean(ctl);if(ctl.tagName==="A")ctl.setAttribute("href","#");ctl.setAttribute&&ctl.setAttribute("title","Switch / VLAN");const leaves=[...ctl.querySelectorAll("span")].filter(x=>x.children.length===0);if(leaves.length)leaves[leaves.length-1].textContent="Switch / VLAN";else ctl.textContent="Switch / VLAN";wrapper.addEventListener("click",openPage);return wrapper;}};
const sync=()=>{{const existing=document.getElementById(ID);let usable=null;for(const trigger of networkTriggers()){{const submenu=findSubmenu(trigger);if(!submenu)continue;const stocks=stockChildren(submenu);if(stocks.length){{usable={{submenu,stocks}};break;}}}}if(!usable){{if(existing)existing.remove();return false;}}if(existing&&existing.parentElement===usable.submenu)return true;if(existing)existing.remove();usable.submenu.insertBefore(buildItem(usable.stocks[0]),usable.stocks[0]);return true;}};
let attempts=0;const retry=()=>{{if(sync()||attempts++>120)return;setTimeout(retry,250);}};
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",retry,{{once:true}});else retry();
new MutationObserver(()=>sync()).observe(document.documentElement,{{childList:true,subtree:true}});
window.addEventListener("hashchange",()=>setTimeout(sync,50));
}})();
{END}
'''


def validate(text: str, module_spec: str) -> None:
    required = (
        MARKER, VERSION, BEGIN, END, "ax53-managed-switch-menu",
        module_spec, "Switch / VLAN", 'n==="rede"||n==="network"',
        "stockChildren", "openPage", "import(MOD)", "MutationObserver",
    )
    missing = [x for x in required if x not in text]
    if missing:
        raise SystemExit("Error: managed-switch stock-SPA injection incomplete: " + ", ".join(missing))
    if text.count(MARKER) != 1 or text.count(BEGIN) != 1 or text.count(END) != 1:
        raise SystemExit("Error: managed-switch menu injector must be present exactly once")
    if "/webpages/managed-switch.html" in text[text.rfind(BEGIN):]:
        raise SystemExit("Error: legacy standalone managed-switch navigation still present")


def main() -> None:
    module_spec = install_module()
    text = read_bundle()
    if VERSION not in text or module_spec not in text:
        text = strip_previous_injector(text)
        text = text.rstrip() + "\n" + injector(module_spec).strip() + "\n"
        check_js(str(BUNDLE), text)
        write_bundle(text)
        text = read_bundle()
    validate(text, module_spec)
    print(f"Managed Switch stock-context module installed: {MODULE_DST}")
    print(f"Managed Switch launcher installed under Network/Rede: {BUNDLE}")


if __name__ == "__main__":
    main()
