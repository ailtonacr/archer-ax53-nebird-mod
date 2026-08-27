# NOTE: current runtime is the R2 runtime (payload downloaded over HTTPS, no netbird_data/MIBIB/UBI). This file documents the historical MIBIB/netbird_data architecture unless stated otherwise. See docs/R2-RUNTIME.md for the current architecture and INSTALL.md for the current install flow.
# NetBird on Archer AX53 V1 — Security

## Secrets handling

- **Setup key**: submitted once via the authenticated admin endpoint, written to a
  0600 temp file (`/tmp/nb-setup-key-*`), consumed by `netbird up
  --setup-key-file <file>` (never argv, never logs), and `unlink`ed immediately.
  It is never persisted, never returned by the API after submit, never written to
  the rootfs or NAND.
- **Identity** (`default.json`: WireGuard private key, SSH private key) and state
  live in `/tp_data/netbird` — directory 0700, files 0600.
- **Settings file** contains no secrets (only toggles/URL).
- **Logs** (`/tmp/netbird.log`) are sanitized for the UI (tail only), rotation
  capped by `NB_LOG_MAX_SIZE_MB=2`, tmpfs only (lost on reboot), never NAND.

## Authentication / authorization

- The backend controller is registered under the LuCI `admin` tree and inherits
  the stock `stok`/session authentication. No anonymous admin endpoint is added.
- Every mutable op (`settings_set`, `enroll`, `start`, `stop`, `restart`,
  `clean`) goes through the same authenticated dispatcher.

## Input validation (backend)

- Settings are validated by a whitelist with per-key rules: booleans,
  `https?://` URL, hostname `[A-Za-z0-9._-]{0,64}`, CIDR `a.b.c.d/0..32`,
  port 1..65535. Unknown keys are ignored. `enrolled` is read-only.
- Command execution uses `luci.util.shellquote` on every argv element (no shell
  string built from UI input). The setup key path is server-generated.
- Concurrency start/stop is naturally serialized by the LuCI dispatcher (max 3
  requests) plus the rc.common per-init flock; a single enroll temp file is used
  per request with a unique name.

## Firewall posture

- Default is `disable_firewall = 1` (NetBird does not manage iptables) and
  `disable_server_routes = 1` (peer only).
- Our own rules are minimal and explicit: UDP handshake port, `wt0` conntrack
  `ESTABLISHED,RELATED`, and FORWARD `wt0 <-> br-lan` **only** when routing-peer
  is enabled. No broad `-i wt0 -j ACCEPT`.
- NetBird's own firewall (when enabled) remains meaningful; no wide bypass or
  `zone_wan` conflict; conntrack/NAT and OpenVPN/WireGuard are preserved.

## Not in scope (documented, not implemented)

- No auto-update of the NetBird binary. Payload updates are manual + controlled
  via `/netbird_data/metadata`.
- No setup key persistence, no key export, no log persistence.
