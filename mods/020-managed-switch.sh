#!/bin/bash -e

ROOTFS_DIR="${ROOTFS_DIR:-rootfs}"
FILES_DIR="$(cd "$(dirname "$0")" && pwd)/020-managed-switch-files"

[ -d "$ROOTFS_DIR" ] || { echo "Error: ROOTFS_DIR not found: $ROOTFS_DIR" >&2; exit 1; }
[ -d "$FILES_DIR" ] || { echo "Error: managed-switch files not found: $FILES_DIR" >&2; exit 1; }

install -D -m 0755 "$FILES_DIR/usr/sbin/managed-switch" "$ROOTFS_DIR/usr/sbin/managed-switch"
install -D -m 0755 "$FILES_DIR/etc/init.d/managed-switch" "$ROOTFS_DIR/etc/init.d/managed-switch"
install -D -m 0644 "$FILES_DIR/etc/config/managed_switch" "$ROOTFS_DIR/etc/config/managed_switch"

mkdir -p "$ROOTFS_DIR/etc/rc.d"
ln -sf ../init.d/managed-switch "$ROOTFS_DIR/etc/rc.d/S98managed-switch"

echo "Managed-switch tooling installed (disabled by default)."
