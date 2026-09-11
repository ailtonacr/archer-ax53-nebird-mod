#!/bin/sh
# Profile-scoped persistence helpers for native NetBird VPN Client profiles.
#
# TP-Link's stock vpn.server row is the only profile authority. Multiple NetBird
# rows may coexist, but only the selected stock VPN Client profile is active.
# Each persisted row gets an isolated NetBird identity/settings directory:
#
#   /tp_data/netbird/profiles/<stock-profile-key>/
#
# there is intentionally no singleton/default profile context and no migration
# path from older NetBird integrations. A caller must select a real stock key
# before any profile-specific runtime operation.

NB_ROOT="${NB_ROOT:-/tp_data/netbird}"
NB_PROFILES_ROOT="${NB_PROFILES_ROOT:-$NB_ROOT/profiles}"
NB_ACTIVE_PROFILE_FILE="${NB_ACTIVE_PROFILE_FILE:-/tmp/netbird-active-profile}"
NB_PROFILE_KEY="${NB_PROFILE_KEY:-}"

nb_profile_clear_context() {
    NB_PROFILE_KEY=""
    NB_CONFIG_DIR=""
    NB_STATE_DIR=""
    NB_CONFIG_FILE=""
    NB_SETTINGS_FILE=""
}

nb_profile_key_valid() {
    local key="${1:-}"
    [ -n "$key" ] || return 1
    [ "${#key}" -le 96 ] || return 1
    case "$key" in
        *[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

nb_profile_select() {
    local key="${1:-}"
    nb_profile_key_valid "$key" || {
        echo "netbird: invalid profile key" >&2
        return 1
    }
    NB_PROFILE_KEY="$key"
    NB_CONFIG_DIR="$NB_PROFILES_ROOT/$key"
    NB_STATE_DIR="$NB_CONFIG_DIR/state"
    NB_CONFIG_FILE="$NB_CONFIG_DIR/default.json"
    NB_SETTINGS_FILE="$NB_CONFIG_DIR/settings"
    return 0
}

nb_profile_active_key() {
    local key=""
    if [ -f "$NB_ACTIVE_PROFILE_FILE" ]; then
        key="$(sed -n '1p' "$NB_ACTIVE_PROFILE_FILE" 2>/dev/null | tr -d '\r\n')"
        if nb_profile_key_valid "$key"; then
            printf '%s\n' "$key"
            return 0
        fi
    fi

    key="$(uci -q get network.vpn.profile_key 2>/dev/null || true)"
    if nb_profile_key_valid "$key"; then
        printf '%s\n' "$key"
        return 0
    fi
    return 1
}

nb_profile_select_active() {
    local key
    key="$(nb_profile_active_key 2>/dev/null)" || return 1
    nb_profile_select "$key"
}

nb_profile_mark_active() {
    nb_profile_key_valid "$NB_PROFILE_KEY" || return 1
    umask 077
    printf '%s\n' "$NB_PROFILE_KEY" > "$NB_ACTIVE_PROFILE_FILE.new" || return 1
    chmod 0600 "$NB_ACTIVE_PROFILE_FILE.new" 2>/dev/null || true
    mv -f "$NB_ACTIVE_PROFILE_FILE.new" "$NB_ACTIVE_PROFILE_FILE"
}

nb_profile_clear_active() {
    local active=""
    active="$(sed -n '1p' "$NB_ACTIVE_PROFILE_FILE" 2>/dev/null | tr -d '\r\n')"
    if [ -z "$NB_PROFILE_KEY" ] || [ "$active" = "$NB_PROFILE_KEY" ]; then
        rm -f "$NB_ACTIVE_PROFILE_FILE" "$NB_ACTIVE_PROFILE_FILE.new"
    fi
}

nb_profile_identity_present() {
    nb_profile_key_valid "$NB_PROFILE_KEY" || return 1
    [ -f "$NB_SETTINGS_FILE" ] || return 1
    [ "$(nb_get "$NB_SETTINGS_FILE" enrolled "0")" = "1" ] || return 1
    return 0
}

nb_enrollment_token_valid() {
    local token="${1:-}"
    [ "${#token}" -eq 32 ] || return 1
    case "$token" in
        *[!0-9a-f]*) return 1 ;;
    esac
    return 0
}

nb_staged_setup_key_path() {
    local token="${1:-}" path
    nb_enrollment_token_valid "$token" || return 1
    path="/tmp/netbird-setup-stage-$token"
    [ -s "$path" ] || return 1
    printf '%s\n' "$path"
}

nb_discard_staged_setup_key() {
    local token="${1:-}"
    nb_enrollment_token_valid "$token" || return 0
    rm -f "/tmp/netbird-setup-stage-$token"
}

nb_profile_clear_enrollment_token() {
    local key="${1:-$NB_PROFILE_KEY}" idx row_key row_type
    nb_profile_key_valid "$key" || return 1

    idx=0
    while :; do
        row_key="$(uci -q get "vpn.@server[$idx].key" 2>/dev/null)" || break
        row_type="$(uci -q get "vpn.@server[$idx].type" 2>/dev/null || true)"
        if [ "$row_key" = "$key" ] && [ "$row_type" = "netbirdvpn" ]; then
            uci -q delete "vpn.@server[$idx].enrollment_token" 2>/dev/null || true
            break
        fi
        idx=$((idx + 1))
    done

    uci -q delete protocol.netbirdvpn.enrollment_token 2>/dev/null || true
    uci -q delete network.vpn.enrollment_token 2>/dev/null || true
    uci commit vpn >/dev/null 2>&1 || return 1
    uci commit protocol >/dev/null 2>&1 || return 1
    uci commit network >/dev/null 2>&1 || return 1
    return 0
}

# The stock vpn.server row is authoritative for whether provider state is valid.
nb_profile_stock_exists() {
    local key="${1:-}" idx row_key row_type
    nb_profile_key_valid "$key" || return 1

    # TP-Link stores the public profile identity in the server option "key";
    # the UCI section itself is anonymous (@server[N]) and is not named by key.
    idx=0
    while :; do
        row_key="$(uci -q get "vpn.@server[$idx].key" 2>/dev/null)" || break
        row_type="$(uci -q get "vpn.@server[$idx].type" 2>/dev/null || true)"
        if [ "$row_key" = "$key" ] && [ "$row_type" = "netbirdvpn" ]; then
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

# Generic DELETE remains TP-Link-owned. Provider state whose authoritative stock
# row no longer exists is garbage-collected independently. Never remove the
# currently selected runtime profile during a transient lifecycle/config race.
nb_profile_gc_orphans() {
    [ -d "$NB_PROFILES_ROOT" ] || return 0
    local active="" dir key
    active="$(nb_profile_active_key 2>/dev/null || true)"

    for dir in "$NB_PROFILES_ROOT"/*; do
        [ -d "$dir" ] || continue
        key="${dir##*/}"
        nb_profile_key_valid "$key" || continue
        nb_profile_stock_exists "$key" && continue
        [ -n "$active" ] && [ "$active" = "$key" ] && continue
        rm -rf "$dir" || return 1
    done
    return 0
}

# Sourcing this helper must never leave root-level singleton paths as an implicit
# writable context inherited from netbird.sh.
nb_profile_clear_context
