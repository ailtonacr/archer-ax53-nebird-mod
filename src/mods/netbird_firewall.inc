# NetBird firewall integration (appended to /lib/firewall/tpcmd.sh).
# Minimal, explicit rules; no broad "-i wt0 -j ACCEPT". The WireGuard/ICE
# handshake port is opened on INPUT; wt0 return traffic uses conntrack.
# FORWARD (routing-peer) rules are only added when access == "lan".

fw_netbird_access(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"

    # WireGuard/ICE handshake port (inbound)
    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }

    # return traffic into the router over the tunnel interface (conntrack only)
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    # routing peer: forward between tunnel and LAN (enabled by advertise_lan)
    if [ "$access" == "lan" ]; then
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i wt0 -o $homeif" }
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i $homeif -o wt0" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    if [ "$access" == "lan" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
    fi
}
