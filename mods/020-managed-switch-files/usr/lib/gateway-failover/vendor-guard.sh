# Source-only policy. No configuration is executed. Default stock path stays intact.
# Called from vendor code with the vendor switch-set.lock already held for 65-iptv.
ax53_vendor_allowed() {
    local data="${GF_DATA_ROOT:-/tp_data}/gateway-failover"
    local mode journal
    if [ -f "$data/journal" ]; then
        journal=$(cat "$data/journal") || return 1
        [ "$journal" = stable:NORMAL ] || return 1
    fi
    if [ -f "$data/config" ]; then
        mode=$(sed -n 's/^mode=//p' "$data/config") || return 1
        case "$mode" in disabled|observe) ;; *) return 1;; esac
    fi
    return 0
}
