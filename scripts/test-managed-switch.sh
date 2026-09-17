#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

mods="$(
    find mods -maxdepth 1 -type f -name '[0-9][0-9][0-9]-*.sh' -printf '%f\n' |
    sort
)"
expected="011-devssh.sh
020-managed-switch.sh"
[ "$mods" = "$expected" ] || {
    echo "Found custom mods:" >&2
    echo "$mods" >&2
    fail "branch must contain only SSH and managed-switch mods"
}


tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fake_root="$tmp/rootfs"
mkdir -p "$fake_root/etc/rc.d" "$fake_root/etc/dropbear"

ROOTFS_DIR="$fake_root" bash -e mods/011-devssh.sh >/dev/null
ROOTFS_DIR="$fake_root" bash -e mods/020-managed-switch.sh >/dev/null

[ -x "$fake_root/etc/init.d/devssh" ] || fail "devssh not packaged"
[ -x "$fake_root/usr/sbin/ax53-switch" ] || fail "ax53-switch not packaged"
[ -x "$fake_root/etc/init.d/managed-switch" ] || fail "managed-switch init not packaged"
[ -x "$fake_root/etc/hotplug.d/switch/99-managed-switch" ] || fail "managed-switch hotplug not packaged"
[ -f "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" ] || fail "LuCI controller not packaged"
[ -f "$fake_root/usr/lib/lua/luci/view/managed-switch.html" ] || fail "managed-switch UI not packaged"
grep -Fq 'entry({"admin", "managed_switch"}' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "LuCI route missing"
grep -Fq 'operation == "save"' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "UI save endpoint missing"
grep -Fq '<h1>Switch / VLAN</h1>' "$fake_root/usr/lib/lua/luci/view/managed-switch.html" || fail "UI title missing"
grep -Fq 'Aplicar agora' "$fake_root/usr/lib/lua/luci/view/managed-switch.html" || fail "explicit apply action missing"
[ -L "$fake_root/etc/rc.d/S55devssh" ] || fail "S55devssh missing"
[ -L "$fake_root/etc/rc.d/S99managed-switch" ] || fail "S99managed-switch missing"

grep -Fxq 'enabled=0' "$fake_root/etc/managed-switch/default.conf" || fail "default must be disabled"
grep -Fxq 'wan_vid=4094' "$fake_root/etc/managed-switch/default.conf" || fail "WAN VID must preserve stock interface"
grep -Fxq 'lan_vid=2' "$fake_root/etc/managed-switch/default.conf" || fail "LAN VID must preserve stock interface"

state="$tmp/tp_data"
log="$tmp/driver.log"
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" init >/dev/null

MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" check | grep -Fxq OK || fail "config validation failed"

# Disabled configuration must be a no-op.
: > "$log"
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" apply >/dev/null
[ ! -s "$log" ] || fail "disabled profile unexpectedly touched switch"

# Force-apply is used by offline tests only. Verify the exact intended L2 layout.
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" apply --force >/dev/null

grep -Fxq 'vlan reset' "$log" || fail "VLAN table reset missing"
grep -Fxq 'vlan init' "$log" || fail "VLAN table init missing"
grep -Fxq 'port ptype set 16 1' "$log" || fail "CPU tagged-frame mode missing"
grep -Fxq 'vlan set 4094 3 1' "$log" || fail "WAN VLAN layout is not WAN0 + tagged LAN1"
grep -Fxq 'vlan set 2 65566 28' "$log" || fail "LAN VLAN layout is not tagged LAN1+CPU + access LAN2-4"

# Atomic full-profile update: changing the trunk must not require an invalid
# intermediate state between trunk_port and access_ports.
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" configure 4094 2 2 "1 3 4" 1 0 >/dev/null
grep -Fxq 'trunk_port=2' "$state/managed-switch/config" || fail "atomic configure did not move trunk"
grep -Fq 'access_ports="1 3 4"' "$state/managed-switch/config" || fail "atomic configure did not update access ports"
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" check | grep -Fxq OK || fail "atomic configuration is invalid"

: > "$log"
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" apply --force >/dev/null
grep -Fxq 'vlan set 4094 5 1' "$log" || fail "WAN VLAN did not follow trunk move to LAN2"
grep -Fxq 'vlan set 2 65566 26' "$log" || fail "LAN untagged mask did not follow access-port update"

# Invalid full-profile change must fail and preserve the last valid config.
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" configure 4094 2 2 "2 3 4" 1 0 >/dev/null 2>&1 && fail "invalid full-profile overlap accepted"
MS_ETC_ROOT="$fake_root/etc" MS_TP_DATA_ROOT="$state" MS_TEST_LOG="$log" "$fake_root/usr/sbin/ax53-switch" check | grep -Fxq OK || fail "rejected full-profile change corrupted config"
grep -Fxq 'trunk_port=2' "$state/managed-switch/config" || fail "rejected full-profile change replaced trunk"
grep -Fq 'access_ports="1 3 4"' "$state/managed-switch/config" || fail "rejected full-profile change replaced access ports"

if command -v luac >/dev/null 2>&1; then
    luac -p "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "LuCI controller syntax invalid"
fi

echo "OK: managed-switch offline contract + LuCI packaging"
