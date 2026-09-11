#!/usr/bin/env python3
"""Validate CREATE/EDIT semantics authored directly in the NetBird subform.

Only a persisted stock key/id switches the protocol subform to Edit mode.
CREATE stages the Setup Key outside the stock payload and carries only an opaque
enrollment_token. EDIT asks the backend whether profile identity really exists,
so an enrolled profile saves with no Setup Key. Enrollment itself is deferred
to the native netifd lifecycle after stock Save returns.
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
    'profileKey.value = existing ? String(value.key || value.id) : ""',
    'draft.value.enable = "0"',
    'draft.value.enrolled = "0"',
    'if (!profileKey.value || creating.value || statusRequestPending) return',
    'const identityPresent = ref(null)',
    'identityPresent.value = !!r.identityPresent',
    'if (!creating.value && hasIdentity === null && profileKey.value)',
    '(creating.value || !hasIdentity) && !setupKey.value',
    'const enrollmentHandedOff = ref(false)',
    'if (enrollmentToken.value) enrollmentHandedOff.value = true',
    'staleToken && !enrollmentHandedOff.value',
    'enrollment_token: enrollmentToken.value || ""',
    'stage_setup_key',
    'A identidade deste perfil já existe. Nenhuma Setup Key é necessária para editar estas configurações.',
    's.advertise_lan === "1" && s.disable_server_routes !== "0"',
    's.advertise_lan === "1" && s.disable_firewall !== "0"',
    'draft.value.disable_firewall = "0"',
    'Permitir roteamento da LAN',
]
missing = [token for token in required if token not in text]
if missing:
    raise RuntimeError("native CREATE/EDIT/provider boundary incomplete: " + ", ".join(missing))

forbidden = [
    'async function enroll()', 'async function afterStockSave()', 'setup_key: setupKey.value || ""',
    'value.type === "netbirdvpn"', 'value.type === "netbird"',
    "const creating = ref(false)", 'Anunciar rede local', 'Já existe um perfil NetBird',
    'enable: s.enable === "1" ? "on" : "off"',
]
leaked = [token for token in forbidden if token in text]
if leaked:
    raise RuntimeError("generic/type-derived NetBird form semantics leaked: " + ", ".join(leaked))

check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
if check.returncode:
    raise RuntimeError("node --check failed for NetBird form:\n" + check.stderr.decode()[:2000])

print("NetBird stock-owned CREATE/EDIT + identity-aware deferred-enrollment contract verified")
