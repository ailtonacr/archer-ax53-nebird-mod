# NetBird on Archer AX53 V1 — Installation (R2 runtime)

**Stop point: nothing below is flashed automatically. Run each step yourself
after reviewing.**

## Current architecture

NetBird is a fifth native TP-Link VPN Client provider:

```text
TP-Link VPN Client UI
  -> /admin/vpn?form=server
  -> type=netbirdvpn / id=5
  -> network.vpn.proto=netbird
  -> network.vpn.profile_key=<stock key>
  -> /etc/init.d/vpnc
  -> netifd
  -> /lib/netifd/proto/netbird.sh
  -> /lib/netbird/netbird-runtime.sh
  -> /tmp/netbird + wt0
```

The generic TP-Link list, ADD, EDIT, Save/Cancel, toggle, DELETE and
`connected_status` paths remain stock. `/admin/netbird` is auxiliary only for
profile-scoped status, Setup Key enrollment, restart delegated to `vpnc`, logs
and payload diagnostics.

There is no profile import/adoption path. The new implementation expects a clean
NetBird profile namespace and creates state only under:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
```

The NetBird executable is not embedded in rootfs and is not stored on an extra
MTD/UBI partition. It is fetched from R2 over HTTPS, validated against pinned
hashes and materialized into `/tmp/netbird`. MIBIB remains stock.

## Step 0 — mandatory local gate

Preconditions:

- current branch: `fix/netbird-ui-state-routing` while this work is under validation;
- working tree contains only changes intentionally included in the build;
- the decrypted stock firmware input is known explicitly.

Check:

```sh
git branch --show-current
git status --short
git rev-parse HEAD
```

If the branch or working tree is unexpected, stop before building.

Run:

```sh
make test-netbird
```

Any failure is a **stop point**. Do not build or flash around a failing gate.

Then:

```sh
make firmware STOCK=stock_decrypted.bin
```

The build recreates `rootfs/` from stock, applies the mods and verifies that the
final image keeps TP-Link generic VPN semantics stock while adding the NetBird
provider.

## Step 1 — prepare the router for the clean implementation

This implementation does not consume any previously created NetBird identity or
profile state. Before validating the new firmware, remove old NetBird state from
the router using an explicitly reviewed cleanup procedure.

Do not remove unrelated VPN profiles, do not touch MIBIB/MTD/UBI and do not
remove the fallback WG-Easy/WireGuard path.

After cleanup, the acceptance baseline is:

```text
no old NetBird profile/state is relied upon
new NetBird profiles will be created through the TP-Link VPN Client UI
```

## Step 2 — backup and flash

Make a full NAND backup before a firmware flash and keep physical recovery access
available.

Upload only the `.bin` produced by the validated build through the normal TP-Link
firmware upgrade UI or the project procedure already validated for this router.

After reboot validate LAN/WAN/Wi-Fi/DHCP/NAT before touching NetBird. Keep the
fallback VPN available.

## Step 3 — create the first NetBird profile

1. Open **VPN → VPN Client**.
2. Choose **Add → VPN Type: NetBird**.
3. Fill the provider fields, including the Management URL.
4. Click the normal TP-Link **SALVAR**.
5. Confirm the row appears in the normal stock list.
6. Re-open **Edit** on that saved row.
7. Enter the **Setup Key** and run **Enrollment**.
8. After enrollment succeeds, enable the row with the normal TP-Link toggle.

The Save → Edit → Enrollment sequence is intentional. The stock row key does not
exist until TP-Link saves the profile, and NetBird persistent identity is scoped
to that exact key.

The Setup Key is staged only temporarily and must not be written to repository,
Notion or persistent settings.

## Step 4 — validate multiple NetBird profiles

The model supports multiple saved profiles of the same provider. Only one
TP-Link VPN Client profile is active at a time, but identities must remain
independent.

Create a second NetBird profile and validate metadata only:

```sh
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
```

Success criteria:

- two distinct stock row keys;
- two distinct provider directories;
- enrollment/edit of A does not alter B;
- enrollment/edit of B does not alter A;
- toggling the active profile does not overwrite another identity.

Do not print `default.json` or any credential material.

## Step 5 — validate native lifecycle

For the active NetBird profile:

```sh
uci show vpn.client
uci show network.vpn
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
ip addr show wt0
```

Expected chain:

```text
vpn.client
  -> network.vpn.proto=netbird
  -> network.vpn.profile_key=<stock key>
  -> vpnc
  -> netifd
  -> proto_netbird
  -> shared NetBird runtime
```

The interface is connected only when:

```text
wt0 exists
daemonStatus=Connected
management.connected=true
```

There is no separate `/etc/init.d/netbird` lifecycle owner in the current
implementation.

## Step 6 — validate DELETE and provider-state GC

DELETE the test profile using the normal TP-Link list action. The stock row must
disappear immediately without a custom frontend DELETE bridge.

The one-shot `netbird-profile-gc` service removes provider directories that no
longer have a matching `vpn.server` row. It never creates profiles and never
starts/stops NetBird.

After running the maintenance service or rebooting, verify only names/metadata:

```sh
/etc/init.d/netbird-profile-gc start
uci show vpn | grep -E 'netbirdvpn|profile_key' || true
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
```

Deleting profile B must never remove profile A's directory.

## Step 7 — optional LAN routing peer

In the active NetBird profile enable **Permitir roteamento da LAN** and configure
the exact local CIDR, for example:

```text
192.168.10.0/24
```

Required provider settings:

```text
advertise_lan=1
disable_server_routes=0
disable_firewall=0
```

The corresponding Network/Resource/Policy is still created in NetBird
Management, with the AX53 selected as routing peer. The router UI does not create
control-plane resources.

Inspect runtime firewall state:

```sh
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -S NETBIRD-RT-FWD-IN
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

A local priority ACCEPT before NetBird's routing policy chain is a stop
condition.

Also test state transitions:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

No rules from A/X may remain after the transition.

## Step 8 — validate remote direction

From a real remote NetBird peer test separately:

1. remote peer → AX53 overlay address;
2. remote peer → LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS through the target architecture without dependency on `10.8.0.1`.

Only after those tests pass should WG-Easy decommission be considered.

## Stop conditions

Do not merge/deploy/remove the fallback VPN if any of these occur:

- `make test-netbird` fails;
- build pre-repack verification fails;
- NetBird does not appear as a normal stock VPN Client row after Save;
- two saved NetBird profiles share provider identity/state;
- `vpn.client.vpntype != netbirdvpn` for an active NetBird profile;
- `network.vpn.proto != netbird`;
- `network.vpn.profile_key` does not match the active stock row;
- more than one lifecycle owner starts NetBird;
- `network.interface.vpn` is UP without `wt0` and management connectivity;
- LAN routing is enabled with server routes or NetBird firewall disabled;
- a local FORWARD ACCEPT bypasses NetBird Route ACLs;
- remote peer → AX53/LAN fails;
- DNS still depends on the WG-Easy path.
