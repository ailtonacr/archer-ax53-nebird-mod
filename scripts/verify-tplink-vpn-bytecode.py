#!/usr/bin/env python3
"""Verify the stock TP-Link vpn.lua bytecode contract used by native NetBird.

The AX53 controller is Lua 5.1/LNUM bytecode with TP-Link's shuffled opcode
order. Native NetBird deliberately leaves that chunk byte-for-byte stock and
extends its module-global registries at LuCI controller load time. This verifier
fails the firmware build if a different stock base makes that assumption false.

Only the top-level prototype/code/constants are parsed; nested prototypes are
irrelevant for proving that VPN_TBL/VPN_CFG_TBL/VPN_TYPE_TBL/
VPN_TYPE_NAME_TBL are exported with SETGLOBAL.
"""
from __future__ import annotations

import pathlib
import struct
import sys

EXPECTED_HEADER = bytes.fromhex("1b4c75615100010404040804")
# TP-Link shuffled opcode index recovered from the GPL Lua source.
OP_SETGLOBAL = 2
REGISTRIES = {
    "VPN_TBL",
    "VPN_CFG_TBL",
    "VPN_TYPE_TBL",
    "VPN_TYPE_NAME_TBL",
}
STOCK_TYPES = {"pptpvpn", "l2tpvpn", "openvpn", "wireguardvpn"}


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.off = 0

    def take(self, n: int) -> bytes:
        end = self.off + n
        if end > len(self.data):
            raise ValueError(f"truncated Lua chunk at offset {self.off}")
        out = self.data[self.off:end]
        self.off = end
        return out

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def string(self) -> str | None:
        n = self.u32()
        if n == 0:
            return None
        raw = self.take(n)
        if not raw.endswith(b"\x00"):
            raise ValueError("Lua string is not NUL terminated")
        return raw[:-1].decode("utf-8", errors="replace")


def parse_top_level(path: pathlib.Path) -> tuple[list[int], list[object]]:
    data = path.read_bytes()
    if data[:12] != EXPECTED_HEADER:
        raise ValueError(
            "unexpected TP-Link Lua header: "
            f"{data[:12].hex()} != {EXPECTED_HEADER.hex()}"
        )

    r = Reader(data)
    r.take(12)
    r.string()  # source
    r.u32()  # linedefined
    r.u32()  # lastlinedefined
    r.take(4)  # nups, numparams, is_vararg, maxstacksize

    sizecode = r.u32()
    if not 1 <= sizecode <= 100000:
        raise ValueError(f"implausible top-level instruction count: {sizecode}")
    code = [r.u32() for _ in range(sizecode)]

    sizek = r.u32()
    if not 1 <= sizek <= 100000:
        raise ValueError(f"implausible top-level constant count: {sizek}")

    constants: list[object] = []
    for _ in range(sizek):
        tag = r.u8()
        if tag == 0:  # LUA_TNIL
            constants.append(None)
        elif tag == 1:  # LUA_TBOOLEAN
            constants.append(bool(r.u8()))
        elif tag == 3:  # LUA_TNUMBER
            constants.append(struct.unpack("<d", r.take(8))[0])
        elif tag == 4:  # LUA_TSTRING
            constants.append(r.string())
        elif tag == 9:  # LNUM integer constant in this TP-Link build
            constants.append(struct.unpack("<i", r.take(4))[0])
        else:
            raise ValueError(f"unsupported top-level constant tag {tag} at offset {r.off - 1}")

    return code, constants


def opcode(insn: int) -> int:
    return insn & 0x3F


def arg_bx(insn: int) -> int:
    return (insn >> 14) & 0x3FFFF


def verify(path: pathlib.Path) -> None:
    code, constants = parse_top_level(path)

    string_constants = {x for x in constants if isinstance(x, str)}
    missing_types = sorted(STOCK_TYPES - string_constants)
    if missing_types:
        raise ValueError("stock VPN type constants missing: " + ", ".join(missing_types))

    exported: set[str] = set()
    for insn in code:
        if opcode(insn) != OP_SETGLOBAL:
            continue
        idx = arg_bx(insn)
        if idx >= len(constants):
            raise ValueError(f"SETGLOBAL references out-of-range constant K{idx}")
        name = constants[idx]
        if isinstance(name, str) and name in REGISTRIES:
            exported.add(name)

    missing = sorted(REGISTRIES - exported)
    if missing:
        raise ValueError(
            "native NetBird cannot safely extend this vpn.lua: module-global "
            "registry export(s) missing: " + ", ".join(missing)
        )

    print(
        "TP-Link VPN bytecode contract ok: "
        + ", ".join(sorted(exported))
        + "; stock types="
        + ",".join(sorted(STOCK_TYPES))
    )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <vpn.lua>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    try:
        verify(path)
    except (OSError, ValueError, struct.error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
