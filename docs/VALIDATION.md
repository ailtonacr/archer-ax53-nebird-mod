# NetBird on Archer AX53 V1 — Offline Validation

All checks below were run offline (host, no device). Results as of 2026-08-26.

## Shell

`bash -n` on every added/modified shell file:

| File | Result |
|---|---|
| `sbin/netbird-ctl` | OK |
| `lib/netbird/netbird.sh` | OK |
| `etc/init.d/netbird` | OK |
| `sbin/fw` (patched) | OK |
| `sbin/reset` (patched) | OK |
| `lib/firewall/tpcmd.sh` (patched) | OK |

## Lua (source modules)

`luaparser` parse on both added modules: **OK**
`usr/lib/lua/luci/controller/admin/netbird.lua`, `usr/lib/lua/luci/model/netbird.lua`.

## Frontend (patched Vue bundles)

`node --input-type=module --check` on decompressed bundles:

| File | Result |
|---|---|
| `update-store-DQkZxaRI.js` | OK |
| `util-JEiJiY0O.js` | OK |
| `model-CI6Gt3Hz.js` | OK |
| `index-DTNtPvwx.js` | OK |
| `VpnServerNetbirdForm-NB.js` | OK |

Patch presence (verified in decompressed output): `e.Netbird="netbird"` enum,
`typeNetbird` i18n, `[t.Netbird, ...]` getType map, `nbStatus/nbSettingsSet/...`
model RPC, `case it.Netbird:return VpnServerNetbirdForm` switch, `Dt()` filter,
client-list injection, generic-save skip for `netbird`, 27/27 locale bundles.

## MIBIB

`mibib-netbird.bin` is generated ONLY via `mibib/make-mibib.sh` (regenerates
from `mibib-original.bin` with `mibib_tool.py patch()`, which updates BOTH the
system and user partition tables and recalculates the footer CRC), and is
gated by three independent checks: `mibib_tool.py show`, `mibib_check.pl`, and
`mibib_verify.py` (a committed read-only re-implementation that re-derives the
CRC bitwise). A previous hand-patched artifact had a stale CRC and an
un-updated user partition table (count 16); it was rejected by
`mibib_tool.py show` and replaced. See `mibib/make-mibib.sh` for the process.

Current artifact: sha256 `d5e7a4f78a2164e3cc651271828c14dcc5c85af324c8d83412b0ebfe097d63f5`
— **17 entries**, system + user tables (count 17 in both copies), footer CRC
valid in both copies (copy 0 `774dac3d`, copy 1 `dabbcca0`), copies identical,
no overlap. `netbird_data` at `start=0x06740000 size=0x01000000
end=0x07740000` (start_eb 826, len 128). `rootfs`/`rootfs_1`/`tp_data`/
`radio`/`data` geometry **unchanged** vs original.

## Payload (R2 runtime)

| Field | Value |
|---|---|
| R2 bucket | `ax53-netbird` |
| Object | `netbird/0.77.1/linux-armv6/netbird-dict8.xz` |
| Public URL | `https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/netbird-dict8.xz` |
| compressed SHA-256 | `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941` |
| decoded SHA-256 (v0.77.1) | `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6` |
| `xzmini` (ARMv7 static-pie) | `b0d7464d643bb52c9f975a8192686f69ae5fbb82d771271f7c4eb3aa1415f9f7` |

Round-trip (host + on-device):
1. Public download → sha256 `4b064830…` (matches local).
2. `xzmini` (stdin→stdout) → ELF 39,125,176 B, sha256 `6cc347b7…` (matches).
3. On-device `nb_materialize` (real curl + device CA bundle): `READY`; tmpfs
   peak measured 31.6 → 69.8 MiB (< 96.7 MiB), free RAM 63.9 → 23.7 MiB.
4. Fail-closed paths verified on-device: bad URL → `PAYLOAD_DOWNLOAD_FAILED`;
   wrong pinned compressed hash → `PAYLOAD_INVALID`; corrupt XZ → `PAYLOAD_INVALID`;
   cooldown blocks auto-retry; `force` (manual start/restart/enroll) retries.

The historical MIBIB (`mibib/`) and `netbird-data`/UBI artifacts are **NOT
used by the current runtime** (see `NOT_USED_BY_CURRENT_RUNTIME.md` markers and
`docs/R2-RUNTIME.md`). The MIBIB section below documents that experiment only;
the runtime MIBIB must be restored to the original (`mibib-original.bin`,
sha256 `d12086f6…`) before any reboot — handled separately.

## netbird-data image

`netbird-data.ubi` parses as a valid UBI image (min I/O 2048, LEB 126976, PEB
131072) with a single **dynamic** volume `netbird_data`. Round-trip extraction
yields `metadata` + `netbird-0.77.1.xz` (payload sha256 matches original).

## Firmware round-trip

`Archer-AX53-NetBird.bin`: header + UBI at offset 4882; UBI volumes `kernel`
(17 PEBs) + `ubi_rootfs` (282 PEBs); total 39,457,554 B (== stock). Extracted
rootfs (via `extract_xz_patch.py`, XZ interception fired) contains all added
files and patched bundles. Executable bits correct in the packed rootfs
(755 for `netbird-ctl`/`xzmini`/`init.d/netbird`).

## Command-injection / secrets static audit

- All control paths build argv via the model's local `shellquote()` (POSIX
  single-quote; TP-Link's `luci.util` has no `shellquote`). Setup key goes only
  through a 0600 temp file → `--setup-key-file` → `unlink`; never
  argv/logs/rootfs/NAND.
- No new admin endpoint without auth (registered under LuCI `admin` tree).
- CIDR/URL/name/port whitelist validation in `model/netbird.lua`.
- No secrets in logs/settings; `/tp_data/netbird` 0700, private files 0600.

## Residual risks

1. **Frontend form is a new chunk** using plain controls styled with the same
   design tokens (not the proprietary `su-*` component library). Functionally
   complete; visual parity is partial.
2. **Enrollment + connection** were validated on the real AX53 in the prior
   phase; this phase's UI/backend wiring is validated offline only — the first
   device test must exercise enroll → connect → status via the web UI.
3. **NSS acceleration bypass** for NetBird traffic is not added (not required
   for the proven peer-only path); verify throughput if routing-peer mode is used.
4. The custom TP-Link Lua is bytecode-compiled; the two new modules ship as
   **source** `.lua` (Lua 5.1 loads source transparently). Loader behaviour was
   inferred, not exercised on-device (can be checked in `/tmp` on the device).
