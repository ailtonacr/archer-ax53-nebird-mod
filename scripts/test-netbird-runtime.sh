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

cat > "$NB_SETTINGS_FILE" <<'EOF'
disable_dns=1
disable_firewall=0
disable_client_routes=1
disable_server_routes=0
disable_ipv6=1
network_monitor=0
advertise_lan=0
advertise_cidr=
wireguard_port=51999
EOF
flags="$(nb_up_flags)"
for token in \
    '--disable-dns=true' \
    '--disable-firewall=false' \
    '--disable-client-routes=true' \
    '--disable-server-routes=false' \
    '--disable-ipv6=true' \
    '--network-monitor=false' \
    '--wireguard-port=51999'
do
    printf '%s' "$flags" | grep -Fq -- "$token" || {
        echo "canonical up flags missing $token: $flags" >&2
        exit 1
    }
done

# Each logical flag must occur exactly once so enrollment and normal connect
# cannot accidentally stack duplicate options.
for name in disable-dns disable-firewall disable-client-routes disable-server-routes disable-ipv6 network-monitor wireguard-port
do
    count="$(printf '%s' "$flags" | grep -o -- "--$name" | wc -l | tr -d ' ')"
    [ "$count" = "1" ] || {
        echo "flag --$name occurred $count times: $flags" >&2
        exit 1
    }
done

# Routing peer invariant: advertise_lan cannot coexist with disabled server
# routes because NetBird v0.77.1 would then refuse to act as a route server.
cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=192.168.10.0/24
disable_server_routes=1
wireguard_port=51820
EOF
if nb_runtime_validate_settings >/dev/null 2>&1; then
    echo "routing invariant accepted advertise_lan=1 + disable_server_routes=1" >&2
    exit 1
fi
sed -i 's/^disable_server_routes=1$/disable_server_routes=0/' "$NB_SETTINGS_FILE"
nb_runtime_validate_settings || {
    echo "routing invariant rejected valid server-route configuration" >&2
    exit 1
}

# Mock firewall primitives and prove A -> B removes A using applied-state data,
# rather than reading already-mutated settings and trying to remove B twice.
: > "$TMP/fw.log"
: > "$TMP/iptables.log"
uci_get_state() { printf '%s\n' "br-lan"; }
nb_fw_access() { printf 'access port=%s mode=%s cidr=%s homeif=%s\n' "$1" "$2" "$3" "$4" >> "$TMP/fw.log"; return 0; }
nb_fw_block() { printf 'block port=%s mode=%s cidr=%s homeif=%s\n' "$1" "$2" "$3" "$4" >> "$TMP/fw.log"; return 0; }
iptables() {
    printf '%s\n' "$*" >> "$TMP/iptables.log"
    case " $* " in
        *" -D "*) return 1 ;;
        *) return 0 ;;
    esac
}

cat > "$NB_SETTINGS_FILE" <<'EOF'
advertise_lan=1
advertise_cidr=192.168.10.0/24
disable_server_routes=0
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

echo "netbird runtime status/flags/routing/firewall-cleanup behavior ok"
