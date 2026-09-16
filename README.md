# Archer AX53 — Managed Switch experiment

This branch is intentionally isolated from the NetBird work. It starts from the last pre-NetBird repository state and keeps only the development SSH mod plus the generic firmware unpack/apply/repack pipeline needed for switch work.

## Scope

- TP-Link Archer AX53 stock firmware as base.
- Development SSH (`mods/011-devssh.sh`).
- Managed-switch tooling (`mods/020-managed-switch.sh`).
- Existing stock RTL8367S/switch implementation is reused; it is not replaced.
- No NetBird, WireGuard integration, R2 runtime, VPN UI patching, telnet mod, iperf mod, GitHub Actions, workflows or tags.

## Safety model

Managed switching is **disabled by default**. The firmware installs inspection/validation tooling but does not automatically rewrite VLANs at boot. Before the first apply on hardware, validate the live logical/physical port mapping and preserve a local recovery path.

`managed-switch apply` requires both `managed_switch.main.enabled=1` and the explicit environment confirmation `MANAGED_SWITCH_CONFIRM=YES`.

## Commands

```sh
make test-firmware
make firmware STOCK=stock_decrypted.bin
```

On the router:

```sh
managed-switch status
managed-switch plan
managed-switch validate
```

Only after live mapping/recovery validation:

```sh
MANAGED_SWITCH_CONFIRM=YES managed-switch apply
```

Runtime rollback, while the backup still exists:

```sh
managed-switch rollback
```

## Target architecture under investigation

The intended use is a VLAN-aware AX53 switch/AP capable of carrying a tagged WAN/LAN trunk to a one-NIC Proxmox host while keeping other physical ports as LAN access ports. Exact VLAN IDs and port tokens are deliberately not baked into the initial firmware because the hardware mapping must be confirmed on the real AX53 first.
