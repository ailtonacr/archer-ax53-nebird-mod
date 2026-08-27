# NOTE: current runtime is the R2 runtime (payload downloaded over HTTPS, no netbird_data/MIBIB/UBI). This file documents the historical MIBIB/netbird_data architecture unless stated otherwise. See docs/R2-RUNTIME.md for the current architecture and INSTALL.md for the current install flow.
# NetBird on Archer AX53 V1 — Rollback

## A. Revert firmware only

Flash the **stock** firmware (or the previous working image) via the Web UI.
NetBird integration disappears; `netbird_data`, `/tp_data/netbird` and the
partition table are left alone (harmless). Wi-Fi/WAN unaffected.

## B. Revert the partition table (MIBIB)

Only needed if you want to remove the `netbird_data` partition:

```sh
mtd write /tmp/mibib-original.bin 0:MIBIB   # or the backup taken during provisioning
reboot
```

The original MIBIB (`mibib/mibib-original.bin`) has the stock 16 partitions.
`mibib-backup.bin` (taken by the provisioner) is bit-identical if the device was
stock before provisioning.

## C. Revert the payload partition

After reverting the MIBIB, `netbird_data` is no longer referenced. If desired,
erase it:

```sh
MTD="$(awk -F: '$4=="\"netbird_data\""{gsub("mtd","",$1); gsub(":","",$1); print $1}' /proc/mtd)"
ubiformat "/dev/mtd${MTD}" -y
```

## D. Clear NetBird configuration only

Without touching firmware/partition/payload:

```sh
/etc/init.d/netbird stop
rm -rf /tp_data/netbird
```

NetBird reappears in VPN Client as "Enrollment required".

## Recovery mode

If the router is unresponsive: power off → hold **Reset** → power on until the
LED is amber → browse to `192.168.0.1` → upload a stock firmware.

## Brick-safety notes

- The MIBIB write is the only risky step. The provisioner backs up first.
- `rootfs` / `rootfs_1` / `tp_boot_idx` are **not** touched by the MIBIB edit
  (verified offline: geometry unchanged, only a 17th entry appended after `data`).
- The firmware repack reproduces the stock UBI geometry (kernel 17 PEBs +
  `ubi_rootfs` 282 PEBs) and the stock image size (39,457,554 B).
