#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB="$ROOT/mods/020-managed-switch-files/usr/lib/gateway-failover"
. "$LIB/transition.sh"
. "$LIB/layout.sh"
. "$LIB/rtl8367s.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
platform() {
    echo "$1" >> "$tmp/log"
    [ "$1" != "${FAIL_STEP:-}" ]
}
expect() {
    actual=$(cat "$tmp/log")
    [ "$actual" = "$1" ] || { echo "wrong transaction order" >&2; exit 1; }
}
takeover='primary-layout
local-services-off
fence-primary
verify-fenced
enable-local-wan
verify-fenced
prepare-firewall
claim-gateway
start-routing
start-dns-dhcp
verify-fenced
verify-local-gateway'
ret='verify-fenced
verify-local-gateway
primary-ready-isolated
stop-dns-dhcp
stop-routing
release-gateway
disable-local-wan
local-services-off
verify-fenced
reconnect-primary
local-services-off
primary-layout'
: > "$tmp/log"; gf_takeover; expect "$takeover"
: > "$tmp/log"; gf_return; expect "$ret"
# A failed phase must prevent subsequent phases, especially gateway claim
# and reconnection. Test every named failure in each direction.
for direction in takeover return; do
    case "$direction" in takeover) expected=$takeover;; return) expected=$ret;; esac
    for step in $expected; do
        : > "$tmp/log"
        FAIL_STEP=$step
        if "gf_$direction"; then echo "unexpected success: $step" >&2; exit 1; fi
        expected_prefix=$(printf '%s\n' "$expected" | awk -v step="$step" '{print} $0 == step {exit}')
        expect "$expected_prefix"
    done
done
unset FAIL_STEP
# VID 99 is only a test fixture, never a production allocation.
[ "$(gf_layout primary 99)" = "$(printf '%s\n' '4094 3 1' '2 65566 28' '99 65538 0')" ]
[ "$(gf_layout fenced 99)" = "$(printf '%s\n' '4094 1 1' '2 65564 28' '99 65538 0')" ]
[ "$(gf_layout fallback 99)" = "$(printf '%s\n' '4094 65537 1' '2 65564 28' '99 65538 0')" ]
for vid in 0 2 4094 4095 invalid 099; do
    if gf_layout primary "$vid"; then echo "invalid control VID accepted" >&2; exit 1; fi
done
# Shipped adapter must fail closed: no qualified-platform installed.
if GF_LIB_ROOT="$LIB" sh "$LIB/board-adapter" preflight; then
    echo "unqualified adapter accepted" >&2; exit 1
fi
# Exercise concrete in-place VLAN commands with no device access.
rtl_write() { printf '%s\n' "$*" >> "$tmp/log"; }
rtl_verify() { printf 'verify %s %s\n' "$@" >> "$tmp/log"; }
: > "$tmp/log"; rtl_fence 99
expect 'verify primary 99
vlan set 4094 1 1
vlan set 2 65564 28
port pvid set 1 99 0
verify fenced 99'
: > "$tmp/log"; rtl_enable_local_wan 99
expect 'verify fenced 99
vlan set 4094 65537 1
verify fallback 99'
: > "$tmp/log"; rtl_disable_local_wan 99
expect 'verify fallback 99
vlan set 4094 1 1
verify fenced 99'
: > "$tmp/log"; rtl_reconnect 99
expect 'verify fenced 99
port pvid set 1 2 0
vlan set 2 65566 28
vlan set 4094 3 1
verify primary 99'
: > "$tmp/log"; if rtl_fence 2; then exit 1; fi
[ ! -s "$tmp/log" ]
echo "OK: ordered transition contract, phase failures and isolation mask model"
