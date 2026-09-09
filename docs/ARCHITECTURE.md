# NetBird on TP-Link Archer AX53 V1 — Current Architecture

This document describes the **current** architecture. Historical experiments
with a `netbird_data` NAND/UBI partition, modified MIBIB, standalone S99 service,
synthetic frontend rows and dedicated `/admin/netbird` CRUD are retired. Their
history remains in Git and the project Notion ADR/Timeline; they are not part of
the current firmware design.

## Architectural rule

NetBird is a **fifth TP-Link VPN Client provider**, not a parallel VPN manager.
The firmware must reuse the vendor flow whenever TP-Link already provides the
operation.

Generic operations remain stock:

```text
list
ADD
EDIT
Save / Cancel
enable / disable
DELETE
connected_status
```

Custom code is allowed only where a new protocol/provider necessarily needs it:

```text
provider registration: netbirdvpn = type 5
provider-specific form fields and serialization
proto=netbird for netifd
NetBird runtime / payload materialization
profile-scoped NetBird identity
Setup Key enrollment
runtime / payload / log diagnostics
legacy identity adoption and orphan-state maintenance
```

## End-to-end flow

```text
TP-Link VPN Client UI
        |
        v
/admin/vpn?form=server                    <- generic flow remains stock
        |
        +-- type=netbirdvpn / id=5 / display=NetBird
        +-- vpn.server                    <- authoritative saved profiles
        +-- vpn.client                    <- authoritative active provider
        +-- network.vpn.proto=netbird
                    |
                    v
          /etc/init.d/vpnc
                    |
                    v
             vpn_core.sh
                    |
                    v
                 netifd
                    |
                    v
       /lib/netifd/proto/netbird.sh
                    |
                    v
       /lib/netbird/netbird-runtime.sh
                    |
          +---------+----------+
          |                    |
          v                    v
/lib/netbird/netbird.sh   NetBird v0.77.1
          |                    |
          v                    v
R2 HTTPS -> xzmini       /tmp/netbird.sock
          |                    |
          v                    v
     /tmp/netbird              wt0
```

The vendor `usr/lib/lua/luci/controller/admin/vpn.lua` remains byte-for-byte
TP-Link bytecode. `luci.model.netbird_vpn_native` extends the module-global
registries used by that controller:

```text
VPN_TYPE_TBL[netbirdvpn]      = 5
VPN_TYPE_NAME_TBL[netbirdvpn] = NetBird
VPN_TBL[netbirdvpn]           = stock-shaped schema, proto=netbird
VPN_CFG_TBL[netbirdvpn]       = NetBird config normalizer
```

`scripts/verify-tplink-vpn-bytecode.py` fails the build if the stock bytecode no
longer exports the required registries.

The loader requires `luci.model.netbird_vpn_native` **inside** its `index()`
function. This is deliberate: the LuCI dispatcher on this firmware serializes
controller `index()` functions into an index cache and does not preserve local
upvalues when reconstructing the tree. Capturing the module in a top-level local
previously caused global LuCI HTTP 500 responses during `createtree()`.

## Configuration and profile authority

`vpn.server` is the authoritative saved-profile store. The stock row key is the
namespace for provider identity and runtime materialization.

For every saved NetBird row:

```text
vpn.<stock-profile-key>=server
vpn.<stock-profile-key>.type=netbirdvpn

/tp_data/netbird/profiles/<stock-profile-key>/
    settings
    default.json
    state/
```

Multiple NetBird profiles may coexist. There is no synthetic `key=netbird` and
no singleton restriction. Only the profile selected by TP-Link's normal VPN
Client state is active at a time.

The provider's `settings` file is a materialized runtime view of the stock row;
it is not a second browser-writable CRUD store.

## Auxiliary `/admin/netbird` boundary

`/admin/netbird` is not a second VPN profile API. It is restricted to behavior
for which the generic TP-Link contract has no equivalent:

```text
status          profile-scoped NetBird runtime/payload/traffic diagnostics
enroll          Setup Key enrollment for an already-saved stock row
restart         explicit restart delegated to /etc/init.d/vpnc
log             runtime diagnostics
payload_status  payload diagnostics
```

It must not expose generic `settings_set`, `settings_get`, `connected_status`,
`profile_delete` or `clean` HTTP operations. Generic list/CRUD/toggle/delete and
connected-status remain in `/admin/vpn?form=server`.

## Frontend boundary

The outer TP-Link dialog owns:

```text
Description
VPN Type
row key / identity
Save / Cancel
enable / disable
DELETE
```

`VpnServerNetbirdForm-NB.js` is only the protocol subform. It uses registered
TP-Link `su-*` controls and exposes the same dynamic-form contract expected by
the stock dialog:

```text
isChanged
validate()
setForm()
getForm()
resetForm()
clearValidate()
```

`getForm()` returns only NetBird protocol fields. It does not own `key`, `id`,
`type`, `description`, `enable`, `enabled` or `enrolled` as generic profile
fields.

CREATE versus EDIT is determined only by a persisted stock `key`/`id`.
`type=netbirdvpn` exists in both modes and therefore cannot be an Edit signal.

The shared frontend model receives only one provider-specific serializer rule:
for NetBird, the full Management URL is normalized to a hostname in TP-Link's
common `server` field while `management_url` remains available to the NetBird
handler. The original stock request/update/delete/status functions are not
replaced.

## Setup Key and enrollment

Enrollment is deliberately a second step:

```text
Add NetBird
  -> TP-Link Save
  -> stock row/key now exists
  -> Edit that row
  -> enter Setup Key
  -> Enrollment
  -> enable with the stock toggle
```

The provider identity directory is keyed by the saved stock row, so initial ADD
has no safe profile identity yet. Performing enrollment inside the first Save
would require intercepting TP-Link's generic Save lifecycle, which is explicitly
rejected by the current architecture.

The Setup Key is staged only in a restrictive temporary file for the explicit
enrollment call and is not persisted in the profile settings or documentation.

## Historical singleton adoption

Older firmware stored a single NetBird identity directly under:

```text
/tp_data/netbird/default.json
/tp_data/netbird/settings
/tp_data/netbird/state/
```

Those paths are now **migration input only**. `netbird-profile-migrate` performs
a one-time adoption:

1. detect historical artifacts;
2. create a real `vpn.server` row of type `netbirdvpn`;
3. copy identity/settings/state into the row-keyed profile directory;
4. mark the adopted profile disabled initially;
5. write a permanent `completed=1` adoption marker.

The completion marker is intentionally permanent. If the adopted stock profile
is later deleted, the historical source must not recreate it on the next boot.

`nb_profile_gc_orphans()` removes profile-scoped NetBird directories whose
authoritative stock NetBird row no longer exists, except for a currently active
profile during a transient lifecycle/config inconsistency. This maintenance is
independent from generic TP-Link DELETE; the DELETE function itself stays stock.

At present the maintenance service runs during boot. Therefore provider-state
cleanup after DELETE is not claimed to be synchronous; the stock row disappears
immediately, while an orphan provider directory may remain until maintenance
runs. This is a cleanup-latency issue, not an alternate CRUD path.

## Runtime storage

Persistent native profile state:

```text
/tp_data/netbird/profiles/<stock-profile-key>/settings
/tp_data/netbird/profiles/<stock-profile-key>/default.json
/tp_data/netbird/profiles/<stock-profile-key>/state/
```

Persistent migration metadata/input:

```text
/tp_data/netbird/default.json       historical singleton source
/tp_data/netbird/settings           historical singleton source
/tp_data/netbird/state/             historical singleton source
/tp_data/netbird/legacy-adoption    one-shot adoption marker
```

Ephemeral:

```text
/tmp/netbird
/tmp/netbird.new
/tmp/netbird.sock
/tmp/netbird.log
/tmp/netbird-active-profile
/tmp/netbird-firewall.state
```

The large executable is not stored in rootfs or a new NAND partition. MIBIB
remains stock.

## R2 materialization

Pinned payload:

```text
version:            0.77.1
compressed size:    9,455,188 bytes
compressed SHA-256: 4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941
decoded size:       39,125,176 bytes
decoded SHA-256:    6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6
```

Materialization is two-pass streaming:

1. HTTPS download -> `sha256sum`, without storing the compressed payload.
2. HTTPS download -> `xzmini` -> `/tmp/netbird.new`.
3. Validate decoded size and SHA-256.
4. `chmod 0755` and atomic rename to `/tmp/netbird`.

No executable is promoted before both pinned hashes and decoded size pass.
Failure leaves NetBird unavailable but must not take down WAN/Wi-Fi/DHCP or the
fallback VPN path.

## Lifecycle ownership

Normal lifecycle has one owner:

```text
vpnc -> netifd -> proto_netbird -> shared runtime
```

`netbird-ctl` is a CLI facade over that runtime; netifd does not call it.
`/etc/init.d/netbird` is a compatibility/recovery wrapper and is **not** linked
as `/etc/rc.d/S99netbird` in the final image.

The recovery supervisor also is not a direct lifecycle owner. It observes the
stock active intent and, if recovery is needed, re-triggers
`network.interface.vpn` or `/etc/init.d/vpnc` instead of calling
`nb_runtime_connect` itself.

The netifd interface publishes UP only when the runtime verifies:

```text
wt0 exists
daemonStatus == Connected
management.connected == true
```

Immediate setup failure and connection timeout both roll back the runtime before
`proto_setup_failed`.

## Vendor acceleration exception

`/lib/vpn/vpn_core.sh` remains the stock lifecycle path. One provider-specific
compatibility guard is inserted around the vendor acceleration hooks because
those hooks know only the original PPTP/L2TP/OpenVPN/WireGuard families:

```sh
if [ "$vpntype" != "netbirdvpn" ]; then
    fw vpnc_access_accel_handle "$vpntype"
    fw vpnc_accelskip_add "$vpntype"
fi
```

For all original TP-Link providers, the original calls still execute. NetBird
continues through the generic `vpnc -> network.interface.vpn -> netifd` path.

## Routing-peer mode

The UI option is **Permitir roteamento da LAN**. It does not create or announce
a NetBird Network/Resource. The matching Network/Resource/Policy must already
exist in NetBird Management with the AX53 selected as routing peer.

Local routing requires:

```text
advertise_lan=1
advertise_cidr=<local CIDR>
disable_server_routes=0
disable_firewall=0
```

NetBird v0.77.1 owns routed authorization through its
`NETBIRD-RT-FWD-IN`/`NETBIRD-RT-FWD-OUT` chains. The TP-Link integration rules
are scoped platform/NAT plumbing and must never be inserted ahead of NetBird's
Route ACL decision.

The exact applied port/access/CIDR/home interface is snapshotted in RAM at:

```text
/tmp/netbird-firewall.state
```

When configuration changes A -> B, A is removed from that snapshot before B is
installed, preventing stale CIDR/port rules.

## Build invariants

The offline/build gates fail if the final artifact no longer preserves the
exact stock functions for:

```text
connected_status
update / toggle
DELETE
list
ADD / EDIT Save
```

They also reject synthetic NetBird rows, a fixed `netbird` profile key,
`settings_set`, generic `/admin/netbird` CRUD helpers, DOM Save interception,
parallel lifecycle ownership and priority FORWARD ACL bypasses.

## Historical architectures

The following are preserved only as history and must not be reintroduced:

- MIBIB modification and a `netbird_data` UBI partition;
- payload stored in NAND instead of R2;
- standalone `/etc/rc.d/S99netbird` lifecycle;
- synthetic NetBird row merged into the stock list;
- singleton `key=netbird` identity;
- writable generic profile CRUD through `/admin/netbird`;
- custom Save/toggle/DELETE/connected-status bridges;
- monkey-patching stock dispatcher closures/upvalues;
- priority `FORWARD ACCEPT` rules ahead of NetBird Route ACLs.

See `docs/R2-RUNTIME.md`, `docs/VALIDATION.md`, `docs/INSTALL.md` and the project
Notion ADR/Timeline for evidence, migration history and validation state.
