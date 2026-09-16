#!/bin/bash -e
#
# Enable the validated development SSH service (dropbear :2222), independent
# of the vendor dropbear service. It binds only to the current LAN address.
#
# Public-key login is proven on real hardware. Password authentication keeps
# the vendor/system-account path intact; no password is embedded by this mod.
# The host key is ephemeral under /tmp and forwarding is disabled.
#
# authorized_keys contains only a public key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "rootfs" ]; then ROOTFS_DIR="$PROJECT_ROOT/rootfs"
  elif [ -d "squashfs-root" ]; then ROOTFS_DIR="$PROJECT_ROOT/squashfs-root"
  else echo "Error: no rootfs dir" >&2; exit 1; fi
else
  case "$ROOTFS_DIR" in
    /*) ;;
    *) ROOTFS_DIR="$PROJECT_ROOT/$ROOTFS_DIR" ;;
  esac
fi
[ -d "$ROOTFS_DIR" ] || { echo "Error: rootfs does not exist: $ROOTFS_DIR" >&2; exit 1; }

FILES="$SCRIPT_DIR/011-devssh-files"
R="$ROOTFS_DIR"

echo "### Dev SSH (dropbear :2222, LAN only) ###"
echo "    rootfs: $R"

echo "[1/3] copying init + authorized_keys ..."
(cd "$FILES" && cp -a --parents etc/init.d/devssh etc/dropbear/authorized_keys "$R/")
chmod 0755 "$R/etc/init.d/devssh"
chmod 0600 "$R/etc/dropbear/authorized_keys"

echo "[2/3] enabling S55devssh ..."
mkdir -p "$R/etc/rc.d"
ln -sfn "../init.d/devssh" "$R/etc/rc.d/S55devssh"

echo "[3/3] verifying ..."
for f in etc/init.d/devssh etc/dropbear/authorized_keys etc/rc.d/S55devssh; do
  [ -e "$R/$f" ] || { echo "Missing $f" >&2; exit 1; }
done

grep -Eq '^[[:space:]]*-L[[:space:]\\]*$' "$R/etc/init.d/devssh" || {
  echo "Error: devssh must allow SSH sessions (-L)" >&2
  exit 1
}
if grep -Eq '^[[:space:]]*-C[[:space:]\\]*$' "$R/etc/init.d/devssh"; then
  echo "Error: -C would replace the vendor account path" >&2
  exit 1
fi

echo "### Dev SSH enabled ###"
