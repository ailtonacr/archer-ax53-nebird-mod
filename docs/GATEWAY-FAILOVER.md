# AX53 gateway failover — stage 1 (not qualified for deployment)
Base: feat/managed-switch-router-on-a-stick. No NetBird, new NAND partitions, CI or tags.
## Implemented
- POSIX policy state machine, hysteresis, disabled/observe/auto policies, status CLI.
- Atomic transition intent journal, single writer lock, explicit board adapter
  gate. Auto refuses unqualified adapters; stock default remains unchanged.
- Observer service is packaged but not linked at boot. Only observe can start
  via init. No hardware writes from the included adapter.
- Local/offline shell tests with mock adapter. No hardware qualification implied.
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
