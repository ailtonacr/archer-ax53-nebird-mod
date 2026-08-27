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

echo "Patching /etc/init.d/telnet to bypass SSH/password checks..."
cat << 'EOF' > "$ROOTFS_DIR/etc/init.d/telnet"
#!/bin/sh /etc/rc.common
# Copyright (C) 2006-2011 OpenWrt.org

START=50

has_root_pwd() {
        local pwd=$([ -f "$1" ] && cat "$1")
              pwd="${pwd#*root:}"
              pwd="${pwd%%:*}"
        test -n "${pwd#[\!x]}"
}

get_root_home() {
        local homedir=$([ -f "$1" ] && cat "$1")
        homedir="${homedir#*:*:0:0:*:}"

        echo "${homedir%%:*}"
}

has_ssh_pubkey() {
        ( /etc/init.d/dropbear enabled 2> /dev/null && grep -qs "^ssh-" /etc/dropbear/authorized_keys ) || \
        ( /etc/init.d/sshd enabled 2> /dev/null && grep -qs "^ssh-" "$(get_root_home /etc/passwd)"/.ssh/authorized_keys )
}

start() {
        # Unconditionally start telnet and bind it to the standard OpenWrt shell wrapper
        service_start /usr/sbin/telnetd -l /bin/login.sh
}

stop() {
        service_stop /usr/sbin/telnetd
}
EOF

# Ensure the script remains executable
chmod +x "$ROOTFS_DIR/etc/init.d/telnet"

echo "Creating auto-start symlink in /etc/rc.d..."
mkdir -p "$ROOTFS_DIR/etc/rc.d"
# Use -sf to forcefully create the symlink even if a broken one exists
ln -sf ../init.d/telnet "$ROOTFS_DIR/etc/rc.d/S50telnet"

echo "==================================="
echo "Success! Telnet is permanently enabled without password"
