#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/netbird-runtime-test-$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
NB_SETTINGS_FILE="$TMP/settings"
NB_DEFAULT_PORT=51820

# Minimal base-library dependency used by the pure/runtime helpers.
nb_get() {
    file="$1" key="$2" def="${3:-}"
    [ -f "$file" ] || { printf '%s\n' "$def"; return 0; }
    value="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
    [ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$def"
}

# Shell functions are defined without executing router-dependent operations.
. "$ROOT/src/init/netbird-runtime.sh"

# Redirect ephemeral firewall bookkeeping into the test sandbox.
NB_FW_STATE="$TMP/firewall.state"
NB_FW_STATE_NEW="$TMP/firewall.state.new"
NB_IFNAME="wt0"

expect_connected() {
    json="$1"
    nb_status_json_is_connected "$json" || {
        echo "expected connected status to pass: $json" >&2
        exit 1
    }
}

expect_disconnected() {
    json="$1"
    if nb_status_json_is_connected "$json"; then
        echo "expected status to be rejected: $json" >&2
        exit 1
    fi
}

# Exact v0.77.1 semantics used by netifd publication: management is distinct
# from signal and daemonStatus must be Connected.
expect_connected '{"daemonStatus":"Connected","management":{"url":"https://m","connected":true,"error":""},"signal":{"url":"https://s","connected":true}}'
expect_connected '{ "signal": {"connected":false}, "management": {"connected": true}, "daemonStatus": "Connected" }'
expect_disconnected '{"daemonStatus":"Connected","management":{"connected":false},"signal":{"connected":true}}'
expect_disconnected '{"daemonStatus":"Connecting","management":{"connected":true},"signal":{"connected":true}}'
expect_disconnected '{"daemonStatus":"Connected","signal":{"connected":true}}'
expect_disconnected '{"daemonStatus":"Connected","management":{"connected":false},"signal":{"connected":false}}'

nb_status_json_is_userspace '{"usesKernelInterface":false}' || {
    echo "userspace status was rejected" >&2
    exit 1
}
if nb_status_json_is_userspace '{"usesKernelInterface":true}'; then
    echo "kernel interface status was accepted" >&2
    exit 1
fi
if nb_status_json_is_userspace '{"daemonStatus":"Connected"}'; then
    echo "status without interface type was accepted" >&2
    exit 1
fi

cat > "$NB_SETTINGS_FILE" <<'EOF'
disable_dns=0
disable_firewall=0
disable_client_routes=1
disable_server_routes=0
disable_ipv6=1
network_monitor=0
advertise_lan=0
advertise_cidr=
wireguard_port=51999
hostname=teste-casa
EOF
flags="$(nb_up_flags)"
for token in \
    '--disable-dns=true' \
    '--disable-firewall=false' \
    '--disable-client-routes=true' \
    '--disable-server-routes=false' \
    '--disable-ipv6=true' \
    '--network-monitor=false' \
    '--wireguard-port=51999' \
    '--hostname=teste-casa'
do
    printf '%s' "$flags" | grep -Fq -- "$token" || {
        echo "canonical up flags missing $token: $flags" >&2
        exit 1
    }
done

# Each logical flag must occur exactly once so enrollment and normal connect
# cannot accidentally stack duplicate options.
for name in disable-dns disable-firewall disable-client-routes disable-server-routes disable-ipv6 network-monitor wireguard-port hostname
do
    count="$(printf '%s' "$flags" | grep -o -- "--$name" | wc -l | tr -d ' ')"
    [ "$count" = "1" ] || {
        echo "flag --$name occurred $count times: $flags" >&2
        exit 1
    }
done

# AX53 gateway-mode invariants:
# - client routes must be enabled so LAN hosts can consume remote Networks;
# - server routes must be enabled so this peer can route the home LAN;
# - NetBird firewall must stay enabled so policy enforcement remains authoritative.
cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=192.168.10.0/24
disable_client_routes=1
disable_server_routes=1
disable_firewall=1
wireguard_port=51820
EOF
if nb_runtime_validate_settings >/dev/null 2>&1; then
    echo "routing invariant accepted advertise_lan=1 + disable_client_routes=1" >&2
    exit 1
fi
sed -i 's/^disable_client_routes=1$/disable_client_routes=0/' "$NB_SETTINGS_FILE"
if nb_runtime_validate_settings >/dev/null 2>&1; then
    echo "routing invariant accepted advertise_lan=1 + disable_server_routes=1" >&2
    exit 1
fi
sed -i 's/^disable_server_routes=1$/disable_server_routes=0/' "$NB_SETTINGS_FILE"
if nb_runtime_validate_settings >/dev/null 2>&1; then
    echo "routing invariant accepted advertise_lan=1 + disable_firewall=1" >&2
    exit 1
fi
sed -i 's/^disable_firewall=1$/disable_firewall=0/' "$NB_SETTINGS_FILE"
nb_runtime_validate_settings || {
    echo "routing invariant rejected policy-safe route configuration" >&2
    exit 1
}

# The shared runtime must not install direct FORWARD ACCEPT rules ahead of the
# NetBird routing ACL chains. Policy ordering belongs to the canonical firewall
# adapter, which appends scoped TP-Link rules after NetBird's own jumps.
if grep -Eq 'iptables[[:space:]].*-I[[:space:]]+FORWARD|iptables[[:space:]].*--insert[[:space:]]+FORWARD' "$ROOT/src/init/netbird-runtime.sh"; then
    echo "runtime contains a direct FORWARD priority bypass" >&2
    exit 1
fi

# Mock firewall primitives and prove A -> B removes A using applied-state data,
# rather than reading already-mutated settings and trying to remove B twice.
: > "$TMP/fw.log"
FW_BLOCK_FAIL=0
uci_get_state() { printf '%s\n' "br-lan"; }
nb_fw_access() {
    printf 'access port=%s mode=%s cidr=%s homeif=%s\n' "$1" "$2" "$3" "$4" >> "$TMP/fw.log"
    return 0
}
nb_fw_block() {
    printf 'block port=%s mode=%s cidr=%s homeif=%s\n' "$1" "$2" "$3" "$4" >> "$TMP/fw.log"
    [ "$FW_BLOCK_FAIL" = "1" ] && return 1
    return 0
}

cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=192.168.10.0/24
disable_server_routes=0
disable_firewall=0
wireguard_port=51820
EOF
nb_runtime_apply_firewall
[ -f "$NB_FW_STATE" ] || { echo "firewall applied-state snapshot missing" >&2; exit 1; }
grep -Fxq 'port=51820' "$NB_FW_STATE"
grep -Fxq 'cidr=192.168.10.0/24' "$NB_FW_STATE"

cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=172.24.10.0/24
disable_server_routes=0
disable_firewall=0
wireguard_port=51999
EOF
nb_runtime_apply_firewall
grep -Fq 'block port=51820 mode=lan cidr=192.168.10.0/24 homeif=br-lan' "$TMP/fw.log" || {
    echo "A -> B did not remove the previously applied firewall values" >&2
    cat "$TMP/fw.log" >&2
    exit 1
}
grep -Fq 'access port=51999 mode=lan cidr=172.24.10.0/24 homeif=br-lan' "$TMP/fw.log" || {
    echo "A -> B did not apply the new firewall values" >&2
    cat "$TMP/fw.log" >&2
    exit 1
}
grep -Fxq 'port=51999' "$NB_FW_STATE"
grep -Fxq 'cidr=172.24.10.0/24' "$NB_FW_STATE"

# B -> C with a cleanup failure must abort before C is applied and retain B's
# snapshot so the exact old rules can be retried later.
cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=172.24.20.0/24
disable_server_routes=0
disable_firewall=0
wireguard_port=52000
EOF
FW_BLOCK_FAIL=1
before_access_c="$(grep -Fc 'access port=52000 mode=lan cidr=172.24.20.0/24 homeif=br-lan' "$TMP/fw.log" || true)"
if nb_runtime_apply_firewall >/dev/null 2>&1; then
    echo "B -> C unexpectedly succeeded while old-rule cleanup was forced to fail" >&2
    exit 1
fi
grep -Fxq 'port=51999' "$NB_FW_STATE" || { echo "failed cleanup lost B port snapshot" >&2; exit 1; }
grep -Fxq 'cidr=172.24.10.0/24' "$NB_FW_STATE" || { echo "failed cleanup lost B CIDR snapshot" >&2; exit 1; }
after_access_c="$(grep -Fc 'access port=52000 mode=lan cidr=172.24.20.0/24 homeif=br-lan' "$TMP/fw.log" || true)"
[ "$before_access_c" = "$after_access_c" ] || { echo "C was applied despite B cleanup failure" >&2; exit 1; }

# Retry with cleanup healthy: B is removed using the preserved snapshot and C
# becomes the new applied state.
FW_BLOCK_FAIL=0
nb_runtime_apply_firewall
grep -Fq 'block port=51999 mode=lan cidr=172.24.10.0/24 homeif=br-lan' "$TMP/fw.log" || {
    echo "retry did not remove B from the preserved snapshot" >&2
    exit 1
}
grep -Fq 'access port=52000 mode=lan cidr=172.24.20.0/24 homeif=br-lan' "$TMP/fw.log" || {
    echo "retry did not apply C" >&2
    exit 1
}
grep -Fxq 'port=52000' "$NB_FW_STATE"
grep -Fxq 'cidr=172.24.20.0/24' "$NB_FW_STATE"

# Enrollment metadata is proof of successful authentication, not config-file
# existence. A setup-key login that succeeds marks enrolled before any later
# firewall step can fail independently.
NB_CONFIG_FILE="$TMP/default.json"
NB_STATE_DIR="$TMP/state"
NB_BIN="$TMP/netbird-mock"
NB_SOCK="$TMP/netbird.sock"
NB_CONFIG_DIR="$TMP/profile"
mkdir -p "$NB_CONFIG_DIR" "$NB_STATE_DIR"
printf '{}\n' > "$NB_CONFIG_FILE"
MOCK_CMD_LOG="$TMP/netbird-commands.log"
export MOCK_CMD_LOG
cat > "$NB_BIN" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_CMD_LOG:-/dev/null}"
case "$1" in
    up) exit "${MOCK_UP_RC:-0}" ;;
    down|status) exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$NB_BIN"
cat > "$NB_SETTINGS_FILE" <<'EOF'
enable=1
enrolled=0
management_url=https://netbird.example
hostname=test
disable_dns=1
disable_firewall=1
disable_client_routes=1
disable_server_routes=1
disable_ipv6=1
network_monitor=0
advertise_lan=0
advertise_cidr=
wireguard_port=51820
EOF
nb_ensure_settings() { :; }
nb_mgmt_url() { printf '%s\n' "https://netbird.example"; }
nb_materialize() { :; }
nb_is_running() { return 0; }
nb_runtime_apply_firewall() { return 0; }
nb_runtime_remove_firewall() { return 0; }
nb_set() {
    file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed "s/^${key}=.*/${key}=${value}/" "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
keyfile="$TMP/setup-key"
printf 'secret-for-test-only\n' > "$keyfile"
export MOCK_UP_RC=0
: > "$MOCK_CMD_LOG"
nb_runtime_connect "$keyfile"
[ "$(sed -n '1s/[[:space:]].*$//p' "$MOCK_CMD_LOG")" = "down" ] || {
    echo "runtime did not force daemon down before canonical up" >&2
    cat "$MOCK_CMD_LOG" >&2
    exit 1
}
grep -q '^up .*--disable-client-routes=true' "$MOCK_CMD_LOG" || {
    echo "runtime up did not carry canonical explicit flags" >&2
    cat "$MOCK_CMD_LOG" >&2
    exit 1
}
grep -Fxq 'enrolled=1' "$NB_SETTINGS_FILE" || { echo "successful setup-key login did not mark enrolled" >&2; exit 1; }

sed -i 's/^enrolled=1$/enrolled=0/' "$NB_SETTINGS_FILE"
export MOCK_UP_RC=1
if nb_runtime_connect "$keyfile" >/dev/null 2>&1; then
    echo "failed setup-key login unexpectedly succeeded" >&2
    exit 1
fi
grep -Fxq 'enrolled=0' "$NB_SETTINGS_FILE" || { echo "failed setup-key login marked enrolled" >&2; exit 1; }
unset MOCK_UP_RC

# Identity cleanup must not recreate state/ after deleting it.
NB_CONFIG_FILE="$TMP/default.json"
NB_STATE_DIR="$TMP/state"
mkdir -p "$NB_STATE_DIR"
printf '{}\n' > "$NB_CONFIG_FILE"
cat > "$NB_SETTINGS_FILE" <<'EOF'
enable=1
enrolled=1
EOF
nb_runtime_stop() { :; }
nb_set() {
    file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed "s/^${key}=.*/${key}=${value}/" "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
nb_clean
[ ! -e "$NB_STATE_DIR" ] || { echo "nb_clean recreated state directory" >&2; exit 1; }
[ ! -e "$NB_CONFIG_FILE" ] || { echo "nb_clean left default.json" >&2; exit 1; }
grep -Fxq 'enable=0' "$NB_SETTINGS_FILE"
grep -Fxq 'enrolled=0' "$NB_SETTINGS_FILE"

echo "netbird runtime status/flags/policy-safe-routing/firewall-transition/cleanup behavior ok"
