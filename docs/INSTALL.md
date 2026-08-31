# NetBird on Archer AX53 V1 — Installation (R2 runtime)

**Stop point: nothing below is flashed automatically. Run each step yourself
after reviewing.**

## Current architecture

NetBird is a fifth native TP-Link VPN Client type:

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

`/admin/netbird` is auxiliary only for enrollment, diagnostics/logs/payload,
restart/recovery and idempotent identity cleanup. It does **not** own normal
profile settings writes. The stock `/admin/vpn?form=server` profile is the
normal configuration authority.

The NetBird binary is **not** embedded in rootfs and is **not** stored on an
extra MTD/UBI partition. At runtime it is fetched over HTTPS, validates the
pinned compressed SHA-256, streams through `xzmini`, validates decoded size and
SHA-256, and is promoted atomically to `/tmp/netbird`. Identity/runtime settings
persist under `/tp_data/netbird/`.

The historical MIBIB / `netbird_data` / UBI artifacts under `mibib/` and
`netbird-data/` are **NOT used by the current runtime**. MIBIB remains stock.

## Step 0 — mandatory local gate

Before producing a firmware image:

```sh
make test-netbird
```

Any failure is a **stop point**. Do not build/flash around a failing gate.

Then build from an explicitly identified decrypted stock image:

```sh
make firmware STOCK=stock_decrypted.bin
```

The build recreates `rootfs/` from that stock image, applies the mods, validates
the native NetBird contracts before repack, and refuses the image if the final
bundle still contains hybrid writable `settings_set`, a parallel NetBird boot
owner, type-derived Add/Edit semantics, or a missing routing/firewall invariant.

## Step 1 — backup and flash

Make a full NAND backup before any future flash (see
`tp-link-ax53-fw-hacks/README.md` "Taking full Partition backup"). Keep physical
recovery access available.

Upload **only the firmware `.bin` produced by the validated build** via
**Advanced → System Tools → Firmware Upgrade**, or use the already validated
recovery path when required.

After reboot, validate LAN/WAN/Wi-Fi/DHCP/NAT before testing NetBird. Do not
remove the fallback WG-Easy/WireGuard path at this stage.

## Step 2 — create the native NetBird profile

1. Open **VPN → VPN Client**.
2. **Add** → **VPN Type: NetBird**.
3. Fill the protocol settings, including **Management URL** (default
   `https://netbird.ailton.dev.br`).
4. Click the TP-Link modal **SALVAR** first.
5. Confirm the profile appears in the stock VPN Client list.
6. Reopen **Edit** for that persisted NetBird profile.
7. Only now enter the **Setup Key** and choose **Enrollment**.

The setup key is staged in a temporary file for the enrollment operation and is
not persisted in the normal settings/profile store.

## Step 3 — enable and validate the peer

After enrollment, enable the NetBird profile through the normal TP-Link VPN
Client flow.

On the router, the link is considered UP only when all three conditions hold:

- `wt0` exists;
- NetBird reports `daemonStatus=Connected`;
- `management.connected=true`.

The normal lifecycle owner is:

```text
/etc/init.d/vpnc -> netifd -> proto=netbird -> shared runtime
```

`/etc/init.d/netbird` is only a compatibility/recovery wrapper and has no
`S99netbird` boot link in the final native image.

## Step 4 (optional) — make the AX53 a routing peer

In the NetBird profile, enable **Permitir roteamento da LAN** and set the exact
local CIDR, for example:

```text
192.168.10.0/24
```

When local LAN routing is enabled, **Rotas de servidor** must also be enabled.
The UI forces this state and both backend/runtime reject the contradictory
combination `advertise_lan=1 + disable_server_routes=1`.

This local option does **not** create a NetBird Network/Resource in the control
plane. In NetBird Management you still need to create/confirm the corresponding
Network/Resource/Policy and select the AX53 as the routing peer. The router does
not receive administrative credentials to create control-plane resources.

The local CIDR is used to scope forwarding/NAT. Runtime firewall bookkeeping is
stored only in:

```text
/tmp/netbird-firewall.state
```

It records the actually applied port/access/CIDR/home interface so changing
CIDR or WireGuard port can remove the old rules deterministically before adding
the new ones. This bookkeeping is ephemeral and is not written to NAND.

## Post-flash validation

Use the repository validator after copying it temporarily to the router:

```sh
NB_PEER_IP=<overlay-peer> \
LAN_TARGET_IP=<lan-host> \
sh /tmp/validate-netbird-native-router.sh
```

Also inspect:

```sh
uci show vpn.client
uci show network.vpn
ubus call network.interface.vpn status
/sbin/netbird-ctl status
/sbin/netbird-ctl payload-status
/sbin/netbird-ctl settings
ip addr show wt0
cat /tmp/netbird-firewall.state
iptables -S FORWARD | grep -E 'wt0|NETBIRD'
iptables -t nat -S POSTROUTING | grep -E 'wt0|100\.64\.'
```

The router-local validator can prove router → peer and router → LAN, but it
**cannot prove the opposite traffic direction**. From a real remote NetBird
peer, separately test:

1. remote peer → AX53 NetBird IP;
2. remote peer → a LAN host through the AX53;
3. Proxmox/VMs/local Coolify as applicable;
4. DNS through the intended non-WG-Easy path.

For firewall mutation, explicitly test at least once:

```text
CIDR A -> CIDR B
routing ON -> OFF
WireGuard port X -> Y
```

and confirm rules for A/X are absent after the transition.

## Payload/runtime checks

```sh
/sbin/netbird-ctl payload-status
/sbin/netbird-ctl status
/sbin/netbird-ctl log 50
```

Payload states are:

- `READY`
- `PAYLOAD_NOT_DOWNLOADED`
- `PAYLOAD_DOWNLOAD_FAILED`
- `PAYLOAD_INVALID`

Failure to materialize NetBird is fail-closed for the NetBird feature and must
not take down WAN, Wi-Fi, DHCP or the fallback VPN.

## Stop conditions

Do **not** remove WG-Easy and do not proceed with migration if any of these are
true:

- `make test-netbird` fails;
- build pre-repack validation fails;
- `vpn.client.vpntype != netbirdvpn` for the active NetBird profile;
- `network.vpn.proto != netbird`;
- more than one lifecycle owner starts NetBird;
- `network.interface.vpn` is UP without `wt0` and management connectivity;
- LAN routing is enabled with server routes disabled;
- `/tmp/netbird-firewall.state` disagrees with the active configuration;
- old CIDR/port rules remain after a settings transition;
- remote peer → AX53 or remote peer → LAN validation fails;
- DNS still depends on the historical `10.8.0.1` WG-Easy path.
