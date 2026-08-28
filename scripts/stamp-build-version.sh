#!/bin/bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/stamp-build-version.sh stamp <rootfs-dir> <build-number>
  scripts/stamp-build-version.sh advance <expected-build-number>
EOF
  exit 2
}

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_FILE="$PROJECT_ROOT/BUILD"

read_build() {
  test -f "$BUILD_FILE" || { echo "Error: BUILD file not found: $BUILD_FILE" >&2; exit 1; }
  local n
  n="$(tr -d '[:space:]' < "$BUILD_FILE")"
  case "$n" in
    ''|*[!0-9]*) echo "Error: BUILD must contain a positive integer, got: '$n'" >&2; exit 1 ;;
  esac
  [ "$n" -ge 1 ] || { echo "Error: BUILD must be >= 1" >&2; exit 1; }
  printf '%s\n' "$n"
}

command="${1:-}"
case "$command" in
  stamp)
    [ $# -eq 3 ] || usage
    rootfs="$2"
    build_no="$3"
    case "$build_no" in
      ''|*[!0-9]*) echo "Error: invalid build number: '$build_no'" >&2; exit 1 ;;
    esac
    [ "$build_no" -ge 1 ] || { echo "Error: build number must be >= 1" >&2; exit 1; }

    soft_file="$rootfs/etc/partition_config/soft-version"
    test -f "$soft_file" || { echo "Error: soft-version not found: $soft_file" >&2; exit 1; }

    current_soft="$(sed -n 's/^soft_ver://p' "$soft_file" | head -n1)"
    test -n "$current_soft" || { echo "Error: soft_ver missing from $soft_file" >&2; exit 1; }

    base_version="${current_soft%% *}"
    case "$base_version" in
      ''|*[!0-9A-Za-z._-]*) echo "Error: unexpected base soft version: '$base_version'" >&2; exit 1 ;;
    esac

    display_version="${base_version}-netbird mod Build ${build_no}"
    tmp_soft="${soft_file}.tmp.$$"
    awk -v version="$display_version" '
      BEGIN { replaced=0 }
      /^soft_ver:/ { print "soft_ver:" version; replaced=1; next }
      { print }
      END { if (!replaced) exit 42 }
    ' "$soft_file" > "$tmp_soft" || {
      rc=$?
      rm -f "$tmp_soft"
      echo "Error: could not rewrite soft_ver (awk rc=$rc)" >&2
      exit 1
    }
    mv "$tmp_soft" "$soft_file"

    commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    meta_file="$rootfs/etc/netbird-build"
    cat > "$meta_file" <<EOF
build=$build_no
base_version=$base_version
display_version=$display_version
git_commit=$commit
git_branch=$branch
built_at_utc=$built_at
EOF
    chmod 0644 "$meta_file"

    echo "Stamped firmware identity: $display_version"
    echo "Build metadata: /etc/netbird-build"
    ;;

  advance)
    [ $# -eq 2 ] || usage
    expected="$2"
    case "$expected" in
      ''|*[!0-9]*) echo "Error: invalid expected build number: '$expected'" >&2; exit 1 ;;
    esac

    current="$(read_build)"
    if [ "$current" != "$expected" ]; then
      echo "Error: BUILD changed during build (expected $expected, found $current); refusing to advance." >&2
      exit 1
    fi

    next=$((current + 1))
    tmp_build="${BUILD_FILE}.tmp.$$"
    printf '%s\n' "$next" > "$tmp_build"
    mv "$tmp_build" "$BUILD_FILE"
    echo "Next firmware build number: $next"
    ;;

  *)
    usage
    ;;
esac
