# R2 Runtime — NetBird payload over HTTPS (architecture)

This document describes the **current** NetBird runtime on the Archer AX53 V1:
the binary is fetched over HTTPS from a public Cloudflare R2 bucket instead of
being read from a `netbird_data` MTD/UBI partition. The earlier
MIBIB/netbird_data approach is abandoned and kept only as
history/experiment (`mibib/`, `netbird-data/`).

## Why

The AX53's boot partitions turned out to be write-protected in a way that made
a reliable MIBIB flash impractical (the vendor write path is `nvrammanager`,
not plain `mtd`/`dd`; see `docs/MIBIB-WRITE-INVESTIGATION.md` if present). The
R2 runtime removes every flash-write dependency: stock MIBIB is left untouched,
no `netbird_data` partition, no UBI, no `ubiformat`/`ubiattach`, no
provisioner.

## Public payload

| Field | Value |
|---|---|
| Bucket | `ax53-netbird` (Cloudflare R2) |
| Object | `netbird/0.77.1/linux-armv6/netbird-dict8.xz` |
| Public URL | `https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/netbird-dict8.xz` |
| Compressed size / SHA-256 | 9,455,188 B / `4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941` |
| Decoded ELF size / SHA-256 | 39,125,176 B / `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6` |
| Version | `0.77.1` (linux-armv6) |
| Cache | `public, max-age=31536000, immutable` (object is immutable by version path) |

Served by the `netbird-dl` Worker (R2 binding `NB_BUCKET` → `ax53-netbird`) on a
`workers.dev` subdomain — no DNS/custom-domain changes required.

## Runtime flow (`/lib/netbird/netbird.sh`, `nb_materialize`)

```
start / UI start / enroll (force=1)
   │
   ├─ fast path: /tmp/netbird exists and SHA-256 == pinned  → READY
   │
   ├─ cooldown: automatic retries throttled to 1/300s; force bypasses it
   │
   ├─ Pass 1: curl (TLS, --cacert device bundle) | sha256sum
   │          → verify PINNED compressed SHA-256 (no file stored)
   │
   ├─ Pass 2: curl | /sbin/xzmini > /tmp/netbird.new   (streaming, 32 KiB bufs)
   │          → XZ stream CRC64 also verified by liblzma
   │
   ├─ verify decoded ELF: size 39125176 and SHA-256 == pinned
   │
   ├─ chmod 0755 + atomic rename → /tmp/netbird
   └─ READY (only ever executes a payload that passed every check)
```

### Fail-closed behaviour
- Download failure (offline/TLS/404) → `PAYLOAD_DOWNLOAD_FAILED`; boot/UI/WAN/
  WiFi/WireGuard untouched; NetBird stays stopped.
- Compressed SHA mismatch, corrupt XZ, decoded size/SHA mismatch →
  `PAYLOAD_INVALID`; nothing is made executable.
- No payload configured → `PAYLOAD_NOT_DOWNLOADED`.
- `/tmp/netbird` present + valid → `READY`, no re-download.
- Cooldown: non-forced calls (status/payload-status polling) attempt a download
  at most once per 300 s; manual start/restart/enroll force a retry.

### States (`netbird-ctl payload-status`)
`READY` (0) · `PAYLOAD_NOT_DOWNLOADED` (1) · `PAYLOAD_DOWNLOAD_FAILED` (2) ·
`PAYLOAD_INVALID` (3). The LuCI backend/UI surface these names only — no MIBIB/
UBI vocabulary is shown to the user.

### Downloader
`/usr/bin/curl` with `--cacert /etc/ssl/certs/ca-certificates.crt` (verified:
`tls 0` on the device), `--connect-timeout 5 --max-time 30`. TLS verification is
never disabled; the pinned SHA-256s are the second layer.

## RAM / tmpfs analysis

`/tmp` on the AX53 is a RAM-backed tmpfs (`~96.7 MiB`). The two-phase approach
(stored 9.45 MiB XZ **and** 39.1 MiB ELF simultaneously) hit
`No space left on device` on the real device. The streaming runtime keeps the
peak at the single decoded ELF:

| Phase | tmpfs delta | free RAM delta (measured) |
|---|---|---|
| Pass 1 (curl \| sha256sum) | ~0 | negligible |
| Pass 2 (curl \| xzmini → new) | +39,125,176 B | ~ −40 MiB peak |
| Final (`/tmp/netbird`) | +39,125,176 B (persistent) | — |

Measured on device during materialization: `/tmp` 31.6 MiB → 69.8 MiB used
(< 96.7 MiB), free RAM 63.9 MiB → 23.7 MiB. The `~40 MiB` resident binary is the
unavoidable cost of running from tmpfs and was the design the user accepted;
the delta peak over idle is the single ELF, not ELF + XZ.

## Security

- HTTPS mandatory, TLS verified with the device CA bundle (`--cacert`).
- Compressed SHA-256 pinned in the firmware (never from remote metadata alone).
- Decoded ELF SHA-256 pinned in the firmware.
- Nothing is ever executed until both hashes and the size match.
- Staging file + atomic `rename`; the downloaded stream is never executed
  directly; no shell interpolation of the URL.
- Object is immutable (versioned path); Cache-Control immutable.

## Update path

Bumping the payload version = change `NB_VERSION`, `NB_PAYLOAD_URL`,
`NB_PAYLOAD_XZ_SHA256`, `NB_EXPECTED_SIZE`, `NB_EXPECTED_SHA256` in
`/lib/netbird/netbird.sh`, upload the new object to R2, rebuild the firmware.
The UI reads `payload.version` from the pinned constant.