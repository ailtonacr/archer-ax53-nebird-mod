# IPv4 fallback implementation. Only the qualified platform may call these.
# Stock DHCP/DNS/RA and WAN management must remain disabled; the board
# qualification checks that independently. No persistent vendor UCI changes.
GF_LAN=br-lan
GF_WAN=eth1.4094
GF_GW=172.24.0.1
GF_NET=172.24.0.0/24
GF_UPSTREAM=192.168.0.1
GF_TABLE=203
GF_RULE=10303
GF_RUN="${GF_RUN_ROOT:-/var/run}/ax53-fallback"
gf_ip() { ip "$@"; }
gf_ipt() { iptables "$@"; }

# Strict data-only profile; the disjoint fallback pool and WAN address must
# be reserved in the actual network before qualification.
gf_l3_load() {
    local f="$1" row
    [ -f "$f" ] || return 1
    row=$(awk -F= '
        function oct(s) {return s ~ /^(0|[1-9][0-9]?[0-9]?)$/ && s+0<=255}
        function ipv4(s, a,n,i) { n=split(s,a,"."); if(n!=4)return 0; for(i=1;i<=4;i++)if(!oct(a[i]))return 0; return 1 }
        function host(s,p, a) {split(s,a,"."); return ipv4(s) && index(s,p)==1 && a[4]>0 && a[4]<255}
        /^#/ || /^$/ {next}
        NF!=2 || $1 !~ /^(wan_ip|dhcp_start|dhcp_end|dns1|dns2)$/ || seen[$1]++ {bad=1; next}
        {v[$1]=$2}
        END {
            if(bad || !host(v["wan_ip"],"192.168.0.") || v["wan_ip"]=="192.168.0.1" || v["wan_ip"]=="192.168.0.3" ||
                !host(v["dhcp_start"],"172.24.0.") || !host(v["dhcp_end"],"172.24.0.") ||
                !ipv4(v["dns1"]) || !ipv4(v["dns2"]) || v["dns1"]==v["dns2"]) exit 1
            split(v["dhcp_start"],a,"."); split(v["dhcp_end"],b,".")
            if(a[4]<3 || a[4]>b[4] || (a[4]<=53 && b[4]>=53) || (a[4]<=200 && b[4]>=200))exit 1
            print v["wan_ip"],v["dhcp_start"],v["dhcp_end"],v["dns1"],v["dns2"]
        }' "$f") || return 1
    set -- $row
    [ "$#" -eq 5 ] || return 1
    GF_WAN_IP=$1 GF_POOL_START=$2 GF_POOL_END=$3 GF_DNS1=$4 GF_DNS2=$5
}
gf_has_addr() {
    gf_ip -4 addr show dev "$1" | awk -v addr="$2" '$1=="inet" && $2==addr {found=1} END{exit !found}'
}
gf_chain_present() { gf_ipt -t "$1" -S "$2" >/dev/null 2>&1; }
gf_hook_present() { gf_ipt -t "$1" -C "$2" -j "$3" >/dev/null 2>&1; }
gf_chain_create() {
    # Refuse an unexpected existing chain. Never flush unrelated rules.
    ! gf_chain_present "$1" "$2" || return 1
    gf_ipt -t "$1" -N "$2"
}
gf_l3_prepare_firewall() {
    # All mutating work follows fencing and durable intent. Forwarding is
    # still disabled. Chain creation is intentionally not blindly replayable.
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 0 ] || return 1
    gf_chain_create filter AX53GF_IN &&
    gf_chain_create filter AX53GF_FWD &&
    gf_chain_create nat AX53GF_NAT &&
    gf_ipt -A AX53GF_IN -i "$GF_WAN" -m state --state ESTABLISHED,RELATED -j ACCEPT &&
    gf_ipt -A AX53GF_IN -i "$GF_WAN" -j DROP &&
    gf_ipt -A AX53GF_IN -i "$GF_LAN" -d "$GF_GW" -p udp --dport 53 -j ACCEPT &&
    gf_ipt -A AX53GF_IN -i "$GF_LAN" -d "$GF_GW" -p tcp --dport 53 -j ACCEPT &&
    gf_ipt -A AX53GF_IN -i "$GF_LAN" -p udp --dport 67 -j ACCEPT &&
    gf_ipt -A AX53GF_IN -j RETURN &&
    gf_ipt -A AX53GF_FWD -i "$GF_LAN" -o "$GF_WAN" -s "$GF_NET" -j ACCEPT &&
    gf_ipt -A AX53GF_FWD -i "$GF_WAN" -o "$GF_LAN" -d "$GF_NET" -m state --state ESTABLISHED,RELATED -j ACCEPT &&
    gf_ipt -A AX53GF_FWD -j DROP &&
    gf_ipt -t nat -A AX53GF_NAT -s "$GF_NET" -o "$GF_WAN" -j MASQUERADE &&
    gf_ipt -I INPUT 1 -j AX53GF_IN &&
    gf_ipt -I FORWARD 1 -j AX53GF_FWD &&
    gf_ipt -t nat -I POSTROUTING 1 -j AX53GF_NAT
}
gf_l3_claim() {
    ! gf_has_addr "$GF_LAN" "$GF_GW/24" || return 1
    ! gf_has_addr "$GF_WAN" "$GF_WAN_IP/24" || return 1
    gf_ip link set "$GF_WAN" up &&
    gf_ip addr add "$GF_WAN_IP/24" dev "$GF_WAN" &&
    gf_ip addr add "$GF_GW/24" dev "$GF_LAN" &&
    gf_has_addr "$GF_LAN" "$GF_GW/24" && gf_has_addr "$GF_WAN" "$GF_WAN_IP/24"
}
gf_l3_start_routing() {
    # A dedicated table gives forwarded clients and locally sourced DNS a
    # fallback route without replacing the existing management default route.
    [ -z "$(gf_ip route show table "$GF_TABLE" 2>/dev/null)" ] || return 1
    ! gf_ip rule show | grep -Eq "^$GF_RULE:" || return 1
    gf_ip route add "$GF_NET" dev "$GF_LAN" scope link table "$GF_TABLE" &&
    gf_ip route add 192.168.0.0/24 dev "$GF_WAN" scope link table "$GF_TABLE" &&
    gf_ip route add default via "$GF_UPSTREAM" dev "$GF_WAN" table "$GF_TABLE" &&
    gf_ip rule add priority "$GF_RULE" from "$GF_NET" lookup "$GF_TABLE" &&
    gf_ip rule add priority "$((GF_RULE+1))" from "$GF_WAN_IP/32" lookup "$GF_TABLE" &&
    printf '1\n' > /proc/sys/net/ipv4/ip_forward
}
gf_l3_dns_running() {
    local pid
    [ -r "$GF_RUN/dnsmasq.pid" ] || return 1
    pid=$(cat "$GF_RUN/dnsmasq.pid") || return 1
    case "$pid" in ''|*[!0-9]*) return 1;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null &&
        [ -r "/proc/$pid/cmdline" ] &&
        tr '\000' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$GF_RUN/dnsmasq.conf"
}
gf_l3_start_dns() {
    ! gf_l3_dns_running || return 1
    mkdir -p "$GF_RUN" || return 1
    umask 077
    cat > "$GF_RUN/dnsmasq.conf" <<EOF
interface=$GF_LAN
listen-address=$GF_GW
bind-interfaces
no-resolv
no-hosts
domain-needed
bogus-priv
server=$GF_DNS1@$GF_WAN_IP
server=$GF_DNS2@$GF_WAN_IP
dhcp-range=$GF_POOL_START,$GF_POOL_END,255.255.255.0,5m
dhcp-option=3,$GF_GW
dhcp-option=6,$GF_GW
dhcp-leasefile=$GF_RUN/dhcp.leases
pid-file=$GF_RUN/dnsmasq.pid
EOF
    /usr/sbin/dnsmasq --test -C "$GF_RUN/dnsmasq.conf" &&
        /usr/sbin/dnsmasq -C "$GF_RUN/dnsmasq.conf" &&
        gf_l3_dns_running
}
gf_l3_stop_dns() {
    local pid n=0
    if [ -e "$GF_RUN/dnsmasq.pid" ]; then
        gf_l3_dns_running || return 1
        pid=$(cat "$GF_RUN/dnsmasq.pid") || return 1
        kill "$pid" || return 1
        while kill -0 "$pid" 2>/dev/null; do
            [ "$n" -lt 5 ] || return 1
            n=$((n+1)); sleep 1
        done
        rm -f "$GF_RUN/dnsmasq.pid"
    fi
    ! gf_l3_dns_running
}
gf_l3_stop_routing() {
    # Disable forwarding first. No stock restoration until all postconditions
    # have been independently verified.
    printf '0\n' > /proc/sys/net/ipv4/ip_forward &&
    gf_ip rule del priority "$GF_RULE" from "$GF_NET" lookup "$GF_TABLE" &&
    gf_ip rule del priority "$((GF_RULE+1))" from "$GF_WAN_IP/32" lookup "$GF_TABLE" &&
    gf_ip route flush table "$GF_TABLE"
}
gf_remove_chain() {
    local table="$1" parent="$2" chain="$3"
    gf_hook_present "$table" "$parent" "$chain" &&
    gf_ipt -t "$table" -D "$parent" -j "$chain" &&
    gf_ipt -t "$table" -F "$chain" &&
    gf_ipt -t "$table" -X "$chain"
}
gf_l3_release() {
    ! gf_l3_dns_running || return 1
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 0 ] || return 1
    gf_ip addr del "$GF_GW/24" dev "$GF_LAN" &&
    gf_ip addr del "$GF_WAN_IP/24" dev "$GF_WAN" &&
    gf_remove_chain nat POSTROUTING AX53GF_NAT &&
    gf_remove_chain filter FORWARD AX53GF_FWD &&
    gf_remove_chain filter INPUT AX53GF_IN
}
gf_l3_verify() {
    gf_has_addr "$GF_LAN" "$GF_GW/24" &&
    gf_has_addr "$GF_WAN" "$GF_WAN_IP/24" &&
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] &&
    gf_hook_present filter INPUT AX53GF_IN &&
    gf_hook_present filter FORWARD AX53GF_FWD &&
    gf_hook_present nat POSTROUTING AX53GF_NAT &&
    gf_ip route show table "$GF_TABLE" | grep -Fq "default via $GF_UPSTREAM dev $GF_WAN" &&
    gf_l3_dns_running
}
gf_l3_off() {
    ! gf_has_addr "$GF_LAN" "$GF_GW/24" &&
    ! gf_has_addr "$GF_WAN" "$GF_WAN_IP/24" &&
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 0 ] &&
    ! gf_l3_dns_running &&
    ! gf_chain_present filter AX53GF_IN &&
    ! gf_chain_present filter AX53GF_FWD &&
    ! gf_chain_present nat AX53GF_NAT
}
