# Reference RTL8367S VLAN membership plans, fixed stock VIDs and LAN1.
# control_vid is deliberately supplied by a qualified platform, not assigned
# here: the VLAN must be reserved on the AX53, Proxmox and OpenWrt.
# Format: VID membership-mask untagged-mask. CPU16 is always tagged.
gf_layout() {
    local mode="$1" control="$2"
    case "$control" in ''|0*|*[!0-9]*) return 1;; esac
    [ "${#control}" -le 4 ] && [ "$control" -ge 1 ] && [ "$control" -le 4094 ] || return 1
    [ "$control" != 2 ] && [ "$control" != 4094 ] || return 1
    case "$mode" in
        primary)
            printf '%s\n' '4094 3 1' '2 65566 28';;
        fenced)
            # WAN disconnected from CPU and trunk; LAN1 isolated from LAN.
            printf '%s\n' '4094 1 1' '2 65564 28';;
        fallback)
            # WAN joins CPU; LAN1 remains excluded from both production VLANs.
            printf '%s\n' '4094 65537 1' '2 65564 28';;
        *) return 1;;
    esac
    printf '%s 65538 0\n' "$control"
}
