# NetBird on Archer AX53 V1 — Validation Status

This document describes the **current validation contract** for the native
NetBird VPN Client integration. Historical validation of the abandoned
MIBIB/`netbird_data` and dedicated-CRUD implementations remains available in
Git history and in the project Notion timeline/ADR; it is not the current
acceptance baseline.

## Current implementation under validation

```text
TP-Link VPN Client UI
  -> /admin/vpn?form=server
  -> netbirdvpn = type 5
  -> network.vpn.proto = netbird
  -> /etc/init.d/vpnc
  -> netifd proto_netbird
  -> /lib/netbird/netbird-runtime.sh
  -> R2 materialization -> /tmp/netbird
  -> wt0
```

The architectural boundary is now explicit: **TP-Link owns every generic VPN
Client operation it already implements**. NetBird is only a fifth provider.

The following paths remain stock:

- list;
- ADD;
- EDIT;
- Save/Cancel;
- enable/disable toggle;
- DELETE;
- connected-status request.

The shared frontend model is allowed one provider-specific serialization rule:
a NetBird Management URL is normalized to a hostname for TP-Link's generic
`server` field while the original `management_url` remains available to the
NetBird registry/model. This does not replace the stock request/lifecycle.

`/admin/netbird` is auxiliary and provider-specific only. Its current HTTP
operations are:

- `status` — runtime/payload/traffic diagnostics for one saved stock profile;
- `enroll` — Setup Key enrollment for one saved stock profile;
- `restart` — explicit restart delegated to `/etc/init.d/vpnc`;
- `log` — runtime diagnostics;
- `payload_status` — payload diagnostics.

It must not expose a second generic settings CRUD, connected-status path or
profile-delete path.

The vendor `vpn.lua` remains byte-for-byte TP-Link bytecode. NetBird extends its
module-global registries through `netbirdvpn = type 5`; the loader is safe for
the LuCI index cache because `luci.model.netbird_vpn_native` is required inside
`index()` rather than captured as a serialized Lua upvalue.

## Existing installed client and multi-profile authority

The authoritative profile namespace is the stock `vpn.server` row key. Each
NetBird row gets independent provider state:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
  settings
  default.json
  state/
```

Multiple NetBird rows may coexist. No fixed key such as `netbird` is permitted.
Only the TP-Link-selected VPN Client profile is active at a time, matching the
stock VPN Client lifecycle.

Historical single-profile state directly under `/tp_data/netbird/` is migration
input. `netbird-profile-migrate` performs a **one-shot adoption** into a real
`vpn.server` row, so an already-installed legacy NetBird identity appears in the
normal TP-Link list. Its permanent completion marker prevents a later stock
DELETE from silently recreating the profile on reboot.

Provider-state orphan cleanup is independent from generic DELETE. If a stock
NetBird row no longer exists, its profile-scoped provider directory is eligible
for garbage collection; an active-profile fail-safe prevents cleanup during a
transient lifecycle inconsistency. The historical migration source is preserved
as evidence/input and is not treated as a live native profile after adoption.

## Setup Key flow

The Setup Key is intentionally **not** part of initial ADD. The reason is
architectural rather than cosmetic: profile identity is keyed by the stock row
key, and that key exists only after TP-Link's normal Save creates the row.

Expected flow:

1. Add NetBird through the normal TP-Link dialog.
2. Save using the stock Save path.
3. Re-open that saved row with Edit.
4. Enter the Setup Key in the NetBird provider subform.
5. Run Enrollment.
6. Enable the profile using the normal stock toggle after enrollment.

Supporting enrollment inside the first Save would require intercepting the stock
Save lifecycle, which is intentionally forbidden by the current architecture.
Setup Keys are staged only in `/tmp` with restrictive permissions for the
explicit enrollment call and are not persisted in profile settings.

## Storage/runtime facts already validated on hardware

These facts predate the current native-flow refactor and remain applicable:

- NetBird version: `0.77.1`.
- Decoded ELF size: `39,125,176` bytes.
- Decoded SHA-256:
  `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6`.
- Compressed XZ size: `9,455,188` bytes.
- Compressed SHA-256:
  `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941`.
- Payload is downloaded over HTTPS and materialized to `/tmp/netbird`.
- Compressed and decoded hashes are pinned in firmware.
- Streaming materialization succeeded on the real AX53.
- Failure paths for bad URL/hash/XZ were previously observed fail-closed for
  the payload materializer.
- Persistent configuration/identity remains under `/tp_data/netbird/`.
- Current architecture uses **stock MIBIB**; the historical `netbird_data`
  partition is not part of the runtime.

These facts do **not** by themselves validate the current native
`/admin/vpn -> vpnc -> netifd` integration.

## Routing peer invariants

NetBird v0.77.1 owns routed authorization through its route firewall chains.
LAN routing is valid only when:

```text
advertise_lan=1
disable_server_routes=0
disable_firewall=0
```

The frontend automatically enables the two prerequisites; the Lua model and
shell runtime independently reject contradictory settings.

`advertise_lan`/`advertise_cidr` do not create a control-plane Network/Resource.
The corresponding Network/Resource/Policy must exist in NetBird Management and
the AX53 must be selected as its routing peer.

### Route ACL preservation

A previous workaround inserted a local priority `FORWARD ACCEPT` ahead of
NetBird's routing chains. Review of the exact NetBird v0.77.1 behaviour showed
that this could bypass Route ACL enforcement, so that strategy is retired.

Current contract:

- no direct `iptables -I/--insert FORWARD` in the shared runtime;
- TP-Link scoped `wt0 <-> LAN` rules are appended, not inserted at position 1;
- routing mode requires the NetBird firewall enabled;
- post-flash validation must show the NetBird Route ACL chain before any scoped
  TP-Link acceptance for matching routed traffic.

Applied firewall values are snapshotted in `/tmp/netbird-firewall.state`; old
CIDR/port state must be removed before applying new values.

## netifd lifecycle

`vpnc/netifd` is the sole normal lifecycle owner. The protocol handler calls the
shared NetBird runtime directly. `/sbin/netbird-ctl` is only a CLI facade.

Both immediate startup failure and connection timeout must call
`nb_runtime_stop()` before `proto_setup_failed`, so a failed setup cannot leave
an orphan daemon/socket/wt0/firewall state.

The polling recovery supervisor is not a second lifecycle owner. It may only
observe state and re-trigger the stock `network.interface.vpn`/`vpnc` lifecycle.

## Offline gate

Run in a current local clone:

```sh
make test-netbird
```

The target checks shell syntax, profile isolation/adoption, runtime behaviour,
recovery behaviour, the authored frontend and structural stock-flow contracts.
It must pass before any firmware build.

Important coverage includes:

- exact stock list/ADD/EDIT/Save/toggle/DELETE/connected-status functions;
- no synthetic NetBird list row or singleton key;
- no `settings_set`, `nbControl`, `nbDelete` or alternate generic CRUD bridge in
  the final shared frontend bundles;
- protocol subform does not own stock key/type/description/enabled state;
- Setup Key never enters persistent profile settings;
- multiple independent stock-keyed NetBird identities;
- one-shot legacy adoption and no resurrection after stock DELETE;
- `daemonStatus=Connected` plus `management.connected=true` semantics;
- canonical `netbird up` flags without duplicates;
- routing/server-route/firewall invariants;
- no priority FORWARD ACL bypass;
- deterministic firewall A -> B cleanup;
- netifd rollback on immediate failure and timeout.

## Build gate

Build only from an explicitly identified decrypted stock image:

```sh
make firmware STOCK=stock_decrypted.bin
```

Before repack, the build verifies at least:

- original TP-Link VPN controller bytecode contract;
- `netbirdvpn=5` registry extension;
- LuCI native registry loader is present;
- stock list/ADD/EDIT/Save/toggle/DELETE/connected-status functions remain;
- provider form mapping and serializer are present;
- no hybrid/synthetic NetBird generic frontend helpers remain;
- `/admin/netbird` does not expose writable generic settings operations;
- `network.vpn.proto=netbird` handler chain;
- no standalone `S99netbird` lifecycle in the final image;
- netifd does not depend on `netbird-ctl`;
- immediate-failure and timeout rollback paths are present;
- routing/server-route/firewall validation exists;
- applied firewall state support exists;
- canonical firewall preserves NetBird Route ACL ordering.

Any failure is a stop point.

## Hardware gate

After a controlled flash, first validate LAN/WAN/Wi-Fi/DHCP/NAT and the fallback
VPN. Then validate the native profile path.

For an existing historical client, first confirm that a real stock row was
adopted:

```sh
uci show vpn | grep -E 'netbirdvpn|legacy_identity|profile_key'
```

For a new profile, verify the two-step Save -> Edit -> Enrollment flow. Do not
paste a real Setup Key into logs or documentation.

Runtime observations should include:

```sh
uci show vpn.client
uci show network.vpn
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
ip addr show wt0
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -S NETBIRD-RT-FWD-IN
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

Also validate at least two saved NetBird profiles can coexist in the TP-Link
list with distinct row keys and distinct directories under
`/tp_data/netbird/profiles/`; switching one must not overwrite the other's
identity.

When LAN routing is enabled:

- `disable_server_routes=0`;
- `disable_firewall=0`;
- applied firewall mode is `lan`;
- applied CIDR matches the active profile;
- `NETBIRD-RT-FWD-IN` exists;
- the first matching routed policy rule must not be a local priority ACCEPT
  bypass;
- scoped TP-Link forwarding/MASQUERADE rules match that CIDR;
- the matching Network/Resource/Policy exists in NetBird Management.

Also test mutations:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

No rule from A/X may remain after the transition.

## External-direction acceptance

A router-local test cannot prove the path users actually need. From a real
remote NetBird peer, separately test:

1. remote peer -> AX53 overlay address;
2. remote peer -> LAN host through AX53;
3. remote peer -> Proxmox/VMs/local Coolify where applicable;
4. DNS using the target architecture without the historical `10.8.0.1`
   dependency.

Only those tests can validate the routing-peer path end to end.

## Current validation status

As of 2026-09-09:

```text
maximum-stock-flow refactor: implemented on fix/netbird-ui-state-routing
legacy identity -> real stock row adoption: implemented in code
multi-profile stock-keyed persistence: implemented in code
LuCI index-cache upvalue crash correction: implemented in code
static remote source audit: performed
make test-netbird: pending local execution
firmware build/repack: pending
hardware flash: pending
stock-list + Save/Edit/Enrollment hardware acceptance: pending
remote peer -> AX53/LAN acceptance: pending
WG-Easy decommission: NOT authorized
```

The ChatGPT execution environment cannot currently resolve `github.com`, so it
cannot honestly claim the local `make test-netbird` or firmware build has run.
Those remain explicit validation stop points before merge/deployment.
