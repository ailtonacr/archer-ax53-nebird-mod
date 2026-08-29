#!/usr/bin/env python3
"""Validate the authored TP-Link native subform contract.

The form no longer relies on DOM Save interception or post-build structural
rewrites. This stage is retained in the existing pipeline as a fail-fast check
that the source still exposes exactly what VpnServerFormDialog consumes.
"""
from __future__ import annotations

import gzip
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
PATH = os.path.join(ROOT, "www/webpages/js/VpnServerNetbirdForm-NB.js.gz")

with gzip.open(PATH, "rt", encoding="utf-8") as fh:
    text = fh.read()

required = [
    "context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })",
    "throw new Error(error.value)",
    'management_url: s.management_url || ""',
    'wireguard_port: s.wireguard_port || "51820"',
    'stockComponent(this, "su-form")',
    'stockComponent(this, "su-form-item")',
    'stockComponent(this, "su-input")',
    'stockComponent(this, "su-checkbox")',
    'stockComponent(this, "su-button")',
]
missing = [token for token in required if token not in text]
if missing:
    raise RuntimeError("native form contract incomplete: " + ", ".join(missing))

forbidden = [
    "syncNativeSaveButton",
    "netbirdSaveSyncTimer",
    "data-netbird-dirty",
    "__netbirdSaveListener",
    "stopImmediatePropagation",
    "NETBIRD_CSS",
    'type: "checkbox"',
    'class: "netbird-input"',
]
leaked = [token for token in forbidden if token in text]
if leaked:
    raise RuntimeError("legacy/custom form implementation leaked: " + ", ".join(leaked))

check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
if check.returncode:
    raise RuntimeError("node --check failed for NetBird form:\n" + check.stderr.decode()[:2000])

print("NetBird TP-Link native form contract verified")
