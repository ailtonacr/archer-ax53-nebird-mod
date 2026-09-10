#!/usr/bin/env python3
"""Validate the authored TP-Link native NetBird subform contract.

The form does not intercept TP-Link Save. setup_key is a transient provider
field included in the normal stock Save payload and consumed by VPN_CFG_TBL;
it is never persisted by the stock profile schema.
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
    'setup_key: setupKey.value || ""',
    'stockComponent(this, "su-form")',
    'stockComponent(this, "su-form-item")',
    'stockComponent(this, "su-input")',
    'stockComponent(this, "su-password")',
    'stockComponent(this, "su-checkbox")',
    'stockComponent(this, "su-button")',
    's.advertise_lan === "1" && s.disable_server_routes !== "0"',
    's.advertise_lan === "1" && s.disable_firewall !== "0"',
    'draft.value.disable_firewall = "0"',
    'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
    '_h(SuForm, { model: s }, { default: () => items })',
    'Permitir roteamento da LAN',
]
missing = [token for token in required if token not in text]
if missing:
    raise RuntimeError("native form contract incomplete: " + ", ".join(missing))

forbidden = [
    '"label-width": { span: 10 }',
    '"content-width": { span: 14 }',
    'async function enroll()',
    'async function afterStockSave()',
    "syncNativeSaveButton",
    "netbirdSaveSyncTimer",
    "data-netbird-dirty",
    "__netbirdSaveListener",
    "stopImmediatePropagation",
    "NETBIRD_CSS",
    'type: "checkbox"',
    'class: "netbird-input"',
    'Anunciar rede local',
]
leaked = [token for token in forbidden if token in text]
if leaked:
    raise RuntimeError("obsolete/custom form implementation leaked: " + ", ".join(leaked))

check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
if check.returncode:
    raise RuntimeError("node --check failed for NetBird form:\n" + check.stderr.decode()[:2000])

print("NetBird TP-Link stock-save/transient-setup-key form contract verified")
