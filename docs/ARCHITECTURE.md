# NetBird on TP-Link Archer AX53 V1 — Current Architecture

This document describes the **current** architecture. Historical experiments
with a `netbird_data` NAND/UBI partition, modified MIBIB, standalone S99 service,
synthetic frontend rows and dedicated `/admin/netbird` CRUD are retired. Their
history remains in Git and the project Notion ADR/Timeline; they are not part of
the current firmware design.

## End-to-end flow

NetBird is a genuine fifth TP-Link VPN Client type:

```text
TP-Link VPN Client UI
        |
        v
/admin/vpn?form=server
        |
        +-- type=netbirdvpn / type id=5 / display=NetBird
        +-- vpn/server                 authoritative profile
        +-- vpn.client                 authoritative active type
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
TP-Link bytecode. `luci.model.netbird_vpn_native` extends its module-global
registries at LuCI load time:

```text
VPN_TYPE_TBL[netbirdvpn]      = 5
VPN_TYPE_NAME_TBL[netbirdvpn] = NetBird
VPN_TBL[netbirdvpn]           = stock-shaped schema, proto=netbird
VPN_CFG_TBL[netbirdvpn]       = NetBird config normalizer
```

`scripts/verify-tplink-vpn-bytecode.py` fails the build if the stock bytecode no
longer exports those registries.

## Configuration authority

Normal profile CRUD/list/toggle/status is owned by the stock endpoint:

```text
/admin/vpn?form=server
```

`vpn/server` is the authoritative profile configuration store. `vpn.client`
controls which VPN Client type is active. `/tp_data/netbird/settings` is a
runtime materialized view consumed by the existing shell/runtime; it is updated
from the native profile handler and is not a second browser-writable profile
store.

The auxiliary endpoint:

```text
/admin/netbird
```

is restricted to concerns the generic TP-Link VPN contract does not own:

- status/diagnostics and read-only settings inspection;
- setup-key enrollment/re-enrollment;
- logs and payload state;
- manual restart delegated back to `/etc/init.d/vpnc`;
- recovery/identity cleanup after stock profile deletion.

It does not expose normal writable `settings_set` CRUD.

## Runtime storage

Persistent:

```text
/tp_data/netbird/default.json   NetBird identity/profile data
/tp_data/netbird/settings       runtime materialized settings
/tp_data/netbird/state/         NetBird runtime state
```

Ephemeral:

```text
/tmp/netbird                    validated executable
/tmp/netbird.new                decode staging
/tmp/netbird.sock               daemon control socket
/tmp/netbird.log                runtime log
/tmp/netbird-firewall.state     exact applied TP-Link firewall bookkeeping
```

The large NetBird executable is not stored in rootfs or a new NAND partition.
MIBIB remains stock.

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

Normal lifecycle has exactly one owner:

```text
vpnc -> netifd -> proto_netbird -> shared runtime
```

`netbird-ctl` is a CLI facade over the same shared runtime; netifd does not call
it. `/etc/init.d/netbird` is a compatibility/recovery wrapper and is **not**
linked as `/etc/rc.d/S99netbird` in the final native image.

The netifd interface publishes UP only if all are true:

```text
wt0 exists
daemonStatus == Connected
management.connected == true
```

`signal.connected` cannot substitute for management connectivity. Immediate
setup failure and timeout both rollback the runtime before `proto_setup_failed`.

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

Why both prerequisites are mandatory:

- NetBird v0.77.1 defines `--disable-server-routes=true` as preventing the peer
  from acting as router for server routes delivered by Management.
- NetBird v0.77.1 enforces routed authorization through
  `NETBIRD-RT-FWD-IN`/`NETBIRD-RT-FWD-OUT` Route ACL chains. Disabling its
  firewall or inserting a local ACCEPT ahead of those chains would bypass
  management policy.

The frontend automatically enables server routes and NetBird firewall when LAN
routing is selected. The Lua model and shell runtime independently reject an
invalid combination.

## Firewall integration

`src/init/netbird_firewall.inc` is the single canonical TP-Link firewall source
and is appended to `/lib/firewall/tpcmd.sh` by `mods/010-netbird.sh`.

Its purpose is scoped platform integration, not policy replacement:

- UDP `wireguard_port` INPUT transport rule;
- established/related return handling;
- optional CIDR-scoped `wt0 <-> LAN` forwarding integration;
- optional CIDR-scoped overlay -> LAN MASQUERADE.

Crucially, scoped TP-Link FORWARD rules are **appended**, not inserted at
position 1. NetBird's `NETBIRD-RT-FWD-*` chains must see inbound routed traffic
first. A direct `iptables -I FORWARD ... ACCEPT` workaround is prohibited.

The exact applied port/access/CIDR/home interface is snapshotted in RAM at:

```text
/tmp/netbird-firewall.state
```

When configuration changes A -> B, A is removed using that snapshot before B
is installed. This prevents stale CIDR/port rules after profile edits.

## Frontend

The NetBird protocol subform uses registered TP-Link `su-*` components and the
same dynamic-form contract as stock protocols:

```text
isChanged
validate()
setForm()
getForm()
resetForm()
clearValidate()
```

The outer TP-Link dialog owns Description, Type, key/id, Save/Cancel and row
identity. NetBird's subform owns protocol-specific fields only. Add starts in
CREATE mode; only a persisted stock `key`/`id` proves EDIT. `type=netbirdvpn`
is present in both modes and is not used as an Edit signal.

## Identity / single profile

The runtime uses one NetBird identity, one daemon and one `wt0`. The supported
product model is one NetBird profile on the router. The UI prevents creating a
second profile and the auxiliary status/enrollment code resolves the native
`vpn/server` profile by `type=netbirdvpn`.

Server-side hard enforcement against deliberately crafted duplicate admin API
requests remains a defense-in-depth item until the stock insert/update context
is proven sufficiently to implement it without breaking native CRUD.

## Historical architectures

The following are preserved only as history and must not be reintroduced into
the current build:

- MIBIB modification and a `netbird_data` UBI partition;
- payload stored in NAND instead of R2;
- standalone `/etc/rc.d/S99netbird` lifecycle;
- synthetic NetBird row merged into the stock VPN list;
- writable profile CRUD through `/admin/netbird`;
- monkey-patching stock dispatcher closures/upvalues;
- priority `FORWARD ACCEPT` rules ahead of NetBird Route ACLs.

See `docs/R2-RUNTIME.md`, `docs/VALIDATION.md`, `docs/INSTALL.md` and the project
Notion ADR/Timeline for rationale, evidence and migration history.
