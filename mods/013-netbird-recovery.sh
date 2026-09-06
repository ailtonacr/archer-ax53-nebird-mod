#!/bin/bash -e
# Install the polling-only recovery supervisor after the native NetBird VPN
# integration is finalized by 012-netbird-native-vpn.sh.
#
# This supervisor is deliberately NOT a second NetBird lifecycle owner. It may
# only observe desired/actual state and re-trigger TP-Link vpnc/netifd. The
# canonical daemon/materialization path remains:
#   vpnc -> netifd -> proto netbird -> netbird-runtime.sh -> NetBird binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
R="${ROOTFS_DIR:-$PROJECT_ROOT/rootfs}"
case "$R" in /*) ;; *) R="$PROJECT_ROOT/$R" ;; esac

RECOVERY_SRC="$PROJECT_ROOT/src/init/netbird-recovery"
RECOVERY_INIT_SRC="$PROJECT_ROOT/src/init/netbird-recovery.init"
RECOVERY_TEST="$PROJECT_ROOT/scripts/test-netbird-recovery.sh"

for f in "$RECOVERY_SRC" "$RECOVERY_INIT_SRC" "$RECOVERY_TEST"; do
  [ -f "$f" ] || { echo "Error: missing NetBird recovery input: $f" >&2; exit 1; }
done
[ -d "$R" ] || { echo "Error: rootfs dir does not exist: $R" >&2; exit 1; }

# Source-level behavioral test is part of the firmware build gate. It covers
# backoff, OFF/ON semantics, pending netifd setup, lock handling and reset after
# successful recovery.
ROOT="$PROJECT_ROOT" sh "$RECOVERY_TEST"

mkdir -p "$R/sbin" "$R/etc/init.d" "$R/etc/rc.d"
cp "$RECOVERY_SRC" "$R/sbin/netbird-recovery"
cp "$RECOVERY_INIT_SRC" "$R/etc/init.d/netbird-recovery"
chmod 0755 "$R/sbin/netbird-recovery" "$R/etc/init.d/netbird-recovery"

# 012 removes the retired standalone S99netbird lifecycle. Keep that invariant
# and enable only the lightweight recovery observer after vpnc (START=90).
rm -f "$R/etc/rc.d/S99netbird"
ln -sfn "../init.d/netbird-recovery" "$R/etc/rc.d/S99netbird-recovery"

cmp -s "$RECOVERY_SRC" "$R/sbin/netbird-recovery" || {
  echo "Error: packaged NetBird recovery worker drifted from canonical source" >&2; exit 1;
}
cmp -s "$RECOVERY_INIT_SRC" "$R/etc/init.d/netbird-recovery" || {
  echo "Error: packaged NetBird recovery init drifted from canonical source" >&2; exit 1;
}
[ ! -e "$R/etc/rc.d/S99netbird" ] || {
  echo "Error: retired standalone NetBird boot lifecycle was re-enabled" >&2; exit 1;
}
[ -L "$R/etc/rc.d/S99netbird-recovery" ] || {
  echo "Error: NetBird polling recovery boot link missing" >&2; exit 1;
}
[ "$(readlink "$R/etc/rc.d/S99netbird-recovery")" = "../init.d/netbird-recovery" ] || {
  echo "Error: NetBird recovery boot link targets the wrong service" >&2; exit 1;
}

grep -Fq 'NB_RECOVERY_MAX_DELAY="${NB_RECOVERY_MAX_DELAY:-300}"' "$R/sbin/netbird-recovery"
grep -Fq '5) printf' "$R/sbin/netbird-recovery"
grep -Fq '6) printf' "$R/sbin/netbird-recovery"
grep -Fq 'ubus call network.interface.vpn disconnect' "$R/sbin/netbird-recovery"
grep -Fq 'ubus call network.interface.vpn connect' "$R/sbin/netbird-recovery"
grep -Fq '/etc/init.d/vpnc restart' "$R/sbin/netbird-recovery"
grep -Fq 'SERVICE_DAEMONIZE=1' "$R/etc/init.d/netbird-recovery"
grep -Fq 'START=99' "$R/etc/init.d/netbird-recovery"

RECOVERY_CODE="$(sed '/^[[:space:]]*#/d' "$R/sbin/netbird-recovery")"
if printf '%s\n' "$RECOVERY_CODE" | grep -Eq '(^|[^[:alnum:]_])nb_runtime_connect([^[:alnum:]_]|$)|\$NB_BIN[[:space:]]+up|service_start[[:space:]]+.*netbird([^_-]|$)'; then
  echo "Error: recovery worker became a direct NetBird lifecycle owner" >&2
  exit 1
fi

# Polling is the only recovery trigger by architectural decision. Do not add a
# WAN/iface hotplug dependency: the upstream router can keep AX53 WAN link UP
# while Internet connectivity beyond it is unavailable.
if grep -R -l 'netbird-recovery' "$R/etc/hotplug.d" >/dev/null 2>&1; then
  echo "Error: NetBird recovery must not depend on WAN/iface hotplug" >&2
  exit 1
fi

echo "### NetBird polling recovery supervisor installed ###"
