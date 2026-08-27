#!/bin/bash -e

# Pin repo root -- mods/ is one level below the project root, and this
# script needs to work both invoked directly (./mods/001-telnet.sh from
# anywhere) and via apply-mods.sh, so it can't assume cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "##### Enabling telnet permanently ... #####"

# check if extracted
if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "squashfs-root" ]; then
    ROOTFS_DIR="squashfs-root"
  elif [ -d "rootfs" ]; then
    ROOTFS_DIR="rootfs"
  else
    echo "Error: neither 'squashfs-root' nor 'rootfs' directory found!"
    echo "Please run an unpack script first."
    exit 1
  fi
fi

echo "Installing /etc/init.d/telnet (stock, conditional start)..."
mkdir -p "$ROOTFS_DIR/etc/init.d"
cp -a "$SCRIPT_DIR/001-telnet-files/etc/init.d/telnet" "$ROOTFS_DIR/etc/init.d/telnet"

# Ensure the script remains executable
chmod +x "$ROOTFS_DIR/etc/init.d/telnet"

echo "Creating auto-start symlink in /etc/rc.d..."
mkdir -p "$ROOTFS_DIR/etc/rc.d"
# Use -sf to forcefully create the symlink even if a broken one exists
ln -sf ../init.d/telnet "$ROOTFS_DIR/etc/rc.d/S50telnet"

echo "==================================="
echo "Success! Telnet is permanently enabled without password"
