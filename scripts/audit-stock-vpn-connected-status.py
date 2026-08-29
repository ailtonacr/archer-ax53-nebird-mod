#!/usr/bin/env python3
"""Read-only audit of TP-Link VPN Client connected-status/ping flow.

Run against an unpacked STOCK rootfs. This script does not modify the rootfs.
It extracts the native model function used by VpnServerStatus and backend hints
so NetBird can implement the exact same UI/data contract without replacing the
stock tooltip/component.
"""
from __future__ import annotations

import gzip
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
JS = ROOT / "www/webpages/js"
INDEX = JS / "index-DTNtPvwx.js.gz"
MODEL = JS / "model-CI6Gt3Hz.js.gz"
OUT = pathlib.Path("work/native-vpn-connected-status-audit.txt")


def read_gz(path: pathlib.Path) -> str:
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return fh.read()


def contexts(text: str, needle: str, radius: int = 1200) -> list[str]:
    out = []
    start = 0
    while True:
        pos = text.find(needle, start)
        if pos < 0:
            break
        out.append(text[max(0, pos-radius): min(len(text), pos+len(needle)+radius)])
        start = pos + len(needle)
    return out


def main() -> None:
    if not INDEX.exists() or not MODEL.exists():
        raise SystemExit(f"missing stock bundles under {JS}")
    index = read_gz(INDEX)
    model = read_gz(MODEL)

    chunks: list[str] = []
    chunks.append("TP-Link AX53 stock VPN connected-status audit")
    chunks.append(f"rootfs={ROOT}")

    # Capture the native VpnServerStatus caller and its import neighborhood.
    for needle in ("connectedStatus", "handleInit", "common.ping", "openVpn.serverAddress"):
        hits = contexts(index, needle)
        chunks.append(f"\n===== index needle {needle!r}: {len(hits)} hit(s) =====")
        chunks.extend(hits[:6])

    # Find model strings/functions that mention fields returned by the tooltip,
    # ping/status-ish forms, and likely server-status endpoints.
    for needle in (
        'ping', 'address', 'dns', 'server_status', 'serverStatus',
        'connected_status', 'connectedStatus', 'status', 'form=',
    ):
        hits = contexts(model, needle, 1600)
        chunks.append(f"\n===== model needle {needle!r}: {len(hits)} hit(s) =====")
        chunks.extend(hits[:12])

    # Also capture every /admin/vpn-ish literal from the model with context.
    urls = sorted(set(re.findall(r'[^\"\']*/admin/vpn[^\"\']*', model)))
    chunks.append("\n===== model /admin/vpn literals =====")
    chunks.extend(urls or ["(none as literal; endpoint may be assembled)"])

    # Bytecode controller is stock and deliberately untouched. `strings` is
    # enough to reveal operation/form names without decompiling or modifying it.
    controller = ROOT / "usr/lib/lua/luci/controller/admin/vpn.lua"
    if controller.exists():
        try:
            proc = subprocess.run(["strings", str(controller)], capture_output=True, text=True, check=False)
            lines = [line for line in proc.stdout.splitlines() if re.search(r'ping|dns|address|status|server|vpn', line, re.I)]
            chunks.append("\n===== stock vpn.lua relevant strings =====")
            chunks.extend(lines[:300])
        except FileNotFoundError:
            chunks.append("\n===== stock vpn.lua relevant strings =====\nstrings(1) unavailable")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(chunks), encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
