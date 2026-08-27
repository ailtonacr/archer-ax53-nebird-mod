# NetBird on Archer AX53 V1 — Final Report (R2 runtime)

Phase complete: NetBird 0.77.1 integrated as a VPN Client type with an **R2
runtime** (payload downloaded over HTTPS, no `netbird_data`/MIBIB/UBI). The
firmware is built and validated offline and on the real device. **Nothing new
was flashed and the router was NOT rebooted** (the runtime MIBIB restoration is
handled separately).

## Artifacts (`work/netbird-final/`)

| Artifact | sha256 |
|---|---|
| `firmware/Archer-AX53-NetBird-r2.bin` (39,457,554 B) | `7b42f4c390a504382585f0c332f816c9a4d6b19f583cdab5c2ae50bc01f0d6a8` |
| R2 payload `netbird-dict8.xz` (9,455,188 B) | `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941` |
| decoded `netbird` v0.77.1 (39,125,176 B) | `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6` |
| `xzmini` ARMv7 static-pie (78,996 B) | `b0d7464d643bb52c9f975a8192686f69ae5fbb82d771271f7c4eb3aa1415f9f7` |

### Historical (NOT used by the current runtime)
| Artifact | sha256 |
|---|---|
| `mibib/mibib-netbird.bin` (524,288 B) — validated MIBIB experiment | `d5e7a4f78a2164e3cc651271828c14dcc5c85af324c8d83412b0ebfe097d63f5` |
| `mibib/mibib-original.bin` (524,288 B) — runtime MIBIB to restore | `d12086f62272e99fb429f33e2c050ed50ef687b8f42e5d5b8f053f284e3dd31a` |
| `netbird-data/netbird-data.ubi` (11,927,552 B) | `b87c1183e0afa300c3c94322e0857a939a5e0d294a299f4e3c178af4359ac4a3` |

## Report items

1. **Architecture (current)** — NetBird = VPN Client type; binary downloaded
   over HTTPS from public Cloudflare R2 (`netbird-dl` Worker → `ax53-netbird`
   bucket), hash-validated, streamed through `xzmini` into `/tmp/netbird`;
   identity/settings persist in `/tp_data/netbird`; LuCI source controller
   under the `admin` tree; rc.common service. See `docs/R2-RUNTIME.md`.
2. **VPN Client integration found** — LuCI `admin/vpn.lua` (bytecode) + `model/vpn.lua`,
   frontend chunks `index-DTNtPvwx.js` (page), `model-CI6Gt3Hz.js` (RPC model),
   `util-JEiJiY0O.js` (getType map), `update-store-DQkZxaRI.js` (Type enum).
3. **Web files changed** — 4 patched bundles + `VpnServerNetbirdForm-NB.js`
   chunk + 27 locale bundles. Form now shows payload state
   (PAYLOAD_NOT_DOWNLOADED / PAYLOAD_DOWNLOAD_FAILED / PAYLOAD_INVALID / READY)
   with no MIBIB/UBI wording.
4. **Backend/API changed** — source `controller/admin/netbird.lua` +
   `model/netbird.lua` (ops: status/settings_get/settings_set/enroll/start/stop/
   restart/clean/log/payload_status); backend Lua uses a local `shellquote()`
   (TP-Link `luci.util` has none — fixed).
5. **Config model** — `/tp_data/netbird/settings` (key=value, 0600);
   management URL etc. from settings; payload URL/hashes are pinned constants in
   `lib/netbird/netbird.sh` (not user-editable in the UI).
6. **Init/service** — `etc/init.d/netbird` (START=99) + `S99netbird`; boot is
   non-blocking and fail-closed (download failure never affects boot/WAN/WiFi).
7. **Lifecycle** — up/down/stop/restart/clean/status/payload-status; manual
   start/restart/enroll force a download retry; automatic polling is throttled
   by a 300 s cooldown (no aggressive loop).
8. **Enrollment** — setup key → 0600 temp file → `up --setup-key-file` → unlink.
9. **Secrets** — `/tp_data/netbird` 0700, private files 0600, logs sanitized.
10. **Firewall** — `fw_netbird_access/block`: UDP handshake port + wt0 conntrack
    ESTABLISHED,RELATED + FORWARD only when `advertise_lan`.
11. **Routing** — optional routing peer via `advertise_lan`+`advertise_cidr`;
    NetBird dashboard owns Network/Resource/Policy.
12. **Persistence** — identity in `/tp_data/netbird`; payload is ephemeral in
    `/tmp` (re-materialized on demand).
13. **Payload states** — `READY` / `PAYLOAD_NOT_DOWNLOADED` /
    `PAYLOAD_DOWNLOAD_FAILED` / `PAYLOAD_INVALID` (no partition/UBI concepts).
14. **RAM (measured on device)** — streaming materialization peaks at the single
    39,125,176-byte ELF: `/tmp` 31.6 → 69.8 MiB used (< 96.7 MiB tmpfs), free
    RAM 63.9 → 23.7 MiB. The two-phase (stored XZ + ELF) variant hit
    `No space left on device` and was abandoned.
15. **Upgrade** — stock updater leaves `/tp_data` intact; no partitions added.
16. **Factory reset** — `sbin/reset` removes `/tp_data/netbird`; payload is
    re-downloaded on demand.
17. **A/B** — `rootfs`/`rootfs_1`/`tp_boot_idx` untouched; stock MIBIB untouched.
18. **Security** — HTTPS + device CA bundle TLS verification (`--cacert`);
    compressed SHA-256 and decoded ELF SHA-256 pinned in firmware; never execute
    a payload failing any check; atomic rename; no shell interpolation.
19. **Final image** — `firmware/Archer-AX53-NetBird-r2.bin`, stock geometry
    (kernel 17 PEBs + ubi_rootfs 282 PEBs), 39,457,554 B (== stock), diff vs the
    previously flashed firmware is exactly 3 files (netbird.sh, netbird-ctl,
    VpnServerNetbirdForm-NB.js.gz).
20. **Hashes** — table above.
21. **Install** — `docs/INSTALL.md` (Web UI flash → UI enroll; no provisioning).
22. **Rollback** — `docs/ROLLBACK.md`.
23. **Residual risks** — `docs/VALIDATION.md`.

## What I did NOT do (per your stop point)

- Did NOT flash the new firmware, did NOT reboot the AX53.
- Did NOT write any MTD / MIBIB / `netbird_data`; no `ubiformat`/`ubiattach`.
- Did NOT remove `wg_c` / WG-Easy / OpenVPN / any stock feature.
- Did NOT include the payload XZ in the rootfs.