# RTL8367S candidate primitives. Call only under exclusive vendor/custom
# ownership, with the transition journal synced and a qualified readback.
# Callbacks rtl_write NODE ... and rtl_verify MODE CONTROL must be supplied
# by the board platform. No reset/init (would transiently erase fencing).
rtl_fence() {
    local control="$1"
    gf_layout fenced "$control" >/dev/null || return 1
    rtl_verify primary "$control" || return 1
    rtl_write vlan set 4094 1 1 || return 1
    rtl_write vlan set 2 65564 28 || return 1
    # Untagged traffic on LAN1 cannot join either production VLAN. The\n    # qualified platform must separately enforce tagged-only ingress on the\n    # control VLAN; do not assume the PVID itself is a filtering control.
    rtl_write port pvid set 1 "$control" 0 || return 1
    rtl_verify fenced "$control"
}
rtl_enable_local_wan() {
    local control="$1"
    gf_layout fallback "$control" >/dev/null || return 1
    rtl_verify fenced "$control" || return 1
    rtl_write vlan set 4094 65537 1 || return 1
    rtl_verify fallback "$control"
}
rtl_disable_local_wan() {
    local control="$1"
    gf_layout fenced "$control" >/dev/null || return 1
    rtl_verify fallback "$control" || return 1
    rtl_write vlan set 4094 1 1 || return 1
    rtl_verify fenced "$control"
}
rtl_reconnect() {
    local control="$1"
    gf_layout primary "$control" >/dev/null || return 1
    rtl_verify fenced "$control" || return 1
    # Local services must already be off; the caller verifies that before
    # invoking this function. CPU stays excluded from WAN.
    rtl_write port pvid set 1 2 0 || return 1
    rtl_write vlan set 2 65566 28 || return 1
    rtl_write vlan set 4094 3 1 || return 1
    rtl_verify primary "$control"
}
