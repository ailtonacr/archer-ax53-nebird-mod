#!/bin/sh
set -eu

ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
TMP="${TMPDIR:-/tmp}/netbird-profiles-test-$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/netbird/profiles"

NB_ROOT="$TMP/netbird"
NB_PROFILES_ROOT="$NB_ROOT/profiles"
NB_ACTIVE_PROFILE_FILE="$TMP/active-profile"

UCI_A=0
UCI_B=0
UCI_NON_NETBIRD=0
UCI_ACTIVE=""

uci() {
    if [ "${1:-}" = "-q" ]; then shift; fi
    cmd="${1:-}"; shift || true
    key="${1:-}"
    case "$cmd" in
        get)
            case "$key" in
                network.vpn.profile_key)
                    [ -n "$UCI_ACTIVE" ] && printf '%s\n' "$UCI_ACTIVE" || return 1 ;;
                vpn.profile-a)
                    [ "$UCI_A" = "1" ] && printf 'server\n' || return 1 ;;
                vpn.profile-a.type)
                    [ "$UCI_A" = "1" ] && printf 'netbirdvpn\n' || return 1 ;;
                vpn.profile-b)
                    [ "$UCI_B" = "1" ] && printf 'server\n' || return 1 ;;
                vpn.profile-b.type)
                    [ "$UCI_B" = "1" ] && printf 'netbirdvpn\n' || return 1 ;;
                vpn.other)
                    [ "$UCI_NON_NETBIRD" = "1" ] && printf 'server\n' || return 1 ;;
                vpn.other.type)
                    [ "$UCI_NON_NETBIRD" = "1" ] && printf 'wireguardvpn\n' || return 1 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# Simulate a caller arriving with an unsafe root-level default context. Sourcing
# the profile helper must erase it until a real stock key is selected.
NB_CONFIG_DIR="$NB_ROOT"
NB_STATE_DIR="$NB_ROOT/state"
NB_CONFIG_FILE="$NB_ROOT/default.json"
NB_SETTINGS_FILE="$NB_ROOT/settings"
. "$ROOT/src/init/netbird-profiles.sh"

fail() { echo "netbird profile test failed: $*" >&2; exit 1; }

[ -z "$NB_CONFIG_DIR" ] || fail "root-level profile context survived helper load"
[ -z "$NB_CONFIG_FILE" ] || fail "root-level identity path survived helper load"
[ -z "$NB_SETTINGS_FILE" ] || fail "root-level settings path survived helper load"

# Stock profile keys are the namespace boundary for provider state.
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

# A/B may coexist. Removing B from vpn.server must never touch A.
mkdir -p "$NB_PROFILES_ROOT/profile-a" "$NB_PROFILES_ROOT/profile-b" "$NB_PROFILES_ROOT/orphan"
printf '{}\n' > "$NB_PROFILES_ROOT/profile-a/default.json"
printf '{}\n' > "$NB_PROFILES_ROOT/profile-b/default.json"
printf '{}\n' > "$NB_PROFILES_ROOT/orphan/default.json"
UCI_A=1
UCI_B=1
nb_profile_gc_orphans || fail "GC failed with two valid stock NetBird rows"
[ -d "$NB_PROFILES_ROOT/profile-a" ] || fail "GC removed stock profile A"
[ -d "$NB_PROFILES_ROOT/profile-b" ] || fail "GC removed stock profile B"
[ ! -d "$NB_PROFILES_ROOT/orphan" ] || fail "GC retained unreferenced orphan"

UCI_B=0
nb_profile_gc_orphans || fail "GC failed after stock profile B deletion"
[ -d "$NB_PROFILES_ROOT/profile-a" ] || fail "deleting B damaged A"
[ ! -d "$NB_PROFILES_ROOT/profile-b" ] || fail "deleted stock B identity was not collected"

# The active profile is retained fail-safe during a transient config/lifecycle race.
mkdir -p "$NB_PROFILES_ROOT/profile-b"
printf '{}\n' > "$NB_PROFILES_ROOT/profile-b/default.json"
printf 'profile-b\n' > "$NB_ACTIVE_PROFILE_FILE"
nb_profile_gc_orphans || fail "GC failed for active fail-safe case"
[ -d "$NB_PROFILES_ROOT/profile-b" ] || fail "GC removed currently active profile"
rm -f "$NB_ACTIVE_PROFILE_FILE"
nb_profile_gc_orphans || fail "GC retry failed"
[ ! -d "$NB_PROFILES_ROOT/profile-b" ] || fail "inactive orphan was not collected on retry"

# A stock row of another provider must not authorize a NetBird identity dir.
mkdir -p "$NB_PROFILES_ROOT/other"
printf '{}\n' > "$NB_PROFILES_ROOT/other/default.json"
UCI_NON_NETBIRD=1
nb_profile_gc_orphans || fail "GC failed for non-NetBird stock row"
[ ! -d "$NB_PROFILES_ROOT/other" ] || fail "non-NetBird row incorrectly retained NetBird identity"

# Setup keys must never enter persistent provider state.
if grep -R -E 'setup[_-]?key=' "$NB_ROOT" >/dev/null 2>&1; then
    fail "setup key leaked into persistent profile storage"
fi

# Provider state is allowed only below profiles/<stock-key>/.
[ ! -e "$NB_ROOT/default.json" ] || fail "root-level identity was created"
[ ! -e "$NB_ROOT/settings" ] || fail "root-level settings were created"
[ ! -e "$NB_ROOT/state" ] || fail "root-level state directory was created"

echo "netbird stock-authority/profile-isolation/orphan-GC behavior ok"
