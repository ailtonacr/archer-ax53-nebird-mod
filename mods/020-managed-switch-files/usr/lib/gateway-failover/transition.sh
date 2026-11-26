# Ordered transaction contract. Platform owns actual hardware readback and L3.
# Every step is synchronous, idempotent and must return success only after
# checking its postcondition. Never reconnect production VLANs on failure.
gf_takeover() {
    platform primary-layout || return 1
    platform local-services-off || return 1
    platform fence-primary || return 1
    platform verify-fenced || return 1
    platform enable-local-wan || return 1
    platform verify-fenced || return 1
    platform prepare-firewall || return 1
    platform claim-gateway || return 1
    platform start-routing || return 1
    platform start-dns-dhcp || return 1
    gf_verify_takeover
}
gf_verify_takeover() {
    platform verify-fenced && platform verify-local-gateway
}
gf_return() {
    gf_verify_takeover || return 1
    platform primary-ready-isolated || return 1
    platform stop-dns-dhcp || return 1
    platform stop-routing || return 1
    platform release-gateway || return 1
    platform disable-local-wan || return 1
    platform local-services-off || return 1
    platform verify-fenced || return 1
    platform reconnect-primary || return 1
    gf_verify_return
}
gf_verify_return() {
    platform local-services-off && platform primary-layout
}
