# NOTE: current runtime is the R2 runtime (payload downloaded over HTTPS, no netbird_data/MIBIB/UBI). This file documents the historical MIBIB/netbird_data architecture unless stated otherwise. See docs/R2-RUNTIME.md for the current architecture and INSTALL.md for the current install flow.
# NetBird on TP-Link Archer AX53 V1 — Architecture

## Overview

NetBird 0.77.1 is integrated as a **VPN Client type** in the stock TP-Link web UI,
alongside OpenVPN / PPTP / L2TP / WireGuard. The NetBird binary is **not** stored in
the root filesystem; it lives in a dedicated 16 MiB NAND partition (`netbird_data`)
and is stream-decompressed into `/tmp` (tmpfs) at runtime. Configuration/identity
persist in `/tp_data/netbird`.

```
Web UI (Vue SPA) ── stok ──> LuCI dispatcher ──> admin/netbird.lua (source Lua)
                                                     │ fork_exec (argv, shell-quoted)
                                                     ▼
                                              /sbin/netbird-ctl
                                                     │  . /lib/netbird/netbird.sh
                                                     ▼
                                       netbird_data (UBI) ──xzmini──> /tmp/netbird
                                                                        │
                                                            netbird daemon (wt0)
                                                                        │
                                                        kernel wireguard + fw rules
```

## Storage layout

| Path | FS | Contents | Perms |
|---|---|---|---|
| `netbird_data` (MTD, 16 MiB) | UBI/UBIFS | `netbird-0.77.1.xz` (9.45 MB), `metadata` | 0644 |
| `/tp_data/netbird/` | UBIFS | NetBird identity + settings | 0700 |
| `/tp_data/netbird/default.json` | UBIFS | NetBird profile (mgmt URL, wg key, ssh key) | 0600 |
| `/tp_data/netbird/state/` | UBIFS | NetBird runtime state (`NB_STATE_DIR`) | 0700 |
| `/tp_data/netbird/settings` | UBIFS | our key=value settings (no secrets) | 0600 |
| `/tmp/netbird` | tmpfs | materialized binary (39,125,176 B) | 0755 |
| `/tmp/netbird.new` | tmpfs | staging during decode | 0600 |
| `/tmp/netbird.sock` | tmpfs | daemon control socket | — |
| `/tmp/netbird.log` | tmpfs | runtime log (rotated by NB_LOG_MAX_SIZE_MB) | 0644 |

The rootfs only carries: `sbin/xzmini` (78,996 B), `sbin/netbird-ctl`,
`lib/netbird/netbird.sh`, `etc/init.d/netbird`, two source Lua files, the
firewall functions and the frontend bundle patches. **No 9.45 MB payload is in
the rootfs.**

## Payload versioning

`/netbird_data/metadata` (key=value):

```
schema=1
version=0.77.1
payload=netbird-0.77.1.xz
size=39125176
sha256=6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6
```

`nb_materialize()` honours the metadata so a future NetBird version can be
provisioned (new `netbird-X.Y.Z.xz` + updated `metadata`) **without** changing
any code.

## Boot / materialization

1. `/etc/init.d/netbird` runs at `START=99` (after `network` S25, `firewall` S45,
   `openvpn`/`vpnc` S90).
2. `nb_materialize()`:
   - if `/tmp/netbird` already hash-valid → skip;
   - attach/mount `netbird_data` **only if** `/proc/mtd` already lists it
     (i.e. the MIBIB was updated) — via a **fail-closed, non-destructive**
     `ubiattach` + `mount -t ubifs` (no `flash_erase`/`ubiformat`/`ubimkvol`
     ever at runtime; provisioning/format is done only by the provisioner);
   - distinct states: `READY`, `PARTITION_MISSING`, `PAYLOAD_STORAGE_INVALID`,
     `PAYLOAD_MISSING`, `PAYLOAD_INVALID`;
   - stream `xzmini < netbird-0.77.1.xz > /tmp/netbird.new` (CRC64 checked by liblzma);
   - validate size `39125176` and sha256;
   - `chmod 0755` + atomic `mv` to `/tmp/netbird`.
3. Any failure logs to `/tmp/netbird.log` and returns without blocking boot
   (Wi-Fi / WAN / DHCP / NAT / existing VPN are untouched).

## Service lifecycle

- **daemon**: `netbird service run` in foreground, PID-tracked via
  `start-stop-daemon` (rc.common `service_start`), env `NB_STATE_DIR`,
  `NB_LOG_MAX_SIZE_MB=2`. Auto-connects on start when an enrolled config exists.
- **connect**: `netbird up` (with `--setup-key-file` for enrollment).
- **disconnect**: `netbird down`.
- **status**: `netbird status -j` (JSON parsed by the backend).
- The daemon is a single **global** profile (NetBird = one identity/interface
  `wt0`), so the UI allows exactly one NetBird client.

## Config model (`/tp_data/netbird/settings`)

`enable`, `enrolled`, `management_url` (default `https://netbird.ailton.dev.br`),
`hostname`, `disable_dns`, `disable_firewall`, `disable_client_routes`,
`disable_server_routes`, `disable_ipv6`, `network_monitor`, `advertise_lan`,
`advertise_cidr`, `wireguard_port`.

Safe defaults: all `disable_*` = 1, `network_monitor` = 0, `advertise_lan` = 0 —
i.e. NetBird starts as a **peer only**. Routing/firewall are opt-in via the UI.

## Backend (source Lua, loaded by LuCI 5.1)

- `usr/lib/lua/luci/model/netbird.lua` — settings persistence/validation,
  shell-quoted control, status parse.
- `usr/lib/lua/luci/controller/admin/netbird.lua` — registered under the `admin`
  tree (inherits `stok` session auth). Operations: `status`, `settings_get`,
  `settings_set`, `enroll`, `start`, `stop`, `restart`, `clean`, `log`,
  `payload_status`.

The existing bytecode controllers are **not** modified; NetBird is a clean,
self-contained source module.

## Frontend (compiled Vue, patched in place)

- `update-store-DQkZxaRI.js` — `Netbird="netbird"` added to the Type enum;
  English `typeNetbird` label.
- `util-JEiJiY0O.js` — `netbird` added to the `getType` map (inserted before
  WireGuard so the Add-Profile default stays WireGuard).
- `model-CI6Gt3Hz.js` — `nbStatus/nbSettingsSet/nbEnroll/nbControl/nbLog` RPC.
- `index-DTNtPvwx.js` — `VpnServerNetbirdForm` component + `case it.Netbird`
  in the sub-form switch; `Dt()` whitelist relaxed for `netbird`; the client
  list is injected with the single NetBird entry; generic insert/update is
  skipped for `netbird` (it persists via its own backend).
- `VpnServerNetbirdForm-NB.js` — new self-contained chunk (management URL,
  setup key enrollment, enable/advanced/routing toggles, status, start/stop/
  restart/re-enroll/delete, logs).
- `locale/*/index-*.js.gz` (27) — `typeNetbird` added.

## Firewall

`fw_netbird_access` / `fw_netbird_block` (appended to `lib/firewall/tpcmd.sh`,
dispatched from `sbin/fw`). Minimal and explicit — **no broad `-i wt0 -j ACCEPT`**:

- `INPUT ACCEPT 1` for UDP `wireguard_port` (handshake/ICE);
- `INPUT`/`FORWARD ACCEPT` on `wt0` limited to `ctstate ESTABLISHED,RELATED`;
- FORWARD `wt0 <-> br-lan` + `POSTROUTING MASQUERADE` **only** when
  `advertise_lan` (routing peer) is enabled.

NetBird's own firewall manager is controlled separately by `disable_firewall`
(default on), so NetBird policies stay meaningful and no wide bypass is created.

## Factory reset / upgrade / A/B

- **Factory reset** (`sbin/reset`): removes `/tp_data/netbird` (identity+settings)
  → NetBird reappears as "Enrollment required". The `netbird_data` payload is
  kept.
- **Firmware upgrade**: the stock updater writes only `rootfs`/`rootfs_1`;
  `netbird_data`, `/tp_data` and the payload survive.
- **A/B**: `rootfs`/`rootfs_1`/`tp_boot_idx` geometry is unchanged by the MIBIB
  edit (only a 17th partition is appended after `data`).

## Multi-profile decision

NetBird uses one identity/config per daemon/`wt0` interface. The architecture is
**single global NetBird client**; the UI allows only one and surfaces
"Enrollment required" until enrolled.
