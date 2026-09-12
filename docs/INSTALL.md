# NetBird on Archer AX53 V1 — Installation (R2 runtime)

**Stop point: nothing below is flashed automatically. Run each step yourself
after reviewing.**

## Current architecture

NetBird is a fifth native TP-Link VPN Client provider:

```text
TP-Link VPN Client UI
  -> /admin/vpn?form=server
  -> type=netbirdvpn / id=5
  -> provider validate() stages Setup Key under /tmp and receives an opaque token
  -> stock Save generates/reuses the profile key and carries only enrollment_token
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
profile-scoped status, restart delegated to `vpnc`, logs and payload diagnostics.
Enrollment is not a second generic Save flow. The provider endpoint only stages
the secret; stock Save carries an opaque token, and the native netifd lifecycle
later resolves that token and performs enrollment/runtime connection.

There is no profile import/adoption path. Provider state exists only under:

```text
/tp_data/netbird/profiles/<stock-profile-key>/
```

The NetBird executable is not embedded in rootfs and is not stored on an extra
MTD/UBI partition. It is fetched from R2 over HTTPS, hash-validated and
materialized into `/tmp/netbird`. MIBIB remains stock.

## Step 0 — mandatory local gate

Preconditions:

- current branch: `fix/netbird-ui-state-routing` while this work is under validation;
- working tree contains only intentional local changes;
- decrypted stock firmware input is explicit.

Check:

```sh
git branch --show-current
git status --short
git rev-parse HEAD
```

Unexpected branch/tree is a stop condition.

Run:

```sh
make test-netbird
```

Any failure is a **stop point**. Then build:

```sh
make firmware STOCK=stock_decrypted.bin
```

The build recreates `rootfs/` from stock and verifies the final image before
repack.

## Step 1 — clean old NetBird state

This implementation intentionally does not consume old NetBird identity/profile
state. The user elected a clean break from all prior experiments.

Before validating the new firmware, remove old NetBird state only with an
explicitly reviewed cleanup procedure. Do not remove unrelated VPN profiles,
do not touch MIBIB/MTD/UBI, and keep the fallback WireGuard/WG-Easy path until
NetBird acceptance is complete.

## Step 2 — backup and flash

Keep a full NAND backup and physical recovery access available. Upload only the
`.bin` produced by the validated build through the normal TP-Link firmware
upgrade path or another already-validated project procedure.

After reboot validate LAN/WAN/Wi-Fi/DHCP/NAT before touching NetBird.

## Step 3 — create the first NetBird profile

1. Open **VPN → VPN Client**.
2. Choose **Add → VPN Type: NetBird**.
3. Fill Description and the NetBird provider fields.
4. Enter the **Setup Key** in the same Add dialog.
5. Click the normal TP-Link **SALVAR**.
6. Confirm the row appears in the normal TP-Link list.
7. Confirm the Setup Key is not present in UCI/provider settings.
8. Enable the row with the normal TP-Link toggle.

Expected flow:

```text
Add NetBird
  -> provider fields + Setup Key
  -> validate() stages /tmp/netbird-setup-stage-<token> mode 0600
  -> form receives opaque enrollment_token
  -> stock SALVAR
  -> stock serializer key=e.key||t()
  -> /admin/vpn?form=server
  -> VPN_CFG_TBL[netbirdvpn] validates token and hands it to network.vpn
  -> stock row visible
  -> native vpnc/netifd setup resolves staged key
  -> NetBird identity is enrolled under profiles/<stock key>/
  -> staged key is removed and enrollment_token is cleared
```

The Setup Key is transient provider-side input. It must never enter the stock
Save payload, `vpn.server`, persistent provider settings, repository or Notion.
Only the opaque `enrollment_token` may cross the stock Save boundary.

To validate without printing secrets:

```sh
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
find /tmp -maxdepth 1 -name 'netbird-setup-stage-*' -print
```

Success requires one stock row and one matching provider directory. After the
native netifd lifecycle consumes or discards the token, no
`/tmp/netbird-setup-stage-*` file may remain.

## Step 4 — validate multiple NetBird profiles

Create a second profile through the same Add + Setup Key + stock Save flow.

```sh
uci show vpn | grep -E "=server|type='netbirdvpn'|profile_key="
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
```

Success criteria:

- A and B both appear in the stock list;
- two distinct stock row keys;
- two distinct provider directories;
- editing/toggling A does not mutate B;
- editing/toggling B does not mutate A;
- only the TP-Link-selected profile is active.

Never print `default.json`, Setup Keys or credential material.

## Step 5 — validate native lifecycle

For the active profile:

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

The interface is connected only when `wt0` exists, `daemonStatus=Connected` and
`management.connected=true`. There is no standalone `/etc/init.d/netbird`
lifecycle owner.

## Step 6 — validate DELETE and provider-state GC

DELETE profile B using the normal TP-Link list action. The stock row must vanish
immediately with no NetBird-specific frontend DELETE bridge. Then run/reboot the
one-shot provider-state GC:

```sh
/etc/init.d/netbird-profile-gc start
uci show vpn | grep -E 'netbirdvpn|profile_key' || true
find /tp_data/netbird/profiles -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
```

B's provider directory must disappear while A remains. The GC never creates
profiles and never starts/stops NetBird.

## Step 7 — optional LAN routing peer

Enable **Permitir roteamento da LAN** and configure the exact LAN CIDR, e.g.:

```text
192.168.10.0/24
```

Required provider state:

```text
advertise_lan=1
disable_client_routes=0
disable_server_routes=0
disable_firewall=0
disable_dns=1
```

On the AX53 the implementation forces NetBird's userspace WireGuard/firewall/router
because the QSDK kernel cannot reliably apply the ipset-backed Route ACL rules.
NetBird DNS stays disabled locally; use the router DHCP to distribute the same
private resolver that NetBird distributes to remote peers.

The corresponding Network/Resource/Policy is created in NetBird Management with
the AX53 selected as routing peer; the router UI does not create control-plane
resources.

Inspect:

```sh
cat /tmp/netbird-firewall.state
/tmp/netbird debug config --daemon-addr unix:///tmp/netbird.sock
/tmp/netbird status -d --daemon-addr unix:///tmp/netbird.sock
iptables -S FORWARD | grep wt0
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
ip rule show
```

Success requires Userspace interface mode, no legacy `lookup vpn` rule, scoped
LAN<->wt0 forwarding, and a scoped `-o wt0 -s <LAN-CIDR> -j MASQUERADE`.
A priority broad ACCEPT remains a stop condition.
Also validate CIDR A -> CIDR B, routing ON -> OFF and WireGuard port X -> Y with
no stale rules.

## Step 8 — remote acceptance

From a real remote NetBird peer test separately:

1. remote peer -> AX53 overlay address;
2. remote peer -> LAN host through AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS through the target architecture without dependency on `10.8.0.1`.

WG-Easy decommission is not authorized until these pass.

## Stop conditions

Do not merge/deploy/remove the fallback VPN if any of these occur:

- `make test-netbird` fails;
- build pre-repack verification fails;
- NetBird does not appear as a stock row after the one-step Save;
- Setup Key appears in persistent configuration or remains in `/tmp`;
- two NetBird profiles share provider identity/state;
- `vpn.client.vpntype != netbirdvpn` for an active NetBird profile;
- `network.vpn.proto != netbird`;
- `network.vpn.profile_key` does not match the active stock row;
- more than one lifecycle owner starts NetBird;
- `network.interface.vpn` is UP without `wt0` and management connectivity;
- LAN routing is enabled with client routes, server routes or NetBird firewall disabled;
- NetBird DNS is enabled on the AX53;
- the NetBird interface is not in Userspace mode on this QSDK build;
- the legacy TP-Link `lookup vpn` rule or `vpnDnsproxy` is active;
- a broad local FORWARD ACCEPT bypass exists;
- remote peer -> AX53/LAN fails;
- DNS still depends on the WG-Easy path.
