#!/bin/sh
set -eu

ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
TMP="${TMPDIR:-/tmp}/netbird-profiles-test-$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/legacy/state"

NB_LEGACY_ROOT="$TMP/legacy"
NB_PROFILES_ROOT="$NB_LEGACY_ROOT/profiles"
NB_ACTIVE_PROFILE_FILE="$TMP/active-profile"
NB_LEGACY_ADOPTION_FILE="$NB_LEGACY_ROOT/legacy-adoption"
NB_DEFAULT_MGMT="https://netbird.example.test"
NB_DEFAULT_PORT="51820"

nb_get() {
    file="$1" key="$2" def="${3:-}"
    [ -f "$file" ] || { printf '%s\n' "$def"; return 0; }
    value="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
    [ -n "$value" ] && printf '%s\n' "$value" || printf '%s\n' "$def"
}
nb_set() {
    file="$1" key="$2" value="$3"
    if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
        sed "s/^${key}=.*/${key}=${value}/" "$file" > "$file.tmp"
        mv "$file.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
nb_ensure_settings() {
    mkdir -p "$NB_CONFIG_DIR" "$NB_STATE_DIR"
    [ -f "$NB_SETTINGS_FILE" ] || printf 'enable=0\nenrolled=0\nmanagement_url=%s\nwireguard_port=%s\n' "$NB_DEFAULT_MGMT" "$NB_DEFAULT_PORT" > "$NB_SETTINGS_FILE"
}

UCI_LOG="$TMP/uci.log"
: > "$UCI_LOG"
UCI_SECTION_EXISTS=0
uci() {
    quiet=0
    if [ "${1:-}" = "-q" ]; then quiet=1; shift; fi
    cmd="${1:-}"; shift || true
    case "$cmd" in
        show)
            printf "vpn.client=client\n"
            if [ "$UCI_SECTION_EXISTS" = "1" ]; then
                printf "vpn.netbird_legacy=server\n"
                printf "vpn.netbird_legacy.type='netbirdvpn'\n"
                printf "vpn.netbird_legacy.legacy_identity='1'\n"
            fi
            ;;
        get)
            case "${1:-}" in
                vpn.netbird_legacy)
                    [ "$UCI_SECTION_EXISTS" = "1" ] && printf 'server\n' || return 1 ;;
                network.vpn.profile_key) return 1 ;;
                *) return 1 ;;
            esac
            ;;
        set)
            printf 'set %s\n' "${1:-}" >> "$UCI_LOG"
            case "${1:-}" in vpn.netbird_legacy=server) UCI_SECTION_EXISTS=1 ;; esac
            ;;
        commit)
            printf 'commit %s\n' "${1:-}" >> "$UCI_LOG"
            ;;
        *) return 1 ;;
    esac
}

. "$ROOT/src/init/netbird-profiles.sh"

fail() { echo "netbird profile test failed: $*" >&2; exit 1; }

nb_profile_key_valid "cfg123" || fail "ordinary stock key rejected"
nb_profile_key_valid "profile-a_1.2" || fail "safe extended stock key rejected"
if nb_profile_key_valid "../escape"; then fail "path traversal key accepted"; fi
if nb_profile_key_valid "bad/key"; then fail "slash key accepted"; fi

nb_profile_select "profile-a"
[ "$NB_CONFIG_DIR" = "$NB_PROFILES_ROOT/profile-a" ] || fail "profile A config dir wrong"
[ "$NB_SETTINGS_FILE" = "$NB_PROFILES_ROOT/profile-a/settings" ] || fail "profile A settings path wrong"
nb_profile_select "profile-b"
[ "$NB_CONFIG_DIR" = "$NB_PROFILES_ROOT/profile-b" ] || fail "profile B config dir wrong"
[ "$NB_CONFIG_DIR" != "$NB_PROFILES_ROOT/profile-a" ] || fail "profiles share a directory"

cat > "$NB_LEGACY_ROOT/settings" <<'EOF'
description=Existing NetBird
management_url=https://netbird.example.test
hostname=archer-legacy
disable_dns=1
disable_firewall=1
disable_client_routes=1
disable_server_routes=1
disable_ipv6=1
network_monitor=0
advertise_lan=0
advertise_cidr=
wireguard_port=51820
enable=1
enrolled=1
EOF
printf '{}\n' > "$NB_LEGACY_ROOT/default.json"
printf 'state\n' > "$NB_LEGACY_ROOT/state/example"

nb_profile_use_legacy
nb_legacy_profile_adopt || fail "legacy adoption failed"
[ -f "$NB_LEGACY_ADOPTION_FILE" ] || fail "adoption marker missing"
grep -Fxq 'completed=1' "$NB_LEGACY_ADOPTION_FILE" || fail "adoption marker incomplete"
grep -Fxq 'profile_key=netbird_legacy' "$NB_LEGACY_ADOPTION_FILE" || fail "adopted key not recorded"
grep -Fq 'set vpn.netbird_legacy=server' "$UCI_LOG" || fail "native stock server row not created"
grep -Fq 'set vpn.netbird_legacy.type=netbirdvpn' "$UCI_LOG" || fail "native NetBird type not persisted"
grep -Fq 'set vpn.netbird_legacy.profile_key=netbird_legacy' "$UCI_LOG" || fail "profile key not persisted"
[ -s "$NB_PROFILES_ROOT/netbird_legacy/default.json" ] || fail "identity was not copied to profile-scoped storage"
[ -f "$NB_PROFILES_ROOT/netbird_legacy/settings" ] || fail "settings were not copied to profile-scoped storage"
[ -f "$NB_PROFILES_ROOT/netbird_legacy/state/example" ] || fail "state was not copied to profile-scoped storage"
grep -Fxq 'enable=0' "$NB_PROFILES_ROOT/netbird_legacy/settings" || fail "adopted profile unexpectedly active"
grep -Fxq 'enrolled=1' "$NB_PROFILES_ROOT/netbird_legacy/settings" || fail "existing identity not recognized as enrolled"

before="$(wc -l < "$UCI_LOG" | tr -d ' ')"
nb_legacy_profile_adopt || fail "second adoption returned failure"
after="$(wc -l < "$UCI_LOG" | tr -d ' ')"
[ "$before" = "$after" ] || fail "completed migration recreated/mutated the stock row"

# The historical source is deliberately preserved as migration evidence/input;
# the runtime copy is profile scoped. Deleting the adopted stock row later must
# not cause boot to recreate it because the completion marker remains.
[ -s "$NB_LEGACY_ROOT/default.json" ] || fail "legacy identity source was destructively moved"

echo "netbird profile isolation/legacy-adoption/multi-profile key behavior ok"
