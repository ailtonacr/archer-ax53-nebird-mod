#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LIB="$ROOT/mods/020-managed-switch-files/usr/lib/gateway-failover"
CLI="$ROOT/mods/020-managed-switch-files/usr/sbin/ax53-failover"
. "$LIB/core.sh"
assert() {
    expected=$1; shift
    actual=$(fo_step "$@")
    [ "$actual" = "$expected" ] || { echo "FAIL expected $expected got $actual" >&2; exit 1; }
}
assert 'NORMAL 0 none' NORMAL 0 healthy 6 24 0
assert 'NORMAL 0 none' SUSPECT 0 local-reachable 6 24 0
assert 'SUSPECT 1 none' NORMAL 0 down 6 24 0
assert 'SUSPECT 5 none' SUSPECT 4 down 6 24 0
assert 'SUSPECT 6 takeover' SUSPECT 5 down 6 24 0
assert 'SUSPECT 0 none' SUSPECT 5 upstream-down 6 24 0
assert 'SUSPECT 0 none' SUSPECT 5 local-unreachable 6 24 0
assert 'NORMAL 0 none' SUSPECT 5 healthy 6 24 0
assert 'RECOVERY 24 none' RECOVERY 23 healthy 6 24 0
assert 'RECOVERY 24 return' RECOVERY 23 healthy 6 24 1
assert 'FAILOVER 0 none' RECOVERY 23 down 6 24 1
assert 'ERROR 0 none' ERROR 0 healthy 6 24 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
export GF_ETC_ROOT="$ROOT/mods/020-managed-switch-files/etc" GF_DATA_ROOT="$tmp/data" GF_RUN_ROOT="$tmp/run" GF_LIB_ROOT="$tmp/lib"
export GF_CLOCK_FILE="$tmp/clock"
echo 100 > "$GF_CLOCK_FILE"
advance() { echo $(($(cat "$GF_CLOCK_FILE") + 5)) > "$GF_CLOCK_FILE"; }
tick() { advance; sh "$CLI" tick; }
mkdir -p "$GF_LIB_ROOT"
cp "$LIB/"* "$GF_LIB_ROOT/"
chmod +x "$GF_LIB_ROOT/board-adapter"
sh "$CLI" init
sh "$CLI" status | grep -qx 'mode=disabled'
sh "$CLI" tick
[ ! -f "$GF_RUN_ROOT/gateway-failover.state" ]
# Observer policy can only be selected with an existing managed profile.
if sh "$CLI" set-observe; then echo "observation accepted without managed profile" >&2; exit 1; fi
mkdir -p "$GF_DATA_ROOT/managed-switch"
printf 'enabled=1\n' > "$GF_DATA_ROOT/managed-switch/config"
sh "$CLI" set-observe
sh "$CLI" status | grep -qx 'mode=observe'
touch "$GF_DATA_ROOT/managed-switch/transition.pending"
sh "$CLI" set-disabled
[ -f "$GF_DATA_ROOT/managed-switch/transition.pending" ]
rm "$GF_DATA_ROOT/managed-switch/transition.pending"
sh "$CLI" status | grep -qx 'mode=disabled'
sed 's/mode=disabled/mode=auto/' "$GF_DATA_ROOT/gateway-failover/config" > "$tmp/c"
mv "$tmp/c" "$GF_DATA_ROOT/gateway-failover/config"
if sh "$CLI" tick; then echo "FAIL unqualified auto" >&2; exit 1; fi
[ ! -f "$GF_DATA_ROOT/gateway-failover/journal" ]
# Mock adapter: no real hardware commands.
cat > "$GF_LIB_ROOT/board-adapter" <<'EOF'
#!/bin/sh
case "$1" in
 preflight|takeover|verify-takeover|return|verify-return) exit 0;;
 probe-primary) cat "$GF_DATA_ROOT/probe";;
 *) exit 1;;
esac
EOF
chmod +x "$GF_LIB_ROOT/board-adapter"
echo down > "$GF_DATA_ROOT/probe"
if sh "$CLI" manual-return; then echo "FAIL premature manual return" >&2; exit 1; fi
tick
# Repeated immediate ticks must not advance the hysteresis.
for n in 1 2 3 4 5 6 7; do sh "$CLI" tick; done
[ ! -f "$GF_DATA_ROOT/gateway-failover/journal" ]
grep -q '^SUSPECT 1 ' "$GF_RUN_ROOT/gateway-failover.state"
for n in 1 2 3 4 5; do tick; done
[ ! -f "$GF_DATA_ROOT/gateway-failover/journal" ]
tick
grep -qx 'stable:FAILOVER' "$GF_DATA_ROOT/gateway-failover/journal"
echo healthy > "$GF_DATA_ROOT/probe"
for n in $(seq 1 25); do tick; done
grep -qx 'stable:FAILOVER' "$GF_DATA_ROOT/gateway-failover/journal"
sh "$CLI" manual-return
grep -qx 'stable:NORMAL' "$GF_DATA_ROOT/gateway-failover/journal"
echo down > "$GF_DATA_ROOT/probe"
for n in 1 2 3 4 5 6 7; do tick; done
echo healthy > "$GF_DATA_ROOT/probe"
for n in $(seq 1 25); do tick; done
sed 's/auto_return=0/auto_return=1/' "$GF_DATA_ROOT/gateway-failover/config" > "$tmp/c"
mv "$tmp/c" "$GF_DATA_ROOT/gateway-failover/config"
tick
grep -qx 'stable:NORMAL' "$GF_DATA_ROOT/gateway-failover/journal"
# An old runtime phase must not win over a verified durable journal.
printf 'FAILOVER 0 unknown none 0 0 auto:5:6:24\n' > "$GF_RUN_ROOT/gateway-failover.state"
tick
grep -q '^NORMAL ' "$GF_RUN_ROOT/gateway-failover.state"
mkdir "$GF_RUN_ROOT/ax53-network.lock"
if sh "$CLI" tick; then echo "FAIL concurrent tick" >&2; exit 1; fi
rmdir "$GF_RUN_ROOT/ax53-network.lock"
echo pending:takeover > "$GF_DATA_ROOT/gateway-failover/journal"
if sh "$CLI" tick; then echo "FAIL pending journal accepted" >&2; exit 1; fi
grep -q '^ERROR ' "$GF_RUN_ROOT/gateway-failover.state"
echo "OK: policy, qualified mock transitions, hysteresis, recovery and fail-closed journal"
sh "$ROOT/scripts/test-gateway-transition.sh"
# Source the read-only guard in the fake data root, without touching stock.
. "$LIB/vendor-guard.sh"
rm -f "$GF_DATA_ROOT/gateway-failover/journal"
printf 'mode=disabled\n' > "$GF_DATA_ROOT/gateway-failover/config"
ax53_vendor_allowed
printf 'pending:takeover\n' > "$GF_DATA_ROOT/gateway-failover/journal"
if ax53_vendor_allowed; then echo "vendor writer allowed with pending journal" >&2; exit 1; fi
printf 'stable:NORMAL\n' > "$GF_DATA_ROOT/gateway-failover/journal"
printf 'mode=auto\n' > "$GF_DATA_ROOT/gateway-failover/config"
if ax53_vendor_allowed; then echo "vendor writer allowed in auto" >&2; exit 1; fi
