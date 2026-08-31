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

Normal profile CRUD/list/toggle/connected-status remains on the stock TP-Link
VPN endpoint. `/admin/netbird` is auxiliary only: enrollment, diagnostics,
read-only settings inspection, logs/payload, restart/recovery and idempotent
identity cleanup.

The vendor `vpn.lua` remains byte-for-byte TP-Link bytecode. NetBird extends the
module-global registries verified by `scripts/verify-tplink-vpn-bytecode.py`.

## Storage/runtime facts already validated on hardware

These facts predate the current native-CRUD refactor and remain applicable:

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
- Identity/settings persist under `/tp_data/netbird/`.
- Current architecture uses **stock MIBIB**; the historical `netbird_data`
  partition is not part of the runtime.

These facts do **not** by themselves validate the current native
`/admin/vpn -> vpnc -> netifd` integration.

## Code corrections after the 2026-08-31 re-audit

The branch `fix/netbird-ui-state-routing` was corrected after an end-to-end
file-by-file audit found several false assumptions in the previous gate.

### Profile authority

- `/admin/vpn?form=server` is the normal profile settings authority.
- `/admin/netbird` no longer dispatches `settings_set`.
- The final frontend model must not contain `operation:"settings_set"`,
  `nbSettingsSet` or the old dedicated connected-status/list/save bridge.

### Delete / identity cleanup

- `nb_clean()` removes identity/state without recreating `state/`.
- Auxiliary `profile_delete` is idempotent:
  - native NetBird profile still exists -> skip;
  - no profile and no artifacts -> no-op;
  - no profile but orphan identity exists -> cleanup.
- Stock deletion remains authoritative; auxiliary cleanup only handles NetBird
  external identity/runtime artifacts.

### Routing peer invariant

NetBird v0.77.1 documents `--disable-server-routes=true` as disabling route
server behaviour. Therefore the local routing state is invalid when:

```text
advertise_lan=1
and
disable_server_routes=1
```

The frontend, Lua model and shell runtime all reject/prevent that state.

`advertise_lan`/`advertise_cidr` do not create a control-plane Network/Resource.
The corresponding Network/Resource/Policy must exist in NetBird Management and
the AX53 must be selected as its routing peer.

### Deterministic firewall mutation

Applied firewall values are snapshotted in RAM:

```text
/tmp/netbird-firewall.state
```

Fields:

```text
port=
access=
cidr=
homeif=
```

Before applying configuration B, the runtime removes the values recorded for A.
This avoids trying to remove A by reading an already-updated settings file that
contains B.

`src/init/netbird_firewall.inc` is the canonical firewall implementation
packaged by `mods/010-netbird.sh`.

### netifd rollback

Both immediate failure from `nb_runtime_connect()` and connection timeout call
`nb_runtime_stop()` before `proto_setup_failed`. A failed netifd setup must not
leave daemon/socket/wt0/firewall state orphaned.

### Frontend source/final artifact parity

The authored `VpnServerNetbirdForm-NB.js` now directly implements the final
contract:

- Add starts with `creating=true`.
- `type=netbirdvpn` does not imply Edit.
- Only persisted `key`/`id` establishes Edit.
- The protocol subform does not own the stock profile key/type.
- Enabling LAN routing enables server routes and validation prevents the
  contradictory state.

The finalizer still removes intermediate hybrid helpers from the TP-Link shared
bundles, but it should not need to rewrite the subform's CREATE/EDIT semantics.

## Offline gate

Run in a current local clone:

```sh
make test-netbird
```

The target checks shell syntax, runtime behaviour, the authored frontend,
structural contracts and a hermetic finalizer contract. It must pass before any
firmware build.

Important behavioural coverage includes:

- `daemonStatus=Connected` **and** `management.connected=true` status semantics;
- canonical `netbird up` flags without duplicates;
- LAN routing requiring server routes;
- firewall CIDR/port A -> B cleanup using applied state;
- `nb_clean` not recreating identity state;
- source CREATE/EDIT by persisted key/id.

## Build gate

Build only from an explicitly identified decrypted stock image:

```sh
make firmware STOCK=stock_decrypted.bin
```

Before repack, the build verifies at least:

- original TP-Link VPN bytecode contract;
- `netbirdvpn=5` registry extension;
- `network.vpn.proto=netbird` handler chain;
- no `S99netbird` in the final image;
- netifd does not depend on `netbird-ctl`;
- immediate-failure and timeout rollback paths are present;
- routing/server-route validation exists;
- applied firewall state support exists;
- final frontend uses stock list/CRUD/status and key/id Add/Edit;
- final model has no writable `settings_set` helper.

Any failure is a stop point.

## Hardware gate

After a controlled flash, first validate LAN/WAN/Wi-Fi/DHCP/NAT and the fallback
VPN. Then run `scripts/validate-netbird-native-router.sh` from `/tmp` or another
temporary location.

Required observations include:

```sh
uci show vpn.client
uci show network.vpn
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
ip addr show wt0
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

When LAN routing is enabled:

- `disable_server_routes=0`;
- applied firewall mode is `lan`;
- applied CIDR matches the active profile;
- scoped forwarding/MASQUERADE rules match that CIDR;
- the matching Network/Resource exists in NetBird Management.

Also test mutations on hardware:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

No rule from A/X may remain after the transition.

## External-direction acceptance

A router-local test cannot prove routing in the direction users actually need.
From a real remote NetBird peer, separately test:

1. remote peer -> AX53 overlay address;
2. remote peer -> LAN host through AX53;
3. remote peer -> Proxmox/VMs/local Coolify where applicable;
4. DNS using the target architecture without the historical `10.8.0.1`
   dependency.

Only those tests can validate the routing-peer path end to end.

## Open hypothesis: INPUT traffic to the AX53 itself

The current explicit NetBird firewall rule accepts `ESTABLISHED,RELATED` input
on `wt0`; no broad rule for new inbound traffic was added. The observed stock
firewall has global INPUT ACCEPT, but the exact chain/zone behaviour for `wt0`
must be confirmed on hardware.

If remote peer -> AX53 fails, inspect INPUT-chain counters/ordering first. Do
**not** add a broad `-i wt0 -j ACCEPT` workaround without evidence.

## Current validation status

As of 2026-08-31, the code corrections and gates are committed on
`fix/netbird-ui-state-routing`, but the current suite/build/hardware sequence has
**not** been executed by the ChatGPT session environment because that executor
could not resolve/clone `github.com`.

Therefore:

```text
code correction: implemented
static remote review: performed
make test-netbird: pending local execution
firmware build/repack: pending
hardware flash: pending
remote peer -> AX53/LAN acceptance: pending
WG-Easy decommission: NOT authorized
```
