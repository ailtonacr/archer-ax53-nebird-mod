#!/usr/bin/env python3
"""Inject a Managed Switch launcher into the stock TP-Link SPA menu.

The TP-Link AX53 V1 frontend keeps its visual menu/router inside minified,
gzipped Vue bundles. LuCI controller entries are therefore not materialized as
SPA menu items automatically.

This patch deliberately avoids reimplementing the stock router. It adds one
small, idempotent DOM launcher to the common application bundle. The launcher
prefers to place "Switch / VLAN" next to the stock IPTV/VLAN item and falls
back to the first sidebar/menu list it can identify.

The launcher opens:
    /webpages/managed-switch.html

That page imports TP-Link's stock update-store client, so authenticated calls to
/admin/managed_switch use the same stok/session transport as the rest of the
SPA. No stok token is parsed from the visible /webpages/index.html#/ URL.
"""
from __future__ import annotations

import gzip
import io
from pathlib import Path
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
BUNDLE = ROOT / "www/webpages/js/index-D26yCMJF.js.gz"
MARKER = "__AX53_MANAGED_SWITCH_MENU__"

INJECTOR = r'''
;(()=>{"use strict";
const M="__AX53_MANAGED_SWITCH_MENU__",ID="ax53-managed-switch-menu";
if(window[M])return;window[M]=true;
const managedUrl=()=>"/webpages/managed-switch.html";
const stripRouterAttrs=e=>{
  ["data-route","data-router-link","data-to","to"].forEach(a=>e.removeAttribute&&e.removeAttribute(a));
  e.removeAttribute&&e.removeAttribute("target");
};
const wire=a=>{
  a.id=ID;stripRouterAttrs(a);a.setAttribute("href",managedUrl());a.setAttribute("title","Switch / VLAN");
  a.textContent="Switch / VLAN";
  a.addEventListener("click",e=>{e.preventDefault();location.href=managedUrl()});
  return a;
};
const findIptv=()=>{
  const nodes=document.querySelectorAll('a[href],[data-route],[data-name],[data-menu],[title]');
  for(const e of nodes){
    const s=[e.getAttribute("href"),e.getAttribute("data-route"),e.getAttribute("data-name"),
      e.getAttribute("data-menu"),e.getAttribute("title"),e.textContent].filter(Boolean).join(" ");
    if(/iptv|vlan/i.test(s))return e;
  }
  return null;
};
const insertBeside=e=>{
  const anchor=e.tagName==="A"?e:(e.querySelector&&e.querySelector("a[href]"));
  if(!anchor)return false;
  const parent=anchor.closest&&anchor.closest("li");
  if(parent&&parent.parentNode){
    const wrapper=parent.cloneNode(false);
    wrapper.removeAttribute("id");wrapper.removeAttribute("data-key");
    const a=wire(anchor.cloneNode(false));wrapper.appendChild(a);
    parent.parentNode.insertBefore(wrapper,parent.nextSibling);return true;
  }
  if(anchor.parentNode){
    const a=wire(anchor.cloneNode(false));anchor.parentNode.insertBefore(a,anchor.nextSibling);return true;
  }
  return false;
};
const fallback=()=>{
  const host=document.querySelector("nav ul,aside ul,[class*=menu] ul,[class*=sidebar] ul");
  if(!host)return false;
  const sample=host.lastElementChild;
  const li=sample?sample.cloneNode(false):document.createElement("li");
  li.removeAttribute&&li.removeAttribute("id");li.removeAttribute&&li.removeAttribute("data-key");
  const sampleA=sample&&sample.querySelector&&sample.querySelector("a[href]");
  const a=wire(sampleA?sampleA.cloneNode(false):document.createElement("a"));
  li.appendChild(a);host.appendChild(li);return true;
};
const inject=()=>{
  if(document.getElementById(ID))return true;
  const iptv=findIptv();return iptv?insertBeside(iptv):fallback();
};
let attempts=0;
const retry=()=>{if(inject()||attempts++>40)return;setTimeout(retry,250)};
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",retry,{once:true});else retry();
new MutationObserver(()=>{if(!document.getElementById(ID))inject()})
  .observe(document.documentElement,{childList:true,subtree:true});
window.addEventListener("hashchange",()=>setTimeout(inject,50));
})();
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


def validate(text: str) -> None:
    required = (MARKER, "ax53-managed-switch-menu", "/webpages/managed-switch.html", "Switch / VLAN", "MutationObserver")
    missing = [token for token in required if token not in text]
    if missing:
        raise SystemExit("Error: managed-switch menu injection incomplete: " + ", ".join(missing))
    if text.count(MARKER) != 1:
        raise SystemExit(f"Error: managed-switch menu marker count is {text.count(MARKER)}, expected 1")


def main() -> None:
    text = read_bundle()
    if MARKER not in text:
        text = text.rstrip() + "\n" + INJECTOR.strip() + "\n"
        write_bundle(text)
        text = read_bundle()
    validate(text)
    print(f"Managed Switch menu launcher installed: {BUNDLE}")


if __name__ == "__main__":
    main()
