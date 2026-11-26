# AX53 gateway failover — stage 1 (not qualified for deployment)
Base: feat/managed-switch-router-on-a-stick. No NetBird, new NAND partitions, CI or tags.
## Implemented
- POSIX policy state machine, hysteresis, disabled/observe/auto policies, status CLI.
- Atomic transition intent journal with sync before and after hardware changes (power-loss behavior still needs physical testing), single writer lock, explicit board adapter
  gate. Auto refuses unqualified adapters; stock default remains unchanged.
- Observer service is packaged but not linked at boot. Only observe can start
  via init. No hardware writes from the included adapter.
- Shared nonblocking custom switch/failover lock, strict non-executable config parsing, switch intent marker, bounded adapter calls and monotonic sample windows. Vendor boot/hotplug remains an outstanding integration gate.\n- Local/offline shell tests with mock adapter, including manual return only after stable recovery and verified fallback. Initial auto operation requires verified primary layout. No hardware qualification implied. A stale lock or interrupted journal requires operator reconciliation; do not remove it blindly.
## Hardware gates before real transitions
1. Inspect installed build, vendor network UCI/state, actual bridge/VLAN table,
   DHCP and IPv6 RA processes, NAT/firewall and WAN address; secure physical
   recovery and back up configurations. The stock template is not live state.
2. Implement adapter with preflight, probe-primary, takeover, verify-takeover,
   return, verify-return. All commands bounded; preflight checks supported
   build, approved topology, safe recovery, non-overlapping DHCP pools and
   independent recovery/monitoring path. Probe returns healthy, down,
   upstream-down or unknown (never derive down solely from internet ping).
3. Fence primary WAN/LAN and verify hardware membership before assuming gateway
   172.24.0.1. Existing rollback reconnects LAN1 untagged and is NOT fencing.
   Preserve management 172.24.0.2 if supported, verify NAT/firewall and DHCP/DNS
   from client; handle IPv6 or disable it safely in fallback.
4. Reconcile vendor S19switch, S25network, S46iptv, 65-iptv, S99managed-switch
   and networkx so no reboot/hotplug reopens primary or starts competing DHCP.
   Do not enable auto boot before this work. Establish isolated control VLAN
   with OpenWrt and recovery probe; prove actual forwarding before failback.
5. Manual failover/failback with access on LAN2–4; tests for VM/host outage,
   upstream-only outage, lease/ARP renewal, partial failures and power loss.
   An interrupted journal blocks automation: inspect fencing, actual gateway
   and services first; no blind deletion or retry. Add a verified reconciliation
   command and stock UI before enabling auto service.
6. Only after qualification: enable auto mode explicitly, initially manual
   failback; opt in automatic failback after repeated physical tests.
## Local test
Run make test-firmware. The test mocks the adapter; it does not touch switch,
UCI, firewall or physical hardware. Factory config mode=disabled.

## Stage 2 — ordered adapter and mode policy (not hardware qualified)
- board-adapter dispatches an ordered takeover/return transaction from transition.sh. No qualified-platform is shipped. The reference layout.sh generates the primary, fenced and fallback membership masks for the documented AX53 LAN1 topology; control VID is an explicit input, not a production allocation.
- Platform preflight must validate exact firmware, hardware readback, vendor writers, recovery network and DHCP reservations. Each step must be synchronous and check its physical postcondition. Fencing is checked before WAN access, firewall/gateway claim and after takeover. Return requires isolated primary health, stops DHCP/DNS/routing and releases address/WAN before reconnecting primary. No blind rollback after failure.
- Platform commands: preflight, primary-layout, local-services-off, fence-primary, verify-fenced, enable-local-wan, prepare-firewall, claim-gateway, start-routing, start-dns-dhcp, verify-local-gateway, primary-ready-isolated, stop-dns-dhcp, stop-routing, release-gateway, disable-local-wan, reconnect-primary, probe-primary. The first-party platform must be implemented against observed vendor runtime; do not replace with an unconditional success script. The driver masks alone do not prove filtering or PVID behavior.
- UI exposes stock L2 restore, managed L2 apply and a disabled auto option. Observe/disabled policy can be saved through the existing stock API; the observer is not started automatically by the UI and must be started explicitly. No automatic mode can be enabled through this API.
- Read-only diagnostics: board-adapter diagnostics. Local tests: scripts/test-gateway-transition.sh (mock platform, failure injection, fixed mask fixtures). Hardware testing and service implementation remain mandatory.

### RTL8367S candidate implementation
rtl8367s.sh defines the exact in-place VLAN membership and PVID changes for fence, local WAN enable/disable and reconnect; no VLAN reset. The platform must supply rtl_write and rtl_verify, establish the control VLAN before fencing, verify ingress filtering/PVID semantics and hardware readback, and serialize all vendor writers. This is not a qualified implementation of those callbacks. The stock boot/hotplug paths remain unchanged: auto must remain unavailable until integrated and tested. The L3 vendor implementation and reserved pool/WAN/control subnet are deliberately not guessed. The first real platform must prove no competing IPv4 gateway, DHCP or IPv6 advertisements, and preserve access via LAN2–4.

Before a stock restore, disable observation explicitly. Invalid or automatic policy blocks custom switch mutations. The control VLAN must enforce tagged-only ingress and authenticated/isolated probes; the candidate PVID alone cannot guarantee this.
