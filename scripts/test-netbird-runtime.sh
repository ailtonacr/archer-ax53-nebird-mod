#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/netbird-runtime-test-$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
NB_SETTINGS_FILE="$TMP/settings"
NB_DEFAULT_PORT=51820

# Minimal base-library dependency used by the pure/runtime flag helpers.
nb_get() {
    file="$1" key="$2" def="${3:-}"
    [ -f "$file" ] || { printf '%s\n' "$def"; return 0; }
    value="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
    [ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$def"
}

# Shell functions are defined without executing router-dependent operations.
. "$ROOT/src/init/netbird-runtime.sh"

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

echo "netbird runtime status/flag behavior ok"
