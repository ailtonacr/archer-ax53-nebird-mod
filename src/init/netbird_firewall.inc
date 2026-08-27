# NetBird firewall integration (appended to /lib/firewall/tpcmd.sh).
# Minimal, explicit rules; no broad "-i wt0 -j ACCEPT". The WireGuard/ICE
# handshake port is opened on INPUT; wt0 return traffic uses conntrack.
# Routing-peer forwarding is opt-in and restricted to advertise_cidr.

fw_netbird_access(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    # WireGuard/ICE handshake port (inbound)
    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }

    # return traffic into the router over the tunnel interface (conntrack only)
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    # Remove the broad rules used by older builds before adding CIDR-scoped
    # forwarding. This makes an in-place upgrade fail closed rather than leave
    # stale unrestricted wt0 <-> LAN rules behind.
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }

    if [ "$access" == "lan" ] && [ -n "$cidr" ]; then
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i wt0 -o $homeif -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i $homeif -o wt0 -s $cidr" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    # Clean both current scoped rules and legacy broad rules.
    if [ -n "$cidr" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
}
