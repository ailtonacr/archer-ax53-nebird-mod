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
  -> /etc/init.d/vpnc
  -> netifd
  -> /lib/netifd/proto/netbird.sh
  -> /lib/netbird/netbird-runtime.sh
  -> /tmp/netbird + wt0
```

The generic TP-Link list, ADD, EDIT, Save/Cancel, toggle, DELETE and
`connected_status` paths remain stock. `/admin/netbird` is auxiliary only for
profile-scoped NetBird runtime status, Setup Key enrollment, restart delegated
to `vpnc`, logs and payload diagnostics. It is not a second profile CRUD API.

The NetBird binary is **not** embedded in rootfs and is **not** stored on an
extra MTD/UBI partition. At runtime it is fetched over HTTPS, validates the
pinned compressed SHA-256, streams through `xzmini`, validates decoded size and
SHA-256, and is promoted atomically to `/tmp/netbird`. MIBIB remains stock.

## Step 0 — mandatory local gate

Preconditions:

- current branch must be `fix/netbird-ui-state-routing` while this work is under validation;
- working tree must contain only changes you intentionally want in the build;
- use the known decrypted stock image as the explicit build input.

Check first:

```sh
git branch --show-current
git status --short
git rev-parse HEAD
```

If the branch or working tree is unexpected, **stop** before building.

Run the offline gate:

```sh
make test-netbird
```

Any failure is a **stop point**. Do not build or flash around a failing gate.

Then build from an explicitly identified decrypted stock image:

```sh
make firmware STOCK=stock_decrypted.bin
```

The build recreates `rootfs/` from that stock image, applies the active mods,
validates the native provider contracts before repack and refuses the image if
the final bundles replace generic TP-Link list/Save/toggle/DELETE/status paths,
contain a synthetic NetBird row/key, expose parallel writable settings CRUD,
introduce a second lifecycle owner or bypass NetBird Route ACL ordering.

## Step 1 — backup and flash

Make a full NAND backup before any firmware flash. Keep physical recovery access
available.

Upload **only the `.bin` produced by the validated build** through the TP-Link
firmware upgrade UI or the already validated project upload/recovery procedure.
Do not write MIBIB, add a partition or use the historical `netbird_data` path.

After reboot, validate LAN/WAN/Wi-Fi/DHCP/NAT before touching NetBird. Keep the
fallback WG-Easy/WireGuard path available.

## Step 2A — router already has a historical NetBird identity

A router upgraded from the older singleton layout may already contain:

```text
/tp_data/netbird/default.json
/tp_data/netbird/settings
/tp_data/netbird/state/
```

The current firmware treats these files as migration input. On boot,
`netbird-profile-migrate` should adopt them **once** into a real stock
`vpn.server` row and copy the runtime identity into:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
```

Validate without exposing secrets:

```sh
uci show vpn | grep -E 'netbirdvpn|legacy_identity|profile_key'
ls -la /tp_data/netbird/profiles 2>/dev/null
sed -n '1,20p' /tp_data/netbird/legacy-adoption 2>/dev/null
```

Expected properties:

- one real `vpn.<key>=server` row with `type='netbirdvpn'`;
- `profile_key` associated with that row;
- a matching profile-scoped directory;
- adoption marker with `completed=1`;
- adopted profile initially disabled.

Do **not** print `default.json`, Setup Keys or other credentials into chat/logs.

If the stock row is absent after migration, stop and collect the non-secret
outputs above before attempting manual repair.

## Step 2B — create a new NetBird profile

1. Open **VPN → VPN Client**.
2. Choose **Add → VPN Type: NetBird**.
3. Fill only the protocol settings required for that profile, including the
   Management URL.
4. Click the normal TP-Link **SALVAR**.
5. Confirm that the new row appears in the normal stock list.
6. Re-open **Edit** on that saved row.
7. Enter the **Setup Key** and choose **Enrollment**.
8. After enrollment succeeds, enable the row using the normal TP-Link toggle.

This two-step Save → Edit → Enrollment flow is intentional. The authoritative
stock row key does not exist before the first Save, and the NetBird identity is
scoped to that key. Supporting enrollment inside the first Save would require
intercepting the generic Save lifecycle, which the current architecture forbids.

The Setup Key is staged only in `/tmp` for the enrollment operation and must not
be stored in repository, Notion or persistent profile settings.

## Step 3 — validate multiple NetBird profiles

The current model supports multiple saved profiles from the same provider. Only
one TP-Link VPN Client profile is active at a time, but their identities must be
independent.

Create or inspect at least two saved NetBird rows and verify:

```sh
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
```

Success criteria:

- distinct stock row keys;
- distinct provider directories;
- editing/enrolling profile A does not change profile B;
- toggling the active profile does not overwrite another identity.

Do not dump the contents of identity files.

## Step 4 — validate native lifecycle

For the active NetBird row:

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
vpn.client -> network.vpn.proto=netbird -> vpnc -> netifd -> proto_netbird
```

The interface is considered connected only when the runtime confirms `wt0`,
`daemonStatus=Connected` and `management.connected=true`.

`/etc/init.d/netbird` is only a compatibility/manual wrapper. A final image must
not contain an active `/etc/rc.d/S99netbird` lifecycle owner.

## Step 5 (optional) — make AX53 a routing peer

In the NetBird profile enable **Permitir roteamento da LAN** and set the exact
local CIDR, currently for example:

```text
192.168.10.0/24
```

This does not create a NetBird Network/Resource. In NetBird Management create or
confirm the appropriate Network/Resource/Policy and select the AX53 as routing
peer.

Routing mode requires:

```text
advertise_lan=1
disable_server_routes=0
disable_firewall=0
```

The frontend enables both prerequisites automatically when LAN routing is
selected; the Lua model and shell runtime independently reject contradictory
settings.

Inspect applied state and ordering:

```sh
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -S NETBIRD-RT-FWD-IN
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

A local priority ACCEPT before NetBird's route-policy chain is a **stop
condition**. The platform integration must not bypass NetBird Route ACLs.

## Step 6 — validate remote direction

Router-local tests do not prove the actual remote-access path. From a real
remote NetBird peer test separately:

1. remote peer → AX53 overlay address;
2. remote peer → LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS through the target architecture without dependency on historical
   `10.8.0.1`/WG-Easy.

Only after these pass should WG-Easy decommission be considered.

## DELETE and provider-state cleanup

DELETE itself remains the exact stock TP-Link operation. There is no custom
frontend DELETE bridge.

The authoritative row disappears immediately from `vpn.server`. Profile-scoped
NetBird state that no longer has a stock row is garbage-collected independently
by `netbird-profile-migrate` maintenance. The current implementation runs that
maintenance during boot, so orphan-directory cleanup is **not claimed to be
synchronous with DELETE**.

The one-shot legacy adoption marker remains `completed=1`; therefore deleting an
adopted historical row must not cause the old singleton source to recreate it at
the next boot.

After intentionally deleting a NetBird row and rebooting, validate only metadata
and directory names:

```sh
uci show vpn | grep -E 'netbirdvpn|profile_key' || true
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
sed -n '1,20p' /tp_data/netbird/legacy-adoption 2>/dev/null
```

## Firewall mutation test

At least once, test these controlled transitions:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

After each transition verify that old A/X rules are absent and
`/tmp/netbird-firewall.state` matches the current active profile.

## Payload/runtime checks

```sh
/sbin/netbird-ctl payload-status
/sbin/netbird-ctl status
/sbin/netbird-ctl log 50
```

Payload states:

```text
READY
PAYLOAD_NOT_DOWNLOADED
PAYLOAD_DOWNLOAD_FAILED
PAYLOAD_INVALID
```

Payload failure is fail-closed for NetBird and must not take down WAN, Wi-Fi,
DHCP or the fallback VPN path.

## Stop conditions

Do not remove WG-Easy or continue deployment if any of these are true:

- local branch/working tree is not the intended build state;
- `make test-netbird` fails;
- pre-repack build validation fails;
- the final shared frontend no longer uses stock list/Save/toggle/DELETE/status;
- an existing historical NetBird identity is not adopted into a real stock row;
- two NetBird profiles share the same provider identity directory;
- Setup Key appears in persistent profile settings;
- active NetBird does not produce `network.vpn.proto=netbird`;
- more than one normal lifecycle owner starts NetBird;
- `network.interface.vpn` reports usable connectivity without `wt0` and
  management connectivity;
- routing is enabled with server routes or NetBird firewall disabled;
- a local FORWARD ACCEPT bypasses NetBird Route ACL ordering;
- applied firewall state disagrees with active settings;
- stale CIDR/port rules remain after mutation;
- remote peer → AX53/LAN validation fails;
- DNS still depends on the historical WG-Easy path.
