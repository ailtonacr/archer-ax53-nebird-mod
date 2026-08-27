#!/bin/bash -e
#
# 010-netbird.sh -- integrate NetBird (0.77.1) as a VPN Client on AX53.
#
# Installs: init service, control CLI, xzmini decoder, LuCI backend (source
# .lua), firewall rules, factory-reset cleanup and boot enable symlink.
# The NetBird binary is NOT embedded in rootfs and NOT stored on any MTD/UBI
# partition; it is downloaded over HTTPS from a public Cloudflare R2 bucket and
# materialized into /tmp at runtime (see work/netbird-final/docs/R2-RUNTIME.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -z "${ROOTFS_DIR:-}" ]; then
  if [ -d "squashfs-root" ]; then ROOTFS_DIR="squashfs-root"
  elif [ -d "rootfs" ]; then ROOTFS_DIR="rootfs"
  else echo "Error: no rootfs dir" >&2; exit 1; fi
fi

FILES="$SCRIPT_DIR/010-netbird-files"
R="$ROOTFS_DIR"

echo "### NetBird backend/service integration ###"

# 1) copy the file tree
echo "[1/6] copying netbird files into rootfs ..."
(cd "$FILES" && cp -a --parents lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini usr/bin/netbird \
   etc/init.d/netbird usr/lib/lua/luci/controller/admin/netbird.lua \
   usr/lib/lua/luci/model/netbird.lua "$PROJECT_ROOT/$R/")
chmod 0755 "$R/sbin/netbird-ctl" "$R/sbin/xzmini" "$R/usr/bin/netbird" "$R/etc/init.d/netbird" 2>/dev/null || true
chmod 0644 "$R/lib/netbird/netbird.sh" "$R/usr/lib/lua/luci/controller/admin/netbird.lua" "$R/usr/lib/lua/luci/model/netbird.lua" 2>/dev/null || true

# 2) firewall functions into tpcmd.sh
echo "[2/6] adding fw_netbird_access/block to /lib/firewall/tpcmd.sh ..."
if ! grep -q "fw_netbird_access" "$R/lib/firewall/tpcmd.sh" 2>/dev/null; then
  cat >> "$R/lib/firewall/tpcmd.sh" <<'EOF'

# NetBird (wt0) -- minimal, explicit rules; no broad "-i wt0 -j ACCEPT".
fw_netbird_access(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"

    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    if [ "$access" == "lan" ]; then
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i wt0 -o $homeif" }
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i $homeif -o wt0" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    if [ "$access" == "lan" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
    fi
}
EOF
else
  echo "    (already present, skipping)"
fi

# 3) dispatch netbird_access/block in /sbin/fw
echo "[3/6] wiring netbird_access|netbird_block into /sbin/fw ..."
if ! grep -q "netbird_access" "$R/sbin/fw" 2>/dev/null; then
  sed -i 's#openvpnc_access|openvpnc_block)#openvpnc_access|openvpnc_block|netbird_access|netbird_block)#' "$R/sbin/fw"
  grep -q "netbird_access" "$R/sbin/fw" || {
    echo "    fallback: patching via explicit replace"
    perl -0pi -e 's/(vpnc_access_accel_handle\|vpnc_block_accel_handle\|openvpnc_access\|openvpnc_block\))/$1|netbird_access|netbird_block)/' "$R/sbin/fw"
  }
else
  echo "    (already present, skipping)"
fi

# 4) factory reset cleanup (remove config; payload is re-downloaded on demand)
echo "[4/6] factory-reset cleanup in /sbin/reset ..."
if ! grep -q "tp_data/netbird" "$R/sbin/reset" 2>/dev/null; then
  sed -i 's#^sleep 3$#rm -rf /tp_data/netbird\nsleep 3#' "$R/sbin/reset"
fi

# 5) boot enable symlink
echo "[5/6] enabling service (rc.d S99netbird) ..."
mkdir -p "$R/etc/rc.d"
ln -sfn "../init.d/netbird" "$R/etc/rc.d/S99netbird" 2>/dev/null || true

# 6) sanity
echo "[6/6] verifying installed files ..."
for f in lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini usr/bin/netbird etc/init.d/netbird \
         usr/lib/lua/luci/controller/admin/netbird.lua usr/lib/lua/luci/model/netbird.lua; do
  [ -f "$R/$f" ] && echo "    ok  $f" || { echo "    MISSING $f" >&2; exit 1; }
done

echo "### NetBird backend/service integration complete ###"
