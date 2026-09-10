# NetBird on Archer AX53 V1 — Validation Status

This document defines the acceptance contract for the **current clean native
implementation**. Earlier experiments remain in Git history and the project
Notion ADR/Timeline, but they are not compatibility requirements.

## Implementation under validation

```text
TP-Link VPN Client UI
  -> /admin/vpn?form=server
  -> netbirdvpn = type 5
  -> stock key generator
  -> VPN_CFG_TBL[netbirdvpn]
  -> transient Setup Key enrollment
  -> vpn.server = authoritative profile row
  -> network.vpn.proto = netbird
  -> network.vpn.profile_key = stock row key
  -> /etc/init.d/vpnc
  -> netifd proto_netbird
  -> /lib/netbird/netbird-runtime.sh
  -> R2 materialization -> /tmp/netbird
  -> wt0
```

TP-Link owns generic list, ADD, EDIT, Save/Cancel, enable/disable, DELETE and
`connected_status`. NetBird adds only provider discovery/form/serialization,
the stock provider callback, profile-scoped identity/runtime, diagnostics and
orphan provider-state GC.

## Stock-flow contract

The vendor `vpn.lua` remains TP-Link bytecode. The integration registers:

```text
VPN_TYPE_TBL[netbirdvpn]      = 5
VPN_TYPE_NAME_TBL[netbirdvpn] = NetBird
VPN_TBL[netbirdvpn]           = stock-shaped validator schema
VPN_CFG_TBL[netbirdvpn]       = NetBird provider callback
```

The validator rule shape must be:

```lua
{ field = { key }, canbe_empty = true }
```

The older `{ key = key }` implementation is forbidden because the stock
controller expects `rule.field`; the hardware ADD path returned HTTP 500 while
that invalid schema was installed.

The final frontend must retain the original stock functions for list,
ADD/EDIT Save, toggle/update, DELETE and connected status. Forbidden regressions
include synthetic rows, fixed `key=netbird`, custom Save/DELETE bridges,
`/admin/netbird` writable settings CRUD and auxiliary connected-status.

## Setup Key contract

The initial profile is created and enrolled in a **single stock Save**:

```text
Add -> NetBird -> provider fields + Setup Key -> stock SALVAR
    -> stock key generated
    -> /admin/vpn?form=server
    -> VPN_CFG_TBL[netbirdvpn]
    -> profile-scoped enrollment
    -> row visible in stock list
    -> stock toggle activates it
```

Required properties:

- the Setup Key control is visible in CREATE;
- CREATE validation requires Setup Key;
- provider `getForm()` supplies `setup_key` only as transient Save input;
- the serializer explicitly carries `setup_key` in the stock Save request;
- `setup_key` is not a `VPN_TBL` persistent field;
- the returned persistent `vpn` object contains no Setup Key;
- the provider callback stages the key under `/tmp/nb-setup-key-*` mode 0600;
- the temporary key file is unlinked after the enrollment call;
- the enrollment daemon is stopped after enrollment so the stock toggle remains
the sole normal activation owner;
- `/admin/netbird` does not accept Setup Key or expose an enrollment operation.

An already enrolled profile may be saved with blank Setup Key. No secret may be
printed into logs, tests, repository docs or Notion.

## Profile isolation contract

Each saved stock NetBird row has exactly one provider namespace:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
  settings
  default.json
  state/
```

There is no root-level profile context. Multiple NetBird rows may coexist. Tests
must prove A/B isolation, safe deletion/GC, refusal to treat another provider's
stock row as NetBird authority, and no Setup Key persistence.

The clean implementation does not import or reconstruct prior NetBird state.

## Auxiliary endpoint contract

`/admin/netbird` may expose only:

```text
status
restart
log
payload_status
```

All profile-specific calls require a valid saved stock key. Status never falls
back to another row. Logs are available only for the active NetBird profile.
Restart delegates to `/etc/init.d/vpnc`.

Forbidden auxiliary operations include:

```text
enroll
settings_set
settings_get
connected_status
profile_delete
clean
```

## R2/runtime facts already validated on hardware

These facts remain applicable:

- NetBird `0.77.1` runs on the AX53.
- Decoded ELF size: `39,125,176` bytes.
- Decoded SHA-256: `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6`.
- Compressed XZ size: `9,455,188` bytes.
- Compressed SHA-256: `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941`.
- HTTPS streaming materialization to `/tmp/netbird` has worked on hardware.
- MIBIB remains stock.

These facts do not by themselves validate the newest one-step stock-profile
flow.

## netifd lifecycle contract

Normal lifecycle has one owner:

```text
vpnc -> netifd -> proto_netbird -> shared runtime
```

There is no standalone NetBird init lifecycle. `netbird-ctl` is a CLI facade and
netifd does not depend on it. The interface may be published UP only when `wt0`
exists, daemon status is Connected and management is connected.

Immediate startup failure and connection timeout both rollback the runtime
before `proto_setup_failed`. Recovery may re-trigger TP-Link
`network.interface.vpn`/`vpnc`, but may not call `nb_runtime_connect` directly.

## Routing-peer invariants

LAN routing is valid only when:

```text
advertise_lan=1
disable_server_routes=0
disable_firewall=0
```

The corresponding Network/Resource/Policy is owned by NetBird Management. The
router does not create it.

Firewall requirements:

- no direct priority `iptables -I/--insert FORWARD` bypass;
- TP-Link scoped forwarding rules appended after NetBird policy chains;
- exact applied values stored in `/tmp/netbird-firewall.state`;
- configuration A removed before B is applied;
- cleanup failure preserves old snapshot and aborts transition.

## Browser/frontend contract

The provider subform exposes:

```text
isChanged
validate()
setForm()
getForm()
resetForm()
clearValidate()
```

It uses TP-Link `su-*` components. It must **not** nest another `su-form` inside
the outer VPN dialog; provider `su-form-item` controls inherit the stock form
context through `su-spin`. This is the fix for the horizontally overflowing
modal observed on hardware.

The custom module import includes content-derived cache busting. Hardware has
already shown stale browser copies can cause incompatible component behavior.

## Offline gate

Run:

```sh
make test-netbird
```

The gate covers shell syntax, runtime/firewall transitions, profile isolation,
recovery, the authored provider form, one-step Setup Key behavior, structural
stock-flow contracts, frontend patch contracts and Python syntax.

Any failure is a stop point.

## Build gate

Run only after the offline gate passes:

```sh
make firmware STOCK=stock_decrypted.bin
```

Before repack the build verifies:

- TP-Link VPN controller bytecode remains stock;
- `netbirdvpn=5` registry extension;
- stock `VPN_TBL` validator rule shape;
- stock profile-key generation and `profile_key` mapping;
- transient Setup Key provider callback without persistence;
- stock list/ADD/EDIT/Save/toggle/DELETE/connected-status functions;
- no auxiliary enrollment or generic CRUD bridge;
- no nested provider `su-form`;
- profile-scoped model/runtime and orphan GC;
- `network.vpn.proto=netbird` + `profile_key` lifecycle;
- runtime rollback/routing-policy invariants;
- content cache-busting;
- build identity stamp.

## Hardware acceptance gate

Test from a clean NetBird profile state.

### First profile — one-step CREATE

Expected UI flow:

```text
Add -> NetBird -> Setup Key visible -> stock Save -> row visible -> stock toggle
```

Validate metadata without printing credentials:

```sh
uci show vpn.client
uci show network.vpn
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
find /tmp -maxdepth 1 -name 'nb-setup-key-*' -print
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
ip addr show wt0
```

Success requires:

- POST `/admin/vpn?form=server` does not return HTTP 500;
- new row appears in stock list;
- row key and `profile_key` match;
- one matching provider directory exists;
- no Setup Key is persisted;
- no temporary Setup Key file remains;
- activation happens only after the stock toggle.

### Multiple profiles

Create B with the same one-step flow and verify A/B both remain visible, keys and
provider directories differ, one profile never mutates the other, and only the
stock-selected profile is active.

### DELETE/GC

Delete B through the stock UI and run:

```sh
/etc/init.d/netbird-profile-gc start
```

B provider state must disappear while A remains.

### Routing peer

When enabled inspect:

```sh
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -S NETBIRD-RT-FWD-IN
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

Also test CIDR A -> B, routing ON -> OFF and WireGuard port X -> Y. No stale
rules may remain.

### Remote direction

From a real remote peer test:

1. remote peer -> AX53 overlay;
2. remote peer -> LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS without dependency on `10.8.0.1`.

## Current validation status — 2026-09-10

```text
clean native provider architecture: IMPLEMENTED IN CODE
multi-profile stock-keyed persistence: IMPLEMENTED IN CODE
no root-level profile fallback: IMPLEMENTED IN CODE
stock generic CRUD/list/toggle/delete/status boundary: ENFORCED BY SOURCE/BUILD GATES
Setup Key visible during CREATE: IMPLEMENTED IN CODE; HARDWARE PENDING
one-step Setup Key via stock Save provider callback: IMPLEMENTED IN CODE; HARDWARE PENDING
stock VPN_TBL rule shape fix for observed HTTP 500: IMPLEMENTED IN CODE; HARDWARE PENDING
nested su-form/layout fix: IMPLEMENTED IN CODE; HARDWARE PENDING
LuCI index-cache upvalue fix: IMPLEMENTED
browser cache busting: IMPLEMENTED
R2 runtime: PREVIOUSLY VALIDATED ON HARDWARE
latest make test-netbird: PENDING LOCAL EXECUTION AFTER THESE COMMITS
latest firmware build/repack: PENDING
hardware one-step ADD -> LIST acceptance: PENDING
multi-profile hardware acceptance: PENDING
remote peer -> AX53/LAN acceptance: PENDING
WG-Easy decommission: NOT AUTHORIZED
```

Do not claim the newest flow validated until the local gate, build and hardware
acceptance pass.
