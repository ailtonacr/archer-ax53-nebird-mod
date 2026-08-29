#!/usr/bin/env python3
"""Validate CREATE/EDIT semantics already authored in the NetBird subform.

Historical versions rewrote the generated form by exact string substitution.
The native stock-component form now owns these semantics directly, so this
pipeline stage remains only as a fail-fast compatibility check.
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
    "const creating = ref(false)",
    'value.type === "netbirdvpn"',
    'creating.value = !existing',
    'draft.value.enable = "0"',
    'draft.value.enrolled = "0"',
    'creating.value && profileExists.value',
]
missing = [token for token in required if token not in text]
if missing:
    raise RuntimeError("native CREATE/EDIT contract incomplete: " + ", ".join(missing))

check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
if check.returncode:
    raise RuntimeError("node --check failed for NetBird form:\n" + check.stderr.decode()[:2000])

print("NetBird CREATE/EDIT native source contract verified")
