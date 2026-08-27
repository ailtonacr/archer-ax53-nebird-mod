# NetBird on Archer AX53 V1 — Installation (R2 runtime)

**Stop point: nothing below is flashed automatically. Run each step yourself
after reviewing.**

## What you get

| Artifact | File | Size |
|---|---|---|
| Firmware (rootfs + NetBird integration) | `firmware/Archer-AX53-NetBird-r2.bin` | 39,457,554 B |

The NetBird binary is **not** embedded in the firmware and **not** stored on any
partition. At runtime it is downloaded over HTTPS from a public Cloudflare R2
bucket, hash-validated (compressed + decoded SHA-256 pinned), and materialized
into `/tmp` (`/tmp/netbird`). Identity and settings persist in `/tp_data/netbird`.

The historical MIBIB / `netbird_data` / UBI artifacts under `mibib/` and
`netbird-data/` are **NOT used by the current runtime** (see the
`NOT_USED_BY_CURRENT_RUNTIME.md` markers and `docs/R2-RUNTIME.md`).

## Step 0 — backup

Make a full NAND backup before any future flash (see
`tp-link-ax53-fw-hacks/README.md` "Taking full Partition backup").

## Step 1 — flash firmware (Web UI)

Upload `Archer-AX53-NetBird-r2.bin` via **Advanced → System Tools → Firmware
Upgrade**, or use recovery mode (hold Reset, 192.168.0.1). Reboot.

After boot the router runs the stock UI + NetBird integration. The payload is
downloaded on demand when NetBird is started; if the download fails (offline,
TLS, or hash mismatch) the boot/UI continue normally and NetBird stays stopped.
Wi-Fi/WAN/OpenVPN/WireGuard are unaffected.

No MIBIB modification and no `netbird_data` partition are required.

## Step 2 — enroll

1. Open **VPN → VPN Client**.
2. **Add** → **VPN Type: NetBird**.
3. Enter the **Management URL** (default `https://netbird.ailton.dev.br`).
4. Paste the **Setup Key** (never stored) → **Enroll**.
5. NetBird connects; status shows **Connected** with NetBird IP / peers.

## Step 3 (optional) — routing peer

In the NetBird client: enable **Advertise LAN (routing peer)** and set the CIDR
(e.g. `192.168.10.0/24`). Define the Network/Resource/Policy in the NetBird
dashboard; the local UI only controls the client behaviour.

## Verification

```sh
/etc/init.d/netbird status        # or netbird-ctl status
netbird-ctl payload-status        # 0 READY / 1 PAYLOAD_NOT_DOWNLOADED
                                  # 2 PAYLOAD_DOWNLOAD_FAILED / 3 PAYLOAD_INVALID
netbird-ctl settings
netbird-ctl log 50
```

The UI VPN Client page shows the payload state (READY /
PAYLOAD_NOT_DOWNLOADED / PAYLOAD_DOWNLOAD_FAILED / PAYLOAD_INVALID) without any
MIBIB/UBI concept.