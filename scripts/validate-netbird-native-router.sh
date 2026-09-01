#!/bin/sh
# Read-only post-flash validation for the Archer AX53 native NetBird VPN Client.
# Run on the router after creating/enrolling/enabling the NetBird profile.
#
# Optional environment variables:
#   NB_PEER_IP      - NetBird overlay peer to ping from the router
#   LAN_TARGET_IP   - LAN host to ping from the router
#
# IMPORTANT: router-originated pings do NOT prove remote peer -> AX53/LAN.
# That direction must still be tested from an actual remote NetBird peer.
# No secret is read or printed by this script.

PASS=0
FAIL=0
WARN=0

ok()   { echo "PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
warn() { echo "WARN  $*"; WARN=$((WARN + 1)); }

expect_eq() {
    label="$1" got="$2" want="$3"
    [ "$got" = "$want" ] && ok "$label = $want" || fail "$label: got '$got', expected '$want'"
}

PROFILE_COUNT="$(uci show vpn 2>/dev/null | grep -c "\.type='netbirdvpn'$" || true)"
[ "$PROFILE_COUNT" -eq 1 ] && ok "exactly one vpn/server NetBird profile" || fail "NetBird profile count = $PROFILE_COUNT (expected 1)"

VPN_ENABLED="$(uci -q get vpn.client.enabled)"
VPN_TYPE="$(uci -q get vpn.client.vpntype)"
NETWORK_PROTO="$(uci -q get network.vpn.proto)"
expect_eq "vpn.client.enabled" "$VPN_ENABLED" "on"
expect_eq "vpn.client.vpntype" "$VPN_TYPE" "netbirdvpn"
expect_eq "network.vpn.proto" "$NETWORK_PROTO" "netbird"

[ ! -e /etc/rc.d/S99netbird ] && ok "standalone S99netbird autostart absent" || fail "S99netbird still exists"
[ -f /lib/netbird/netbird-runtime.sh ] && ok "shared native runtime installed" || fail "missing /lib/netbird/netbird-runtime.sh"
[ -f /lib/netifd/proto/netbird.sh ] && ok "netifd NetBird protocol installed" || fail "missing /lib/netifd/proto/netbird.sh"
if [ -f /lib/netifd/proto/netbird.sh ]; then
    grep -q 'nb_runtime_connect' /lib/netifd/proto/netbird.sh && ok "netifd calls shared runtime" || fail "netifd does not call shared runtime"
    if grep -q '/sbin/netbird-ctl' /lib/netifd/proto/netbird.sh; then
        fail "netifd still depends on netbird-ctl"
    else
        ok "netifd has no netbird-ctl lifecycle dependency"
    fi
    SETUP_BLOCK="$(sed -n '/^proto_netbird_setup()/,/^proto_netbird_teardown()/p' /lib/netifd/proto/netbird.sh)"
    [ "$(printf '%s\n' "$SETUP_BLOCK" | grep -c 'nb_runtime_stop')" -ge 2 ] \
        && ok "netifd setup rolls back immediate failure and timeout" \
        || fail "netifd setup rollback paths are incomplete"
fi

PAYLOAD_STATE="$(/sbin/netbird-ctl payload-status 2>/dev/null || true)"
expect_eq "NetBird payload" "$PAYLOAD_STATE" "READY"

[ -S /tmp/netbird.sock ] && ok "daemon socket exists" || fail "missing /tmp/netbird.sock"
[ -d /sys/class/net/wt0 ] && ok "wt0 exists" || fail "wt0 missing"

PROC_COUNT="$(ps 2>/dev/null | grep '[n]etbird service run' | wc -l | tr -d ' ')"
[ "$PROC_COUNT" -eq 1 ] && ok "exactly one NetBird service process" || fail "NetBird service process count = $PROC_COUNT (expected 1)"

STATUS="$(/sbin/netbird-ctl status 2>/dev/null || true)"
COMPACT="$(printf '%s' "$STATUS" | tr -d '\r\n\t ')"
printf '%s' "$COMPACT" | grep -q '"daemonStatus":"Connected"' && ok "daemonStatus Connected" || fail "daemonStatus is not Connected"
MANAGEMENT="$(printf '%s' "$COMPACT" | sed -n 's/.*"management":{\([^}]*\)}.*/\1/p')"
if [ -n "$MANAGEMENT" ] && printf '%s' "$MANAGEMENT" | grep -q '"connected":true'; then
    ok "management.connected = true"
else
    fail "management.connected is not true"
fi
NETBIRD_IP="$(printf '%s' "$COMPACT" | sed -n 's/.*"netbirdIp":"\([^"]*\)".*/\1/p')"
[ -n "$NETBIRD_IP" ] && ok "NetBird IP assigned: $NETBIRD_IP" || fail "NetBird IP missing from status"

UBUS="$(ubus call network.interface.vpn status 2>/dev/null || true)"
printf '%s' "$UBUS" | tr -d '\r\n\t ' | grep -q '"up":true' && ok "network.interface.vpn up=true" || fail "network.interface.vpn is not up"
printf '%s' "$UBUS" | grep -q 'wt0' && ok "network.interface.vpn references wt0" || warn "ubus status does not explicitly contain wt0"

ADVERTISE_LAN="$(sed -n 's/^advertise_lan=//p' /tp_data/netbird/settings 2>/dev/null | head -n1)"
ADVERTISE_CIDR="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n1)"
DISABLE_SERVER_ROUTES="$(sed -n 's/^disable_server_routes=//p' /tp_data/netbird/settings 2>/dev/null | head -n1)"
DISABLE_FIREWALL="$(sed -n 's/^disable_firewall=//p' /tp_data/netbird/settings 2>/dev/null | head -n1)"
WG_PORT="$(sed -n 's/^wireguard_port=//p' /tp_data/netbird/settings 2>/dev/null | head -n1)"
HOME_IF="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
[ -n "$HOME_IF" ] || HOME_IF="br-lan"

FW_STATE="/tmp/netbird-firewall.state"
if [ -f "$FW_STATE" ]; then
    APPLIED_PORT="$(sed -n 's/^port=//p' "$FW_STATE" | head -n1)"
    APPLIED_ACCESS="$(sed -n 's/^access=//p' "$FW_STATE" | head -n1)"
    APPLIED_CIDR="$(sed -n 's/^cidr=//p' "$FW_STATE" | head -n1)"
    APPLIED_HOMEIF="$(sed -n 's/^homeif=//p' "$FW_STATE" | head -n1)"
    expect_eq "applied firewall port" "$APPLIED_PORT" "$WG_PORT"
    expect_eq "applied firewall interface" "$APPLIED_HOMEIF" "$HOME_IF"
else
    fail "missing /tmp/netbird-firewall.state while NetBird is active"
fi

if [ "$ADVERTISE_LAN" = "1" ]; then
    expect_eq "disable_server_routes for routing peer" "$DISABLE_SERVER_ROUTES" "0"
    expect_eq "disable_firewall for Route ACL enforcement" "$DISABLE_FIREWALL" "0"
    [ -n "$ADVERTISE_CIDR" ] && ok "LAN routing CIDR configured: $ADVERTISE_CIDR" || fail "advertise_lan=1 without advertise_cidr"
    if [ -f "$FW_STATE" ]; then
        expect_eq "applied firewall mode" "$APPLIED_ACCESS" "lan"
        expect_eq "applied firewall CIDR" "$APPLIED_CIDR" "$ADVERTISE_CIDR"
    fi

    # NetBird v0.77.1 owns inbound routed authorization. Its jump must be the
    # first wt0-specific FORWARD decision; an earlier ACCEPT would bypass Route ACLs.
    FORWARD_RULES="$(iptables -S FORWARD 2>/dev/null || true)"
    FIRST_WT0="$(printf '%s\n' "$FORWARD_RULES" | grep -- '-i wt0' | head -n1)"
    if printf '%s' "$FIRST_WT0" | grep -Fq -- '-j NETBIRD-RT-FWD-IN'; then
        ok "NetBird Route ACL jump precedes local wt0 FORWARD rules"
    else
        fail "first wt0 FORWARD rule is not NETBIRD-RT-FWD-IN: ${FIRST_WT0:-<none>}"
    fi
    iptables -S NETBIRD-RT-FWD-IN >/dev/null 2>&1 \
        && ok "NETBIRD-RT-FWD-IN chain exists" \
        || fail "NETBIRD-RT-FWD-IN chain missing while LAN routing is enabled"

    if [ -n "$ADVERTISE_CIDR" ]; then
        printf '%s\n' "$FORWARD_RULES" | grep -F -- "-i wt0 -o $HOME_IF -d $ADVERTISE_CIDR -j ACCEPT" >/dev/null \
            && ok "scoped wt0 -> LAN integration rule present" || fail "missing scoped wt0 -> LAN integration rule"
        iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-o $HOME_IF -s 100.64.0.0/10 -d $ADVERTISE_CIDR -j MASQUERADE" >/dev/null \
            && ok "overlay -> LAN scoped MASQUERADE present" || fail "missing scoped overlay -> LAN MASQUERADE"
    fi
else
    if [ -f "$FW_STATE" ]; then
        expect_eq "applied firewall mode" "$APPLIED_ACCESS" "home"
    fi
    ok "LAN routing disabled; routed-LAN firewall checks skipped"
fi

if [ -n "${NB_PEER_IP:-}" ]; then
    ping -c 3 -W 2 "$NB_PEER_IP" >/dev/null 2>&1 && ok "overlay peer reachable from router: $NB_PEER_IP" || fail "overlay peer unreachable from router: $NB_PEER_IP"
else
    warn "NB_PEER_IP not supplied; router-to-overlay peer ping not executed"
fi

if [ -n "${LAN_TARGET_IP:-}" ]; then
    ping -c 3 -W 2 "$LAN_TARGET_IP" >/dev/null 2>&1 && ok "LAN target reachable from router: $LAN_TARGET_IP" || fail "LAN target unreachable from router: $LAN_TARGET_IP"
else
    warn "LAN_TARGET_IP not supplied; router-to-LAN ping not executed"
fi

warn "external acceptance still required: from a remote NetBird peer, test the AX53 overlay IP and a LAN target through the AX53; this router-local script cannot prove that traffic direction"

echo
echo "SUMMARY pass=$PASS fail=$FAIL warn=$WARN"
[ "$FAIL" -eq 0 ]
