# NetBird on TP-Link Archer AX53 V1 — Current Architecture

This document describes the **current firmware architecture**. NetBird is a
fifth TP-Link VPN Client provider. It is not a parallel VPN manager and the
current implementation contains no import/adoption path for data created by
older NetBird experiments.

## Architectural rule

TP-Link remains the owner of every generic VPN Client operation it already
implements:

```text
list
ADD
EDIT
Save / Cancel
enable / disable
DELETE
connected_status
```

NetBird-specific code is limited to:

```text
provider registration: netbirdvpn = type 5
provider-specific form fields and serialization
proto=netbird for netifd
NetBird runtime / R2 payload materialization
profile-scoped identity/settings/state
Setup Key enrollment
runtime / payload / log diagnostics
orphan provider-state garbage collection
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
        +-- network.vpn.profile_key=<stock key>
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

The vendor `usr/lib/lua/luci/controller/admin/vpn.lua` remains TP-Link bytecode.
`luci.model.netbird_vpn_native` extends the module-global registries used by the
controller:

```text
VPN_TYPE_TBL[netbirdvpn]      = 5
VPN_TYPE_NAME_TBL[netbirdvpn] = NetBird
VPN_TBL[netbirdvpn]           = stock-shaped schema, proto=netbird
VPN_CFG_TBL[netbirdvpn]       = NetBird config normalizer
```

`scripts/verify-tplink-vpn-bytecode.py` fails the build if the expected stock
registry contract is absent.

The native registry loader requires `luci.model.netbird_vpn_native` inside its
`index()` function. This avoids the LuCI index-cache upvalue failure previously
observed on the AX53.

## Profile authority and multi-profile storage

`vpn.server` is the authoritative saved-profile store. A saved row's stock key
is the namespace for all provider-specific persistent state.

For every NetBird profile:

```text
vpn.<stock-profile-key>=server
vpn.<stock-profile-key>.type=netbirdvpn
vpn.<stock-profile-key>.profile_key=<stock-profile-key>

/tp_data/netbird/profiles/<stock-profile-key>/
    settings
    default.json
    state/
```

Multiple NetBird profiles may coexist. There is no fixed `key=netbird`, no
singleton identity and no root-level profile context. Only the profile selected
by the normal TP-Link VPN Client state may be active at a time.

The `settings` file is a runtime materialization of the stock row. It is not a
second browser-writable profile database.

No profile-specific operation is allowed to fall back to:

```text
/tp_data/netbird/settings
/tp_data/netbird/default.json
/tp_data/netbird/state/
```

Those paths are not part of the current implementation.

## Auxiliary `/admin/netbird` boundary

`/admin/netbird` exists only for behavior the generic TP-Link VPN contract does
not implement:

```text
status          profile-scoped runtime/payload/traffic diagnostics
enroll          Setup Key enrollment for an already-saved stock row
restart         explicit restart delegated to /etc/init.d/vpnc
log             diagnostics for the active NetBird profile
payload_status  global payload diagnostics
```

It must not expose generic `settings_set`, `settings_get`, `connected_status`,
profile CRUD or DELETE helpers. Those remain under `/admin/vpn?form=server`.

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
TP-Link `su-*` controls and exposes the dynamic-form contract expected by the
stock dialog:

```text
isChanged
validate()
setForm()
getForm()
resetForm()
clearValidate()
```

`getForm()` returns protocol-specific fields only. CREATE versus EDIT is derived
from a persisted stock `key`/`id`; `type=netbirdvpn` exists in both modes and is
not used as an Edit signal.

The shared frontend model receives only the provider serializer needed to map
the Management URL hostname into TP-Link's common `server` field. Stock
list/request/update/delete/status functions remain unchanged.

The custom module import includes a content-derived query key so a firmware
update does not reuse a stale browser copy of `VpnServerNetbirdForm-NB.js`.

## Setup Key and enrollment

Enrollment is deliberately a second step:

```text
Add NetBird
  -> TP-Link Save
  -> stock row/key exists
  -> Edit that row
  -> enter Setup Key
  -> Enrollment
  -> enable with the stock toggle
```

The Setup Key is staged only in a restrictive temporary file and is removed
after the enrollment call. It is never stored in the stock row, provider
settings, repository or documentation.

## Provider-state garbage collection

DELETE remains the exact stock TP-Link operation. The provider does not wrap or
replace it.

Because NetBird identity files live outside `vpn.server`, a small one-shot
maintenance service removes directories under:

```text
/tp_data/netbird/profiles/<key>/
```

when the corresponding stock row no longer exists. A currently active profile
is retained fail-safe during a transient lifecycle/config race. The GC service
never creates profiles and never starts or stops NetBird.

## Runtime storage

Persistent provider state:

```text
/tp_data/netbird/profiles/<stock-profile-key>/settings
/tp_data/netbird/profiles/<stock-profile-key>/default.json
/tp_data/netbird/profiles/<stock-profile-key>/state/
```

Ephemeral:

```text
/tmp/netbird
/tmp/netbird.new
/tmp/netbird.valid
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

Failure is fail-closed for NetBird and must not take down WAN, Wi-Fi or DHCP.

## Lifecycle ownership

Normal lifecycle has one owner:

```text
TP-Link vpnc -> netifd -> proto_netbird -> shared runtime
```

There is no separate `/etc/init.d/netbird` lifecycle wrapper in the current
source. `netbird-ctl` is a CLI facade over the shared runtime; netifd does not
call it.

The netifd interface publishes UP only when all are true:

```text
wt0 exists
daemonStatus == Connected
management.connected == true
```

Immediate setup failure and connection timeout both rollback the runtime before
`proto_setup_failed`.

The polling recovery worker is an observer only: it can re-trigger TP-Link
`network.interface.vpn`/`vpnc`, but it cannot call `nb_runtime_connect` itself.

## Routing-peer mode

The UI option **Permitir roteamento da LAN** does not create or announce a
NetBird Network/Resource. The Network/Resource/Policy is managed in NetBird
Management and the AX53 is selected there as routing peer.

Local routing requires:

```text
advertise_lan=1
advertise_cidr=<local CIDR>
disable_server_routes=0
disable_firewall=0
```

The frontend enables the two prerequisites and both Lua and shell runtime
independently reject invalid combinations.

TP-Link scoped forwarding rules are appended after NetBird's own Route ACL
chains. A priority `iptables -I FORWARD ... ACCEPT` workaround is prohibited.
Applied firewall values are snapshotted in `/tmp/netbird-firewall.state` so a
configuration transition can remove the exact previous rules before applying
new values.

## Historical work

Earlier experiments and abandoned integration approaches remain available in Git
history and in the project Notion ADR/Timeline. They are not compatibility
requirements for this implementation and are not imported into the current
profile model.
