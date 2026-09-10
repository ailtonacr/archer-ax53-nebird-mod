# NetBird on Archer AX53 V1 — Validation Status

This document defines the acceptance contract for the **current clean native
implementation**. Earlier experiments remain in Git history and the project
Notion ADR/Timeline, but they are not compatibility requirements for this
firmware.

## Implementation under validation

```text
TP-Link VPN Client UI
  -> /admin/vpn?form=server
  -> netbirdvpn = type 5
  -> vpn.server = authoritative profile row
  -> network.vpn.proto = netbird
  -> network.vpn.profile_key = stock row key
  -> /etc/init.d/vpnc
  -> netifd proto_netbird
  -> /lib/netbird/netbird-runtime.sh
  -> R2 materialization -> /tmp/netbird
  -> wt0
```

TP-Link owns generic:

```text
list
ADD
EDIT
Save / Cancel
enable / disable
DELETE
connected_status
```

NetBird adds only the provider-specific subform/serializer, registry entry,
profile-scoped identity/runtime, enrollment and diagnostics.

## Stock-flow contract

The vendor `vpn.lua` remains TP-Link bytecode. The integration registers:

```text
VPN_TYPE_TBL[netbirdvpn]      = 5
VPN_TYPE_NAME_TBL[netbirdvpn] = NetBird
VPN_TBL[netbirdvpn]           = stock-shaped schema
VPN_CFG_TBL[netbirdvpn]       = NetBird config normalizer
```

The final frontend must retain the original stock functions for:

- list;
- ADD/EDIT Save;
- toggle/update;
- DELETE;
- connected status.

Forbidden regressions include:

- synthetic NetBird rows merged into the list;
- fixed `key=netbird`;
- custom generic Save bridge;
- custom generic DELETE bridge;
- `/admin/netbird` writable settings CRUD;
- `/admin/netbird` connected-status replacement.

## Profile isolation contract

Each saved stock NetBird row has exactly one provider namespace:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
  settings
  default.json
  state/
```

There is no root-level profile context. No current operation may use
`/tp_data/netbird/settings`, `/tp_data/netbird/default.json` or
`/tp_data/netbird/state/` as an implicit profile.

Multiple NetBird rows may coexist. Tests must prove:

- A and B receive distinct directories;
- deleting B cannot remove A;
- a stock row belonging to another provider cannot authorize a NetBird identity;
- an active profile is retained fail-safe during a transient config/lifecycle race;
- provider state is garbage-collected only when its matching stock row is gone;
- Setup Keys never enter persistent state.

The clean implementation does not import or reconstruct prior NetBird profile
state.

## Setup Key flow

Expected flow:

1. Add NetBird through the normal TP-Link dialog.
2. Save through the stock Save path.
3. Confirm the stock row appears.
4. Re-open Edit.
5. Enter Setup Key.
6. Run Enrollment.
7. Enable using the stock toggle.

Enrollment before the first stock Save is intentionally unsupported because no
stock profile key exists yet.

## Auxiliary endpoint contract

`/admin/netbird` may expose only:

```text
status
enroll
restart
log
payload_status
```

All profile-specific calls require a valid saved stock key. Status must never
fall back to another NetBird row. Logs are meaningful only for the active
NetBird profile. Restart delegates to `/etc/init.d/vpnc`.

## R2/runtime facts already validated on hardware

These facts remain applicable:

- NetBird `0.77.1` runs on the AX53.
- Decoded ELF size: `39,125,176` bytes.
- Decoded SHA-256:
  `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6`.
- Compressed XZ size: `9,455,188` bytes.
- Compressed SHA-256:
  `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941`.
- HTTPS streaming materialization to `/tmp/netbird` has worked on real hardware.
- MIBIB remains stock.

These facts do not by themselves validate the new stock-profile flow.

## netifd lifecycle contract

Normal lifecycle has one owner:

```text
vpnc -> netifd -> proto_netbird -> shared runtime
```

There is no standalone NetBird init lifecycle in the current implementation.
`netbird-ctl` is a CLI facade and netifd does not depend on it.

The interface may be published UP only when:

```text
wt0 exists
daemonStatus == Connected
management.connected == true
```

Immediate startup failure and connection timeout must both rollback the runtime
before `proto_setup_failed`.

The recovery supervisor may re-trigger TP-Link `network.interface.vpn`/`vpnc`,
but may not call `nb_runtime_connect` directly.

## Routing-peer invariants

LAN routing is valid only when:

```text
advertise_lan=1
disable_server_routes=0
disable_firewall=0
```

The corresponding Network/Resource/Policy is owned by NetBird Management. The
router does not create it.

The current firewall contract requires:

- no direct priority `iptables -I/--insert FORWARD` bypass in the runtime;
- TP-Link scoped forwarding rules appended after NetBird policy chains;
- exact applied values stored in `/tmp/netbird-firewall.state`;
- configuration A removed before configuration B is applied;
- cleanup failure preserves the old snapshot and aborts the transition.

## Browser/frontend contract

The provider subform must expose:

```text
isChanged
validate()
setForm()
getForm()
resetForm()
clearValidate()
```

It must use TP-Link `su-*` components and return only protocol-specific fields.
The custom module import must include content-derived cache busting. This is
required because a real hardware test showed a stale browser copy producing
`setForm is not a function` while an incognito session loaded the corrected
form.

## Offline gate

Run:

```sh
make test-netbird
```

The gate covers:

- shell syntax;
- runtime status/flags/firewall transitions;
- profile isolation and orphan GC;
- polling recovery;
- authored provider form behavior;
- structural stock-flow contracts;
- final frontend patch contracts;
- Python syntax.

Any failure is a stop point.

## Build gate

Run only after the offline gate passes:

```sh
make firmware STOCK=stock_decrypted.bin
```

Before repack the build verifies:

- TP-Link VPN controller bytecode contract;
- `netbirdvpn=5` registry extension;
- profile-scoped NetBird model/runtime;
- stock list/ADD/EDIT/Save/toggle/DELETE/connected-status frontend functions;
- provider form mapping and serializer;
- no synthetic row/fixed key/generic CRUD bridge;
- `network.vpn.proto=netbird` + `profile_key` path;
- no separate NetBird lifecycle owner;
- runtime rollback and routing policy invariants;
- profile GC service;
- cache-busted provider module;
- build identity stamp.

## Hardware acceptance gate

The router should be tested from a clean NetBird profile state. Do not rely on
any prior NetBird identity/configuration.

First confirm basic router services after flash. Then create NetBird entirely
through the stock UI.

### First profile

Validate:

```text
Add -> NetBird -> stock Save -> row visible -> Edit -> Enrollment -> stock toggle
```

Observe metadata/runtime without printing credentials:

```sh
uci show vpn.client
uci show network.vpn
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
ip addr show wt0
```

### Multiple profiles

Create profile B and verify:

- A and B both appear in the stock list;
- keys differ;
- provider directories differ;
- enrollment/edit of one does not mutate the other;
- only the stock-selected profile is active.

### DELETE/GC

Delete B through the stock UI. A must remain untouched. Then run:

```sh
/etc/init.d/netbird-profile-gc start
```

B's provider directory should disappear while A remains.

### Routing peer

When enabled validate:

```sh
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -S NETBIRD-RT-FWD-IN
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

Also test:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

No stale A/X rule may remain.

### Remote direction

From a real remote peer test:

1. remote peer -> AX53 overlay;
2. remote peer -> LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS without dependency on `10.8.0.1`.

## Current validation status — 2026-09-09

```text
clean native provider architecture: implemented on fix/netbird-ui-state-routing
multi-profile stock-keyed persistence: implemented in code
no root-level profile fallback: implemented in code
stock generic CRUD/list/toggle/delete/status boundary: enforced in code/build gates
LuCI index-cache upvalue fix: implemented in code
browser cache busting: implemented in code
R2 runtime: previously validated on hardware
make test-netbird after clean-break refactor: PENDING LOCAL EXECUTION
firmware build/repack after clean-break refactor: PENDING
hardware stock Save/Edit/Enrollment acceptance: PENDING
multi-profile hardware acceptance: PENDING
remote peer -> AX53/LAN acceptance: PENDING
WG-Easy decommission: NOT AUTHORIZED
```

Do not claim this refactor validated until the local gate, build and hardware
acceptance all pass.
