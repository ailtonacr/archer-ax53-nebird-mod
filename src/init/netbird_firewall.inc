# NetBird v4 CIDR-scoped/applied-state firewall integration.
#
# Appended to /lib/firewall/tpcmd.sh by mods/010-netbird.sh. Optional explicit
# cidr/homeif arguments are used by netbird-runtime.sh to remove the exact rules
# that were previously applied even after settings change from A -> B.
#
# NetBird owns route authorization. On AX53 that authorization is forced into
# the userspace firewall/router because the QSDK kernel cannot apply ipset-backed
# Route ACLs reliably. The scoped TP-Link FORWARD rules below are deliberately
# APPENDED (no position 1): they provide only kernel interface plumbing and must
# never become a broad policy bypass. Gateway mode requires the NetBird firewall
# to stay enabled; see netbird-runtime.sh.
#
# No broad "-i wt0 -j ACCEPT" is installed. The WireGuard/ICE handshake port is
# opened on INPUT; routing-peer forwarding remains opt-in and CIDR-scoped.

fw_netbird_access(){
    local port=$1
    local access=$2
    local cidr="$3"
    local homeif="$4"
    [ -n "$homeif" ] || homeif="$(uci_get_state firewall core lan_ifname)"
    [ -n "$homeif" ] || homeif="br-lan"
    # WireGuard/ICE handshake port (inbound transport).
    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }

    # Return traffic into the router/tunnel only. New inbound peer access to the
    # AX53 itself remains governed by NetBird/stock INPUT policy until hardware
    # evidence justifies a narrower explicit local-management rule.
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    # Remove broad rules from historical builds before installing scoped rules.
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 f forwarding_lan ACCEPT { "-i $homeif -o wt0" }
    [ -n "$cidr" ] && fw_s_del 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }

    if [ "$access" == "lan" ] && [ -n "$cidr" ]; then
        # Idempotent replacement for the currently requested scope. Do not pass
        # a numeric position: fw_s_add without pos avoids turning local kernel
        # plumbing into a priority policy bypass.
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 f forwarding_lan ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        # The stock LAN zone ends in DROP. Put clientless LAN -> wt0 in the
        # LAN custom chain, which runs before zone_lan_DROP, instead of appending
        # to top-level FORWARD where the packet would never reach the rule.
        fw_s_add 4 f forwarding_lan ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        # Clientless LAN hosts use the AX53 as their NetBird gateway. NetBird's
        # userspace firewall/router remains the policy authority; this SNAT runs
        # only in POSTROUTING so remote peers/resources see the AX53 overlay
        # identity after the local forwarding decision.
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local cidr="$3"
    local homeif="$4"
    [ -n "$homeif" ] || homeif="$(uci_get_state firewall core lan_ifname)"
    [ -n "$homeif" ] || homeif="br-lan"
    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    if [ -n "$cidr" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 f forwarding_lan ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi

    # Also clean historical broad rules from pre-CIDR builds.
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 f forwarding_lan ACCEPT { "-i $homeif -o wt0" }
    [ -n "$cidr" ] && fw_s_del 4 n POSTROUTING MASQUERADE { "-o wt0 -s $cidr" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
}
