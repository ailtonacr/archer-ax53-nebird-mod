#!/bin/bash -e
#
# 011-devssh.sh -- enable the validated development SSH (dropbear :2222) in the
# AX53 rootfs, independent of the stock /etc/init.d/dropbear.
#
# Reuses the exact implementation proven on real hardware (DEV-01 / netbird-prune
# builds): dropbear LAN-only, TCP 2222, public-key only, no password, no
# forwarding, no IPv6, ephemeral host key under /tmp, START=55.
#
# The authorized_keys file contains ONLY the public key (~/.ssh/ax53_dev.pub).
# No private key is ever placed in the firmware.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "squashfs-root" ]; then ROOTFS_DIR="squashfs-root"
  elif [ -d "rootfs" ]; then ROOTFS_DIR="rootfs"
  else echo "Error: no rootfs dir" >&2; exit 1; fi
fi

FILES="$SCRIPT_DIR/011-devssh-files"
R="$ROOTFS_DIR"

echo "### Dev SSH (dropbear :2222, key-only, LAN) ###"

echo "[1/3] copying devssh init + authorized_keys ..."
(cd "$FILES" && cp -a --parents etc/init.d/devssh etc/dropbear/authorized_keys "$PROJECT_ROOT/$R/")
chmod 0755 "$R/etc/init.d/devssh"
chmod 0600 "$R/etc/dropbear/authorized_keys"

echo "[2/3] enabling service (rc.d S55devssh) ..."
mkdir -p "$R/etc/rc.d"
ln -sfn "../init.d/devssh" "$R/etc/rc.d/S55devssh"

echo "[3/3] verifying ..."
for f in etc/init.d/devssh etc/dropbear/authorized_keys etc/rc.d/S55devssh; do
  [ -e "$R/$f" ] && echo "    ok $f" || { echo "    MISSING $f" >&2; exit 1; }
done

echo "### Dev SSH enabled ###"