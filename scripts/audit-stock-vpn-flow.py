#!/usr/bin/env python3
"""Extract the native TP-Link VPN Client form/save contract from a stock rootfs.

This is a read-only diagnostic tool. It does not patch the firmware. The goal is
to inspect the exact stock bundle used by this repository before changing the
NetBird integration again.
"""
from __future__ import annotations

import gzip
import os
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "rootfs")
JS = ROOT / "www/webpages/js"
INDEX = JS / "index-DTNtPvwx.js.gz"
OUT = Path("work/native-vpn-flow-audit.txt")

if not INDEX.is_file():
    raise SystemExit(f"missing stock VPN page bundle: {INDEX}")

text = gzip.decompress(INDEX.read_bytes()).decode("utf-8")

# Deliberately broad markers: we want evidence from the exact stock bundle,
# including minified variable names, not assumptions embedded in the NetBird
# patchers.
MARKERS = [
    ("dynamic form selector", "case it.Wireguard:return"),
    ("stock add/edit save backend", '"add"==='),
    ("getForm contract", "getForm"),
    ("validate contract", "validate"),
    ("setForm contract", "setForm"),
    ("resetForm contract", "resetForm"),
    ("clearValidate contract", "clearValidate"),
    ("form component ref", ".value.getForm"),
    ("form validate ref", ".value.validate"),
    ("dialog footer", "su-dialog-footer"),
    ("button disabled state", "disabled:"),
    ("change event", 'onChange'),
    ("update model event", 'onUpdate:'),
    ("update:modelValue event", 'onUpdate:modelValue'),
    ("WireGuard token", "Wireguard"),
]


def contexts(label: str, needle: str, radius: int = 2200) -> list[str]:
    hits = [m.start() for m in re.finditer(re.escape(needle), text)]
    chunks = []
    for idx, pos in enumerate(hits[:12], 1):
        lo = max(0, pos - radius)
        hi = min(len(text), pos + len(needle) + radius)
        chunks.append(
            f"\n===== {label} | hit {idx}/{len(hits)} | offset {pos} =====\n"
            + text[lo:hi]
            + "\n"
        )
    if not hits:
        chunks.append(f"\n===== {label} | 0 hits for {needle!r} =====\n")
    return chunks

report = [
    "TP-Link AX53 stock VPN Client native-flow audit\n",
    f"rootfs={ROOT}\n",
    f"bundle={INDEX}\n",
    f"bundle_chars={len(text)}\n",
]

for label, needle in MARKERS:
    report.extend(contexts(label, needle))

# Also record function-sized neighborhoods around the known stock save call if
# present. This is intentionally not parsed as JavaScript; the minified code is
# retained verbatim so subsequent reasoning is grounded in the shipped bundle.
for needle in (
    'await Ce(',
    'await ne(',
    'case it.Wireguard:return',
):
    for pos in [m.start() for m in re.finditer(re.escape(needle), text)][:12]:
        lo = max(0, text.rfind("function", max(0, pos - 8000), pos))
        hi_candidates = [p for p in (text.find("function", pos + 1), text.find("export", pos + 1)) if p != -1]
        hi = min(hi_candidates) if hi_candidates else min(len(text), pos + 8000)
        report.append(f"\n===== function neighborhood for {needle!r} @ {pos} =====\n{text[lo:hi]}\n")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("".join(report), encoding="utf-8")
print(f"wrote {OUT}")
print("marker counts:")
for label, needle in MARKERS:
    print(f"  {label}: {text.count(needle)}")
