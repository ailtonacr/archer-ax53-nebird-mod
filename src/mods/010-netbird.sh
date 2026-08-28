#!/bin/bash -e
# Compatibility entry point for older documentation/tooling.
#
# The authoritative build mod is ../../mods/010-netbird.sh, which implements
# the current R2 -> /tmp runtime and frontend patching. Keep this wrapper so
# historical paths do not silently run the retired netbird_data/NAND design.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec "$PROJECT_ROOT/mods/010-netbird.sh" "$@"
