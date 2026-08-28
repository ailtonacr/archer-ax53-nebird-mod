#!/usr/bin/env python3
"""Offline contract checks for the AX53 NetBird integration.

These tests intentionally cover the boundary that the component-only JS test
cannot: representative flat/nested/JSON request envelopes, dispatcher hardening,
identity reconciliation and build-source canonicalization. They do not claim to
emulate TP-Link's compiled controller bytecode; hardware validation remains the
final authority.
"""
from __future__ import annotations

import json
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "src/web-backend/controller/admin/vpn_netbird_adapter.lua"
NB_CONTROLLER = ROOT / "src/web-backend/controller/admin/netbird.lua"
MOD = ROOT / "mods/010-netbird.sh"

PRIORITY_KEYS = (
    "new", "data", "profile", "server", "item", "record", "value",
    "form", "params", "payload", "config", "old",
)
MAX_DEPTH = 6


def normalized(value):
    if isinstance(value, list):
        value = value[-1] if value else None
    return str(value).lower() if value is not None else None


def table_is_netbird(value):
    if not isinstance(value, dict):
        return False
    key = normalized(value.get("key") or value.get("id") or value.get("name"))
    typ = normalized(value.get("type") or value.get("proto") or value.get("vpntype") or value.get("client_type"))
    return key == "netbird" or typ == "netbird"


def decode_json_table(value):
    if not isinstance(value, str) or not value.lstrip().startswith(("{", "[")):
        return None
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError:
        return None
    return decoded if isinstance(decoded, (dict, list)) else None


def scan(value, depth=0, seen=None):
    if depth > MAX_DEPTH:
        return None
    seen = seen or set()
    if isinstance(value, str):
        decoded = decode_json_table(value)
        return scan(decoded, depth, seen) if decoded is not None else None
    if isinstance(value, list):
        for item in value:
            found = scan(item, depth + 1, seen)
            if found:
                return found
        return None
    if not isinstance(value, dict):
        return None
    marker = id(value)
    if marker in seen:
        return None
    seen.add(marker)
    if table_is_netbird(value):
        return value
    for key in PRIORITY_KEYS:
        if key in value:
            found = scan(value[key], depth + 1, seen)
            if found:
                return found
    for key, item in value.items():
        if key not in PRIORITY_KEYS and isinstance(item, (dict, list, str)):
            found = scan(item, depth + 1, seen)
            if found:
                return found
    return None


def check_envelopes():
    flat = {"operation": "insert", "key": "netbird", "type": "netbird", "server": "https://netbird.example"}
    assert scan(flat) is flat

    nested = {"operation": "insert", "data": {"key": "netbird", "type": "netbird", "server": "https://netbird.example"}}
    assert scan(nested)["type"] == "netbird"

    serialized = {"operation": "insert", "data": json.dumps({"key": "netbird", "type": "netbird", "advertise_cidr": "192.168.10.0/24"})}
    assert scan(serialized)["advertise_cidr"] == "192.168.10.0/24"

    update = {
        "operation": "update",
        "old": {"key": "netbird", "type": "netbird", "server": "https://old.example"},
        "new": {"key": "netbird", "type": "netbird", "server": "https://new.example"},
    }
    assert scan(update)["server"] == "https://new.example", "new profile must win over old profile"

    wrapped = {"params": {"payload": {"record": {"client_type": "netbird", "management_url": "https://netbird.example"}}}}
    assert scan(wrapped)["management_url"] == "https://netbird.example"

    non_netbird = {"operation": "insert", "data": {"key": "wg1", "type": "wireguard", "server": "vpn.example"}}
    assert scan(non_netbird) is None


def check_source_contracts():
    adapter = ADAPTER.read_text()
    required = (
        'local json    = require "luci.json"',
        "decode_json_table",
        "PRIORITY_KEYS",
        '"new", "data", "profile"',
        "request_context",
        "direct_request_is_netbird",
        "safe_netbird",
        "patch_dispatch_upvalues",
        "debug.getupvalue",
        "debug.setupvalue",
        "/tmp/netbird-vpn-adapter.log",
    )
    for token in required:
        assert token in adapter, f"adapter contract missing {token!r}"
    assert "setup_key" not in adapter.split("local function trace", 1)[1].split("local function request_body", 1)[0], "trace function must not log setup keys"

    controller = NB_CONTROLLER.read_text()
    assert "local function identity_present()" in controller
    assert 'lfs.readfile("/tp_data/netbird/default.json")' in controller
    assert 'if identity_present() and settings.enrolled ~= "1"' in controller

    mod = MOD.read_text()
    assert 'RUNTIME_SRC="$PROJECT_ROOT/src/init"' in mod
    assert 'cp "$RUNTIME_SRC/netbird-ctl" "$R/sbin/netbird-ctl"' in mod
    assert 'cp "$RUNTIME_SRC/netbird.sh" "$R/lib/netbird/netbird.sh"' in mod
    assert 'cp "$RUNTIME_SRC/netbird.init" "$R/etc/init.d/netbird"' in mod
    assert "patch_dispatch_upvalues" in mod

    mirrors = (
        ROOT / "mods/010-netbird-files/sbin/netbird-ctl",
        ROOT / "mods/010-netbird-files/lib/netbird/netbird.sh",
        ROOT / "mods/010-netbird-files/etc/init.d/netbird",
    )
    for mirror in mirrors:
        assert not mirror.exists(), f"stale runtime mirror must be removed: {mirror}"


def main():
    check_envelopes()
    check_source_contracts()
    print("netbird request/dispatcher/reconciliation/build contracts ok")


if __name__ == "__main__":
    main()
