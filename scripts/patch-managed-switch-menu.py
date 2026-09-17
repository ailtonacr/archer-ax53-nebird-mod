#!/usr/bin/env python3
"""Inject the Managed Switch launcher under the stock Network/Rede menu.

The AX53 V1 frontend is a minified, gzipped Vue SPA. LuCI controller entries do
not automatically become visible SPA routes, so this patch adds one tiny DOM
launcher while leaving the stock router/menu implementation intact.

The launcher is intentionally nested under the existing "Rede" / "Network"
group. There is no top-level fallback: if the Network submenu is not present
yet, a MutationObserver retries when the SPA materializes it.

The launcher opens:
    /webpages/managed-switch.html

The standalone page talks directly to the LuCI controller and does not import
the SPA's update-store singleton.
"""
from __future__ import annotations

import gzip
import io
from pathlib import Path
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
BUNDLE = ROOT / "www/webpages/js/index-D26yCMJF.js.gz"
MARKER = "__AX53_MANAGED_SWITCH_MENU__"
VERSION = "__AX53_MANAGED_SWITCH_MENU_V2_NETWORK__"
BEGIN = "/*__AX53_MANAGED_SWITCH_MENU_BEGIN__*/"
END = "/*__AX53_MANAGED_SWITCH_MENU_END__*/"

INJECTOR = rf'''
{BEGIN}
;(()=>{{"use strict";
const M="{MARKER}",V="{VERSION}",ID="ax53-managed-switch-menu";
if(window[M]===V)return;window[M]=V;
const managedUrl=()=>"/webpages/managed-switch.html";
const norm=s=>(s||"").replace(/\s+/g," ").trim().toLowerCase();
const isNetworkLabel=s=>{{const n=norm(s);return n==="rede"||n==="network";}};
const stripRouterAttrs=e=>{{
  ["data-route","data-router-link","data-to","to","data-key"].forEach(a=>e.removeAttribute&&e.removeAttribute(a));
  e.removeAttribute&&e.removeAttribute("target");
}};
const wire=e=>{{
  e.id=ID;stripRouterAttrs(e);
  if(e.tagName==="A")e.setAttribute("href",managedUrl());
  e.setAttribute&&e.setAttribute("title","Switch / VLAN");
  e.textContent="Switch / VLAN";
  e.addEventListener("click",ev=>{{ev.preventDefault();ev.stopPropagation();location.href=managedUrl();}});
  return e;
}};
const networkTrigger=()=>{{
  const nodes=document.querySelectorAll("a,button,span,div");
  for(const e of nodes){{
    if(!isNetworkLabel(e.textContent))continue;
    return e;
  }}
  return null;
}};
const looksLikeMenu=e=>{{
  if(!e||e.nodeType!==1)return false;
  const cls=String(e.className||"").toLowerCase();
  return e.tagName==="UL"||e.getAttribute("role")==="menu"||/sub.?menu|children|submenu/.test(cls);
}};
const findSubmenu=trigger=>{{
  if(!trigger)return null;
  const controls=trigger.getAttribute&&trigger.getAttribute("aria-controls");
  if(controls){{const byId=document.getElementById(controls);if(byId)return byId;}}
  const root=trigger.closest&&trigger.closest("li");
  if(root){{
    const inside=root.querySelector("ul,[role=menu],[class*=submenu],[class*=sub-menu],[class*=children]");
    if(inside&&inside!==root)return inside;
    let sib=root.nextElementSibling;
    while(sib){{if(looksLikeMenu(sib))return sib;sib=sib.nextElementSibling;}}
  }}
  const parent=trigger.parentElement;
  if(parent){{
    const inside=parent.querySelector("ul,[role=menu],[class*=submenu],[class*=sub-menu],[class*=children]");
    if(inside&&inside!==parent)return inside;
    let sib=parent.nextElementSibling;
    while(sib){{if(looksLikeMenu(sib))return sib;sib=sib.nextElementSibling;}}
  }}
  return null;
}};
const buildItem=submenu=>{{
  const children=[...submenu.children];
  const sample=children.find(c=>c.querySelector&&c.querySelector("a,button"))||null;
  let wrapper;
  if(sample){{wrapper=sample.cloneNode(false);stripRouterAttrs(wrapper);wrapper.removeAttribute&&wrapper.removeAttribute("id");}}
  else wrapper=document.createElement(submenu.tagName==="UL"?"li":"div");
  const sampleControl=sample&&sample.querySelector&&sample.querySelector("a,button");
  const control=wire(sampleControl?sampleControl.cloneNode(false):document.createElement("a"));
  wrapper.appendChild(control);
  return wrapper;
}};
const inject=()=>{{
  if(document.getElementById(ID))return true;
  const trigger=networkTrigger();
  const submenu=findSubmenu(trigger);
  if(!submenu)return false;
  submenu.appendChild(buildItem(submenu));
  return true;
}};
let attempts=0;
const retry=()=>{{if(inject()||attempts++>120)return;setTimeout(retry,250);}};
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",retry,{{once:true}});else retry();
new MutationObserver(()=>{{if(!document.getElementById(ID))inject();}})
  .observe(document.documentElement,{{childList:true,subtree:true}});
window.addEventListener("hashchange",()=>setTimeout(inject,50));
}})();
{END}
'''


def read_bundle() -> str:
    if not BUNDLE.is_file():
        raise SystemExit(f"Error: TP-Link main SPA bundle missing: {BUNDLE}")
    with gzip.open(BUNDLE, "rt", encoding="utf-8") as fh:
        return fh.read()


def write_bundle(text: str) -> None:
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode("utf-8"))
    BUNDLE.write_bytes(buf.getvalue())


def strip_previous_injector(text: str) -> str:
    if BEGIN in text:
        start = text.rfind(BEGIN)
        end = text.find(END, start)
        if end < 0:
            raise SystemExit("Error: managed-switch menu BEGIN marker has no END marker")
        end += len(END)
        return (text[:start] + text[end:]).rstrip() + "\n"

    if MARKER in text:
        marker_pos = text.rfind(MARKER)
        start = text.rfind(';(()=>{"use strict";', 0, marker_pos)
        if start < 0 or "/webpages/managed-switch.html" not in text[start:]:
            raise SystemExit("Error: found legacy managed-switch marker but cannot locate its injector safely")
        return text[:start].rstrip() + "\n"

    return text


def validate(text: str) -> None:
    required = (
        MARKER,
        VERSION,
        BEGIN,
        END,
        "ax53-managed-switch-menu",
        "/webpages/managed-switch.html",
        "Switch / VLAN",
        'n==="rede"||n==="network"',
        "findSubmenu",
        "MutationObserver",
    )
    missing = [token for token in required if token not in text]
    if missing:
        raise SystemExit("Error: managed-switch Network-menu injection incomplete: " + ", ".join(missing))
    if text.count(MARKER) != 1:
        raise SystemExit(f"Error: managed-switch menu marker count is {text.count(MARKER)}, expected 1")
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise SystemExit("Error: managed-switch menu sentinel count must be exactly one")


def main() -> None:
    text = read_bundle()
    if VERSION not in text:
        text = strip_previous_injector(text)
        text = text.rstrip() + "\n" + INJECTOR.strip() + "\n"
        write_bundle(text)
        text = read_bundle()
    validate(text)
    print(f"Managed Switch launcher installed under Network/Rede: {BUNDLE}")


if __name__ == "__main__":
    main()
