#!/bin/sh
set -eu

ROOT="${ROOT:-$(pwd)}"
RECOVERY="$ROOT/src/init/netbird-recovery"
RECOVERY_INIT="$ROOT/src/init/netbird-recovery.init"

sh -n "$RECOVERY" "$RECOVERY_INIT"

NB_RECOVERY_INCLUDE_ONLY=1
export NB_RECOVERY_INCLUDE_ONLY
. "$RECOVERY"

fail() {
    echo "netbird recovery test failed: $*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"
}

# Exact exponential schedule requested for transient recovery, capped forever
# at five minutes after the sixth exponential step.
expected="5 10 20 40 80 160 300 300 300"
i=1
actual=""
while [ "$i" -le 9 ]; do
    d="$(nb_recovery_delay_for_failure "$i")"
    actual="${actual}${actual:+ }$d"
    [ "$d" -le 300 ] || fail "backoff exceeded 300s at failure $i"
    i=$((i + 1))
done
assert_eq "$actual" "$expected" "backoff schedule"

MOCK_ACTIVE=1
MOCK_CONNECTED=0
MOCK_IDENTITY=1
MOCK_PENDING=0
MOCK_TRIGGER_RC=1
MOCK_WAIT_RC=1
MOCK_TRIGGER_COUNT=0

nb_recovery_native_active() { [ "$MOCK_ACTIVE" = "1" ]; }
nb_runtime_is_connected() { [ "$MOCK_CONNECTED" = "1" ]; }
nb_recovery_identity_ready() { [ "$MOCK_IDENTITY" = "1" ]; }
nb_recovery_netifd_pending() { [ "$MOCK_PENDING" = "1" ]; }
nb_recovery_trigger() { MOCK_TRIGGER_COUNT=$((MOCK_TRIGGER_COUNT + 1)); return "$MOCK_TRIGGER_RC"; }
nb_recovery_wait_connected() { return "$MOCK_WAIT_RC"; }
nb_recovery_log() { :; }

# OFF/type mismatch: reset state and do not trigger anything.
NB_RECOVERY_FAILURES=4
MOCK_ACTIVE=0
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "inactive"
assert_eq "$NB_RECOVERY_FAILURES" "0"
assert_eq "$NB_RECOVERY_DELAY" "60"
assert_eq "$MOCK_TRIGGER_COUNT" "0"

# Healthy: reset backoff and poll at the low-frequency health interval.
MOCK_ACTIVE=1
MOCK_CONNECTED=1
NB_RECOVERY_FAILURES=5
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "connected"
assert_eq "$NB_RECOVERY_FAILURES" "0"
assert_eq "$NB_RECOVERY_DELAY" "300"
assert_eq "$MOCK_TRIGGER_COUNT" "0"

# No persistent identity: do not provoke SSO/login loops.
MOCK_CONNECTED=0
MOCK_IDENTITY=0
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "identity-not-ready"
assert_eq "$NB_RECOVERY_DELAY" "300"
assert_eq "$MOCK_TRIGGER_COUNT" "0"

# Existing netifd setup/reconnect wins; supervisor waits without incrementing.
MOCK_IDENTITY=1
MOCK_PENDING=1
NB_RECOVERY_FAILURES=3
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "netifd-pending"
assert_eq "$NB_RECOVERY_FAILURES" "3"
assert_eq "$NB_RECOVERY_DELAY" "5"
assert_eq "$MOCK_TRIGGER_COUNT" "0"

# Trigger failures follow the exact capped backoff sequence.
MOCK_PENDING=0
MOCK_TRIGGER_RC=1
NB_RECOVERY_FAILURES=0
MOCK_TRIGGER_COUNT=0
for delay in 5 10 20 40 80 160 300 300; do
    nb_recovery_step
    assert_eq "$NB_RECOVERY_STEP_STATE" "trigger-failed"
    assert_eq "$NB_RECOVERY_DELAY" "$delay"
done
assert_eq "$MOCK_TRIGGER_COUNT" "8"

# A successful native trigger that reaches Connected resets the sequence.
MOCK_TRIGGER_RC=0
MOCK_WAIT_RC=0
NB_RECOVERY_FAILURES=7
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "connected"
assert_eq "$NB_RECOVERY_FAILURES" "0"
assert_eq "$NB_RECOVERY_DELAY" "300"

# If the user switches VPN OFF while waiting, retries are cancelled/reset.
MOCK_WAIT_RC=2
NB_RECOVERY_FAILURES=4
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "inactive"
assert_eq "$NB_RECOVERY_FAILURES" "0"
assert_eq "$NB_RECOVERY_DELAY" "60"

# A second supervisor instance/attempt does not count as a network failure.
MOCK_TRIGGER_RC=2
MOCK_WAIT_RC=1
NB_RECOVERY_FAILURES=2
nb_recovery_step
assert_eq "$NB_RECOVERY_STEP_STATE" "attempt-locked"
assert_eq "$NB_RECOVERY_FAILURES" "2"
assert_eq "$NB_RECOVERY_DELAY" "5"

# Architectural guard: recovery may re-trigger native lifecycle only. It must
# never become a second daemon/runtime owner.
RECOVERY_CODE="$(sed '/^[[:space:]]*#/d' "$RECOVERY")"
if printf '%s\n' "$RECOVERY_CODE" | grep -Eq '(^|[^[:alnum:]_])nb_runtime_connect([^[:alnum:]_]|$)|\$NB_BIN[[:space:]]+up|service_start[[:space:]]+.*netbird([^_-]|$)'; then
    fail "recovery worker contains a direct NetBird lifecycle call"
fi
grep -Fq 'ubus call network.interface.vpn disconnect' "$RECOVERY" || fail "missing native disconnect trigger"
grep -Fq 'ubus call network.interface.vpn connect' "$RECOVERY" || fail "missing native connect trigger"
grep -Fq '/etc/init.d/vpnc restart' "$RECOVERY" || fail "missing vpnc fallback"
grep -Fq 'NB_RECOVERY_MAX_DELAY="${NB_RECOVERY_MAX_DELAY:-300}"' "$RECOVERY" || fail "300s cap missing"

echo "netbird polling recovery/backoff/native-lifecycle behavior ok"
