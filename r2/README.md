# R2 payload manifest (current NetBird runtime)

- Bucket: `ax53-netbird` (Cloudflare R2, public)
- Worker: `netbird-dl` (binding `NB_BUCKET` -> `ax53-netbird`)
- Public URL (root): https://netbird-dl.ailtonrodrigues1324.workers.dev/
- Object: `netbird/0.77.1/linux-armv6/netbird-dict8.xz`
- URL: https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/netbird-dict8.xz
- Content-Type: application/x-xz
- Cache-Control: public, max-age=31536000, immutable
- metadata.json: https://netbird-dl.ailtonrodrigues1324.workers.dev/netbird/0.77.1/linux-armv6/metadata.json

Pinned in `lib/netbird/netbird.sh`: compressed sha256
`4b0648305e5f4126fa58be391e5db995447a58d867d5d290a15b2df972c58941`, decoded ELF
(0.77.1) sha256 `6cc347b741695e6664d4ba0ba7004e823a77ab0705a4de5ebe92b290623bb8e6`.
