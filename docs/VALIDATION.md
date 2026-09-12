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
  -> provider-side Setup Key staging
  -> opaque enrollment_token through VPN_CFG_TBL[netbirdvpn]
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

The validator rule shape used by the current hardware-observed contract is:

```lua
{ key = key }
```

The previously inferred `{ field = { key }, canbe_empty = true }` shape is
forbidden by the current build gates.

The final frontend must retain the original stock functions for list,
ADD/EDIT Save, toggle/update, DELETE and connected status. Forbidden regressions
include synthetic rows, fixed `key=netbird`, custom Save/DELETE bridges,
`/admin/netbird` writable settings CRUD and auxiliary connected-status.

## Setup Key contract

The UI still uses one normal TP-Link Save, but the Setup Key itself stays outside
generic CRUD:

```text
Add -> NetBird -> provider fields + Setup Key
    -> validate() calls /admin/netbird stage_setup_key
    -> /tmp/netbird-setup-stage-<token> mode 0600
    -> opaque enrollment_token returned
    -> stock SALVAR
    -> stock key generated
    -> /admin/vpn?form=server
    -> VPN_CFG_TBL[netbirdvpn] validates token
    -> enrollment_token reaches network.vpn
    -> native netifd setup resolves staged key
    -> profile-scoped enrollment/runtime connection
    -> staged key + token state are cleared
```

Required properties:

- the Setup Key control is visible in CREATE;
- CREATE validation requires Setup Key;
- provider `validate()` stages the secret through `/admin/netbird`;
- provider `getForm()` supplies only `enrollment_token`;
- the serializer carries only `enrollment_token`, never `setup_key`;
- `setup_key` is not a `VPN_TBL` field or persistent profile value;
- staged key files use `/tmp/netbird-setup-stage-*` mode 0600;
- `VPN_CFG_TBL[netbirdvpn]` validates the staged token before handoff;
- `proto_netbird` resolves the staged key and owns enrollment/runtime connect;
- staged key/token state is cleared after consumption or invalidation;
- `/admin/netbird` stages/discards the secret but exposes no enrollment or
generic writable profile operation.

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

AX53 LAN gateway mode is valid only when:

```text
advertise_lan=1
disable_client_routes=0
disable_server_routes=0
disable_firewall=0
disable_dns=1
```

The service must run NetBird with the userspace datapath forced
(`NB_WG_KERNEL_DISABLED`, `NB_FORCE_USERSPACE_FIREWALL`,
`NB_FORCE_USERSPACE_ROUTER`) because the hardware kernel cannot satisfy the
native ipset-backed ACL requirements.

The corresponding Network/Resource/Policy is owned by NetBird Management. The
router does not create it.

Firewall/routing requirements:

- no direct priority `iptables -I/--insert FORWARD` bypass;
- scoped `br-lan -> wt0` rule in `forwarding_lan` before the stock LAN-zone DROP;
- scoped return/integration rule for `wt0 -> br-lan` only for the configured LAN CIDR;
- scoped `LAN CIDR -> wt0` MASQUERADE;
- scoped overlay `100.64.0.0/10 -> LAN CIDR` MASQUERADE;
- no legacy pref-500 `lookup vpn` rule and no `vpnDnsproxy` for `netbirdvpn`;
- firewall restart restores NetBird scoped rules via `firewall-sync` without restarting the daemon;
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
- provider-side Setup Key staging + opaque enrollment token without persistence;
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
find /tmp -maxdepth 1 -name 'netbird-setup-stage-*' -print
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
/tmp/netbird debug config --daemon-addr unix:///tmp/netbird.sock
/tmp/netbird status -d --daemon-addr unix:///tmp/netbird.sock
iptables -S FORWARD | grep wt0
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
ip rule show
```

Also test CIDR A -> B, routing ON -> OFF and WireGuard port X -> Y. No stale
rules may remain.

### Bidirectional acceptance

From a real remote peer test:

1. remote peer -> AX53 overlay;
2. remote peer -> LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable.

From a LAN host without NetBird:

4. LAN host -> remote NetBird Network resource;
5. LAN host -> shared private DNS resolver (for example `10.0.6.3:53`);
6. DNS works without dependency on `10.8.0.1`.

After reboot, repeat both directions and confirm the NetBird interface remains
Userspace and the effective daemon config still has client/server routes enabled
with DNS disabled.

## Current validation status — 2026-09-11

```text
clean native provider architecture: IMPLEMENTED IN CODE
multi-profile stock-keyed persistence: IMPLEMENTED IN CODE
no root-level profile fallback: IMPLEMENTED IN CODE
stock generic CRUD/list/toggle/delete/status boundary: ENFORCED BY SOURCE/BUILD GATES
Setup Key visible during CREATE: IMPLEMENTED IN CODE; HARDWARE PENDING
staged Setup Key + opaque stock Save token + deferred netifd enrollment: IMPLEMENTED IN CODE; HARDWARE PENDING
stock VPN_TBL rule shape fix for observed HTTP 500: IMPLEMENTED IN CODE; HARDWARE PENDING
nested su-form/layout fix: IMPLEMENTED IN CODE; HARDWARE PENDING
LuCI index-cache upvalue fix: IMPLEMENTED
browser cache busting: IMPLEMENTED
R2 runtime: PREVIOUSLY VALIDATED ON HARDWARE
down -> up config reconciliation: VALIDATED MANUALLY ON HARDWARE
remote Network route installation (10.0.6.3/32): VALIDATED MANUALLY IN KERNEL MODE
AX53 forced userspace WireGuard/firewall/router workaround: IMPLEMENTED IN CODE; HARDWARE PENDING
LAN -> wt0 scoped SNAT: IMPLEMENTED IN CODE; HARDWARE PENDING
NetBird DNS hard-disabled on AX53: IMPLEMENTED IN CODE; HARDWARE PENDING
legacy table-vpn/vpnDnsproxy isolation: IMPLEMENTED IN CODE; HARDWARE PENDING
latest make test-netbird: PENDING LOCAL EXECUTION AFTER THESE COMMITS
latest firmware build/repack: PENDING
hardware one-step ADD -> LIST acceptance: PENDING
multi-profile hardware acceptance: PENDING
remote peer -> AX53/LAN acceptance: PENDING
clientless LAN -> remote NetBird resource/DNS acceptance: PENDING
WG-Easy decommission: NOT AUTHORIZED
```

Do not claim the newest flow validated until the local gate, build and hardware
acceptance pass.
