#!/bin/sh
# Profile-scoped persistence helpers for native NetBird VPN Client profiles.
#
# TP-Link's stock vpn.server row is the profile authority. Multiple NetBird
# rows may coexist, but only the selected stock VPN Client profile is active.
# Each persisted row therefore gets its own NetBird identity/settings directory:
#
#   /tp_data/netbird/profiles/<stock-profile-key>/
#
# Historical single-profile files directly under /tp_data/netbird are migration
# input. The adoption marker distinguishes an intentional provider deletion from
# a stock-config loss/firmware migration so an installed legacy client can be
# restored to the native list without resurrecting a profile the user deleted.

NB_LEGACY_ROOT="${NB_LEGACY_ROOT:-/tp_data/netbird}"
NB_PROFILES_ROOT="${NB_PROFILES_ROOT:-$NB_LEGACY_ROOT/profiles}"
NB_ACTIVE_PROFILE_FILE="${NB_ACTIVE_PROFILE_FILE:-/tmp/netbird-active-profile}"
NB_LEGACY_ADOPTION_FILE="${NB_LEGACY_ADOPTION_FILE:-$NB_LEGACY_ROOT/legacy-adoption}"
NB_PROFILE_KEY="${NB_PROFILE_KEY:-}"

nb_profile_key_valid() {
    local key="${1:-}"
    [ -n "$key" ] || return 1
    [ "${#key}" -le 96 ] || return 1
    case "$key" in
        *[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    return 0
}

nb_profile_use_legacy() {
    NB_PROFILE_KEY=""
    NB_CONFIG_DIR="$NB_LEGACY_ROOT"
    NB_STATE_DIR="$NB_CONFIG_DIR/state"
    NB_CONFIG_FILE="$NB_CONFIG_DIR/default.json"
    NB_SETTINGS_FILE="$NB_CONFIG_DIR/settings"
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
    [ -s "$NB_CONFIG_FILE" ] || return 1
    return 0
}

# The stock vpn.server row is the authority for whether a profile exists.
nb_profile_stock_exists() {
    local key="${1:-}" section_type profile_type
    nb_profile_key_valid "$key" || return 1
    section_type="$(uci -q get "vpn.$key" 2>/dev/null || true)"
    profile_type="$(uci -q get "vpn.$key.type" 2>/dev/null || true)"
    [ "$section_type" = "server" ] && [ "$profile_type" = "netbirdvpn" ]
}

nb_legacy_adoption_key() {
    local key
    [ -f "$NB_LEGACY_ADOPTION_FILE" ] || return 1
    key="$(nb_get "$NB_LEGACY_ADOPTION_FILE" profile_key "")"
    nb_profile_key_valid "$key" || return 1
    printf '%s\n' "$key"
}

nb_legacy_mark_profile_deleted() {
    local key="${1:-}" adopted
    nb_profile_key_valid "$key" || return 0
    adopted="$(nb_legacy_adoption_key 2>/dev/null || true)"
    [ -n "$adopted" ] && [ "$adopted" = "$key" ] || return 0
    nb_set "$NB_LEGACY_ADOPTION_FILE" deleted 1
}

# Completion is authoritative only while the adopted stock row still exists, or
# after an explicit provider cleanup marked it intentionally deleted. If the
# stock configuration disappears without that tombstone (for example across a
# firmware/config migration), the persistent identity is eligible for adoption
# again so the installed client becomes visible in the stock list.
nb_legacy_adoption_done() {
    local key
    [ -f "$NB_LEGACY_ADOPTION_FILE" ] || return 1
    [ "$(nb_get "$NB_LEGACY_ADOPTION_FILE" completed "0")" = "1" ] || return 1
    [ "$(nb_get "$NB_LEGACY_ADOPTION_FILE" deleted "0")" = "1" ] && return 0
    key="$(nb_legacy_adoption_key 2>/dev/null || true)"
    [ -n "$key" ] && nb_profile_stock_exists "$key" && return 0
    return 1
}

# Fallback cleanup for profiles removed outside the normal web flow or when the
# immediate provider post-DELETE cleanup failed. Never delete the currently
# selected runtime profile. The normal UI path cleans provider identity
# immediately after TP-Link's stock DELETE succeeds.
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
        nb_legacy_mark_profile_deleted "$key"
    done
    return 0
}

nb_legacy_artifacts_present() {
    [ -s "$NB_LEGACY_ROOT/default.json" ] || \
    [ -f "$NB_LEGACY_ROOT/settings" ] || \
    [ -d "$NB_LEGACY_ROOT/state" ]
}

nb_url_host() {
    printf '%s' "${1:-}" | sed -e 's#^[A-Za-z][A-Za-z0-9+.-]*://##' -e 's#/.*$##' -e 's/:[0-9][0-9]*$//'
}

nb_legacy_profile_find_section() {
    uci -q show vpn 2>/dev/null | \
        sed -n "s/^vpn\.\([^.=]*\)\.legacy_identity='1'$/\1/p" | head -n 1
}

nb_legacy_profile_allocate_section() {
    local preferred="" base="netbird_legacy" section n=0
    preferred="$(nb_legacy_adoption_key 2>/dev/null || true)"
    if [ -n "$preferred" ] && ! uci -q get "vpn.$preferred" >/dev/null 2>&1; then
        printf '%s\n' "$preferred"
        return 0
    fi
    section="$base"
    while uci -q get "vpn.$section" >/dev/null 2>&1; do
        n=$((n + 1))
        section="${base}${n}"
    done
    printf '%s\n' "$section"
}

# Adopt the historical single NetBird identity into the native stock list. The
# operation is idempotent while its row exists. If stock config is lost without
# a provider-deletion tombstone it reuses the recorded key when available.
nb_legacy_profile_adopt() {
    nb_legacy_adoption_done && return 0
    nb_legacy_artifacts_present || return 0
    uci -q show vpn >/dev/null 2>&1 || return 0

    local section management description server key value copied=0
    section="$(nb_legacy_profile_find_section)"
    if ! nb_profile_key_valid "$section"; then
        section="$(nb_legacy_profile_allocate_section)"
    fi
    nb_profile_key_valid "$section" || return 1

    management="$(nb_get "$NB_LEGACY_ROOT/settings" management_url "$NB_DEFAULT_MGMT")"
    description="$(nb_get "$NB_LEGACY_ROOT/settings" description "NetBird")"
    server="$(nb_url_host "$management")"

    uci set "vpn.$section=server" || return 1
    uci set "vpn.$section.type=netbirdvpn" || return 1
    uci set "vpn.$section.description=$description" || return 1
    uci set "vpn.$section.management_url=$management" || return 1
    uci set "vpn.$section.server=$server" || return 1
    uci set "vpn.$section.profile_key=$section" || return 1
    uci set "vpn.$section.legacy_identity=1" || return 1

    for key in hostname disable_dns disable_firewall disable_client_routes disable_server_routes disable_ipv6 network_monitor advertise_lan advertise_cidr wireguard_port; do
        value="$(nb_get "$NB_LEGACY_ROOT/settings" "$key" "")"
        [ -n "$value" ] || {
            case "$key" in
                disable_dns|disable_firewall|disable_client_routes|disable_server_routes|disable_ipv6) value="1" ;;
                network_monitor|advertise_lan) value="0" ;;
                wireguard_port) value="$NB_DEFAULT_PORT" ;;
                *) value="" ;;
            esac
        }
        uci set "vpn.$section.$key=$value" || return 1
    done
    uci commit vpn || return 1

    mkdir -p "$NB_PROFILES_ROOT/$section" || return 1
    chmod 0700 "$NB_LEGACY_ROOT" "$NB_PROFILES_ROOT" "$NB_PROFILES_ROOT/$section" 2>/dev/null || true
    if [ -f "$NB_LEGACY_ROOT/settings" ]; then
        cp -p "$NB_LEGACY_ROOT/settings" "$NB_PROFILES_ROOT/$section/settings" || return 1
        copied=1
    fi
    if [ -s "$NB_LEGACY_ROOT/default.json" ]; then
        cp -p "$NB_LEGACY_ROOT/default.json" "$NB_PROFILES_ROOT/$section/default.json" || return 1
        copied=1
    fi
    if [ -d "$NB_LEGACY_ROOT/state" ]; then
        mkdir -p "$NB_PROFILES_ROOT/$section/state" || return 1
        cp -a "$NB_LEGACY_ROOT/state/." "$NB_PROFILES_ROOT/$section/state/" || return 1
        copied=1
    fi

    nb_profile_select "$section" || return 1
    nb_ensure_settings
    [ -s "$NB_CONFIG_FILE" ] && nb_set "$NB_SETTINGS_FILE" enrolled 1
    nb_set "$NB_SETTINGS_FILE" enable 0
    nb_profile_use_legacy

    umask 077
    {
        printf 'completed=1\n'
        printf 'deleted=0\n'
        printf 'profile_key=%s\n' "$section"
        printf 'copied=%s\n' "$copied"
    } > "$NB_LEGACY_ADOPTION_FILE.new" || return 1
    chmod 0600 "$NB_LEGACY_ADOPTION_FILE.new" 2>/dev/null || true
    mv -f "$NB_LEGACY_ADOPTION_FILE.new" "$NB_LEGACY_ADOPTION_FILE"
    return 0
}

# Preserve the historical default context for callers that do not explicitly
# select a profile (payload diagnostics, migration and compatibility tooling).
nb_profile_use_legacy
