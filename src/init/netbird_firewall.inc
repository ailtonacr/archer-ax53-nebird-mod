# NetBird v4 CIDR-scoped/applied-state firewall integration.
#
# Appended to /lib/firewall/tpcmd.sh by mods/010-netbird.sh. Optional explicit
# cidr/homeif arguments are used by netbird-runtime.sh to remove the exact rules
# that were previously applied even after settings change from A -> B.
#
# NetBird v0.77.1 owns route authorization through NETBIRD-RT-FWD-* chains. The
# scoped TP-Link FORWARD rules below are deliberately APPENDED (no position 1)
# so they cannot bypass NetBird Route ACL ACCEPT/DROP decisions. Routing-peer
# mode requires the NetBird firewall to stay enabled; see netbird-runtime.sh.
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
    if [ $# -lt 3 ]; then
        cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"
    fi

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
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }

    if [ "$access" == "lan" ] && [ -n "$cidr" ]; then
        # Idempotent replacement for the currently requested scope. Do not pass
        # a numeric position: fw_s_add without pos appends after NetBird's own
        # FORWARD jumps and therefore preserves Route ACL enforcement.
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
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
    if [ $# -lt 3 ]; then
        cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"
    fi

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    if [ -n "$cidr" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi

    # Also clean historical broad rules from pre-CIDR builds.
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
}
