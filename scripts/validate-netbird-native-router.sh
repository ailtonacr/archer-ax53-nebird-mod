#!/bin/sh
# Read-only post-flash validation for the Archer AX53 native NetBird VPN Client.
# Run on the router after creating/enrolling/enabling the NetBird profile.
#
# Optional environment variables:
#   NB_PEER_IP      - NetBird overlay peer to ping from the router
#   LAN_TARGET_IP   - LAN host to ping from the router
#
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
HOME_IF="$(uci_get_state firewall core lan_ifname 2>/dev/null)"
[ -n "$HOME_IF" ] || HOME_IF="br-lan"
if [ "$ADVERTISE_LAN" = "1" ]; then
    [ -n "$ADVERTISE_CIDR" ] && ok "LAN routing CIDR configured: $ADVERTISE_CIDR" || fail "advertise_lan=1 without advertise_cidr"
    if [ -n "$ADVERTISE_CIDR" ]; then
        iptables -S FORWARD 2>/dev/null | grep -F -- "-i wt0 -o $HOME_IF -d $ADVERTISE_CIDR -j ACCEPT" >/dev/null \
            && ok "priority wt0 -> LAN rule present" || fail "missing priority wt0 -> LAN rule"
        iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-o $HOME_IF -s 100.64.0.0/10 -d $ADVERTISE_CIDR -j MASQUERADE" >/dev/null \
            && ok "overlay -> LAN scoped MASQUERADE present" || fail "missing scoped overlay -> LAN MASQUERADE"
    fi
else
    ok "LAN advertisement disabled; routed-LAN firewall checks skipped"
fi

if [ -n "${NB_PEER_IP:-}" ]; then
    ping -c 3 -W 2 "$NB_PEER_IP" >/dev/null 2>&1 && ok "overlay peer reachable: $NB_PEER_IP" || fail "overlay peer unreachable: $NB_PEER_IP"
else
    warn "NB_PEER_IP not supplied; overlay peer ping not executed"
fi

if [ -n "${LAN_TARGET_IP:-}" ]; then
    ping -c 3 -W 2 "$LAN_TARGET_IP" >/dev/null 2>&1 && ok "LAN target reachable from router: $LAN_TARGET_IP" || fail "LAN target unreachable from router: $LAN_TARGET_IP"
else
    warn "LAN_TARGET_IP not supplied; router-to-LAN ping not executed"
fi

echo
echo "SUMMARY pass=$PASS fail=$FAIL warn=$WARN"
[ "$FAIL" -eq 0 ]
