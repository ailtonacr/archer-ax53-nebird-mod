#!/usr/bin/env python3
"""Install the managed-switch SPA module and register it in the stock TP-Link menu/router model.

Reverse engineering of the AX53 bundle showed two independent stock contracts:
- route components are declared in the `k` route table as {name,path,component};
- visible navigation comes from the `navConfig` store and is a tree of
  {key,text,children} nodes whose leaf `key` matches a route name.

The managed-switch integration therefore patches those models before render.
It never clones rendered DOM nodes and never uses MutationObserver/polling.
"""
from __future__ import annotations

import gzip
import hashlib
import io
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "www/webpages/js/index-D26yCMJF.js.gz"
SOURCE = PROJECT_ROOT / "src/web/ManagedSwitchPage-AX.js"
MODULE_DST = ROOT / "www/webpages/js/ManagedSwitchPage-AX.js.gz"

LEGACY_MARKER = "__AX53_MANAGED_SWITCH_MENU__"
LEGACY_BEGIN = "/*__AX53_MANAGED_SWITCH_MENU_BEGIN__*/"
LEGACY_END = "/*__AX53_MANAGED_SWITCH_MENU_END__*/"

NATIVE_MARKER = "/*__AX53_MANAGED_SWITCH_NATIVE_MENU_V6__*/"
ROUTE_NAME = "managedSwitch"
ROUTE_PATH = "managedSwitch"
MENU_TEXT = "Switch / VLAN"

ROUTE_END_ANCHOR = '];class H{static getTopMenuInfo'
NAV_CONFIG_ANCHOR = 'const de=t("navConfig"'
MODE_MENU_OLD = (
    's=i((()=>{const e=t.value.supportOperationMode[0];'
    'return a.value[r.value]||a.value[e]||[]}))'
)
MODE_MENU_NEW = (
    's=i((()=>{const e=t.value.supportOperationMode[0],'
    'n=a.value[r.value]||a.value[e]||[];'
    'return ax53ManagedSwitchMenu(n),n}))'
)
VISIBLE_MENU_ANCHOR = (
    'u=i((()=>{const e=[...t.value.hiddenFunction.modules,'
    '...oe.getToHideModules(n.value),...le.getHideMenus()];'
    'return H.getExcludedMenu(s.value,e)}))'
)
MENU_HELPER = (
    'function ax53ManagedSwitchMenu(e){for(const t of e){'
    'if(!Array.isArray(t.children))continue;'
    'const n=t.children.findIndex((e=>"iptvAdv"===e.key));'
    'if(n>=0){return t.children.some((e=>"managedSwitch"===e.key))'
    '||t.children.splice(n+1,0,{key:"managedSwitch",text:"Switch / VLAN"}),!0}'
    'if(ax53ManagedSwitchMenu(t.children))return!0}return!1}'
)


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
        raise SystemExit(
            f"Error: node --check failed for {name}:\n"
            f"{result.stderr.decode()[:2000]}"
        )


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
        raise SystemExit(
            "Error: managed-switch module is not using stock API contract: "
            + ", ".join(missing)
        )
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


def strip_legacy_dom_injector(text: str) -> str:
    """Remove only the retired DOM-cloning launcher from older builds."""
    if LEGACY_BEGIN in text:
        start = text.rfind(LEGACY_BEGIN)
        end = text.find(LEGACY_END, start)
        if end < 0:
            raise SystemExit(
                "Error: legacy managed-switch menu BEGIN marker has no END marker"
            )
        text = (text[:start] + text[end + len(LEGACY_END):]).rstrip() + "\n"

    elif LEGACY_MARKER in text:
        marker_pos = text.rfind(LEGACY_MARKER)
        start = text.rfind(';(()=>{"use strict";', 0, marker_pos)
        if start < 0:
            raise SystemExit(
                "Error: found legacy managed-switch marker but cannot locate injector safely"
            )
        text = text[:start].rstrip() + "\n"

    return text


def route_entry(module_spec: str) -> str:
    """Return a normal stock-style route declaration.

    The component wrapper owns only lifecycle glue:
    - mount the already-authored managed-switch page;
    - make its Voltar button navigate back through the stock router;
    - remove the fixed overlay when the route is unmounted.
    """
    return (
        '{name:"managedSwitch",path:"managedSwitch",component:()=>C((()=>import("'
        + module_spec
        + '").then((e=>({name:"ManagedSwitchRoute",mounted(){'
        'const t=e.openManagedSwitch();if(t&&t.querySelector){'
        'const e=t.querySelector(\'[data-act="close"]\');'
        'e&&(e.onclick=()=>window.history.back())}},'
        'beforeUnmount(){const e=document.getElementById("ax53-managed-switch-page");'
        'e&&(document.body.style.overflow="",e.remove())},'
        'render(){return null}})))),[],import.meta.url)}'
    )


def install_native_menu(text: str, module_spec: str) -> str:
    """Patch the stock route table and navConfig tree, never the rendered DOM."""
    route = route_entry(module_spec)

    if NATIVE_MARKER in text:
        # Idempotent rerun. Only refresh the cache-busting module URL when source
        # changed; the structural patch itself must already be complete.
        pattern = re.compile(
            r'\./ManagedSwitchPage-AX\.js\?v=[0-9a-f]{12}'
        )
        matches = pattern.findall(text)
        if len(matches) != 1:
            raise SystemExit(
                "Error: native managed-switch route exists but module import is ambiguous"
            )
        return pattern.sub(module_spec, text, count=1)

    if text.count(ROUTE_END_ANCHOR) != 1:
        raise SystemExit(
            "Error: stock TP-Link route-table anchor changed; refusing blind menu patch"
        )
    if text.count(NAV_CONFIG_ANCHOR) != 1:
        raise SystemExit(
            "Error: stock TP-Link navConfig anchor changed; refusing blind menu patch"
        )
    if text.count(MODE_MENU_OLD) != 1:
        raise SystemExit(
            "Error: stock TP-Link mode-menu contract changed; refusing blind menu patch"
        )
    if text.count(VISIBLE_MENU_ANCHOR) != 1:
        raise SystemExit(
            "Error: stock TP-Link visible-menu filter changed; refusing blind menu patch"
        )
    if 'name:"managedSwitch"' in text or 'key:"managedSwitch"' in text:
        raise SystemExit(
            "Error: managed-switch route/menu token exists without native marker"
        )

    text = text.replace(
        ROUTE_END_ANCHOR,
        "," + NATIVE_MARKER + route + ROUTE_END_ANCHOR,
        1,
    )
    text = text.replace(
        NAV_CONFIG_ANCHOR,
        MENU_HELPER + ";" + NAV_CONFIG_ANCHOR,
        1,
    )
    text = text.replace(MODE_MENU_OLD, MODE_MENU_NEW, 1)
    return text


def validate(text: str, module_spec: str) -> None:
    required = (
        NATIVE_MARKER,
        'name:"managedSwitch"',
        'path:"managedSwitch"',
        module_spec,
        "ManagedSwitchRoute",
        "ax53ManagedSwitchMenu",
        'findIndex((e=>"iptvAdv"===e.key))',
        '{key:"managedSwitch",text:"Switch / VLAN"}',
        'return ax53ManagedSwitchMenu(n),n',
        VISIBLE_MENU_ANCHOR,
        'e.openManagedSwitch()',
        'window.history.back()',
    )
    missing = [x for x in required if x not in text]
    if missing:
        raise SystemExit(
            "Error: native managed-switch route/menu patch incomplete: "
            + ", ".join(missing)
        )

    if text.count(NATIVE_MARKER) != 1:
        raise SystemExit("Error: native managed-switch marker must exist exactly once")
    if text.count('name:"managedSwitch"') != 1:
        raise SystemExit("Error: managed-switch route must exist exactly once")
    if text.count('key:"managedSwitch"') != 1:
        raise SystemExit("Error: managed-switch menu node must exist exactly once")
    if text.count(module_spec) != 1:
        raise SystemExit("Error: managed-switch route module import must exist exactly once")

    forbidden = (
        LEGACY_MARKER,
        LEGACY_BEGIN,
        LEGACY_END,
        "MutationObserver",
        "cloneNode(",
        "leafIptv",
        "rowFor",
        "/webpages/managed-switch.html",
    )
    leaked = [x for x in forbidden if x in text]
    if leaked:
        raise SystemExit(
            "Error: retired DOM/standalone managed-switch integration remains: "
            + ", ".join(leaked)
        )


def main() -> None:
    module_spec = install_module()
    text = strip_legacy_dom_injector(read_bundle())
    text = install_native_menu(text, module_spec)
    check_js(str(BUNDLE), text)
    write_bundle(text)

    final = read_bundle()
    validate(final, module_spec)
    print(f"Managed Switch stock-context module installed: {MODULE_DST}")
    print(
        "Managed Switch registered in native TP-Link route/nav model: "
        f"{BUNDLE}"
    )


if __name__ == "__main__":
    main()
