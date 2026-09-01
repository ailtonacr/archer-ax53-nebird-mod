#!/usr/bin/env python3
"""Validate CREATE/EDIT semantics authored directly in the NetBird subform.

A NetBird type value exists in both Add and Edit. Only a persisted stock key/id
may switch the protocol subform to Edit mode. This stage intentionally performs
no rewrite: source and shipped semantics must stay identical.
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
    "const creating = ref(true)",
    "const existing = !!(value && (value.key || value.id))",
    "creating.value = !existing",
    'draft.value.enable = "0"',
    'draft.value.enrolled = "0"',
    'creating.value && profileExists.value',
    's.advertise_lan === "1" && s.disable_server_routes !== "0"',
    's.advertise_lan === "1" && s.disable_firewall !== "0"',
    'draft.value.disable_firewall = "0"',
    'Permitir roteamento da LAN',
]
missing = [token for token in required if token not in text]
if missing:
    raise RuntimeError("native CREATE/EDIT/routing contract incomplete: " + ", ".join(missing))

forbidden = [
    'value.type === "netbirdvpn"',
    'value.type === "netbird"',
    "const creating = ref(false)",
    'Anunciar rede local',
]
leaked = [token for token in forbidden if token in text]
if leaked:
    raise RuntimeError("type-derived/misleading NetBird form semantics leaked: " + ", ".join(leaked))

check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
if check.returncode:
    raise RuntimeError("node --check failed for NetBird form:\n" + check.stderr.decode()[:2000])

print("NetBird CREATE/EDIT and ACL-safe routing source contract verified")
