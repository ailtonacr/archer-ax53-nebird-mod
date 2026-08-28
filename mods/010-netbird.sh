#!/bin/bash -e
#
# 010-netbird.sh -- integrate NetBird (0.77.1) as a VPN Client on AX53.
#
# Installs: init service, control CLI, xzmini decoder, LuCI backend (source
# .lua), patched VPN Client frontend, firewall rules, factory-reset cleanup
# and boot enable symlink.
# The NetBird binary is NOT embedded in rootfs and NOT stored on any MTD/UBI
# partition; it is downloaded over HTTPS and materialized into /tmp at runtime.

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
WEB_PATCHER="$PROJECT_ROOT/src/web/patchnetbird_web.py"

echo "### NetBird backend/service/frontend integration ###"

echo "[1/7] copying NetBird runtime files into rootfs ..."
# The large NetBird ELF is deliberately absent here. Runtime materialization
# downloads the pinned XZ payload to /tmp; only the tiny wrapper/decoder and
# integration files belong in squashfs.
(cd "$FILES" && cp -a --parents lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini \
   etc/init.d/netbird usr/lib/lua/luci/controller/admin/netbird.lua \
   usr/lib/lua/luci/model/netbird.lua "$PROJECT_ROOT/$R/")
chmod 0755 "$R/sbin/netbird-ctl" "$R/sbin/xzmini" "$R/etc/init.d/netbird" 2>/dev/null || true
chmod 0644 "$R/lib/netbird/netbird.sh" "$R/usr/lib/lua/luci/controller/admin/netbird.lua" "$R/usr/lib/lua/luci/model/netbird.lua" 2>/dev/null || true

echo "[2/7] patching VPN Client frontend ..."
[ -f "$WEB_PATCHER" ] || { echo "Error: missing $WEB_PATCHER" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required for frontend patching" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Error: node is required for frontend syntax validation" >&2; exit 1; }
python3 "$WEB_PATCHER" "$PROJECT_ROOT/$R"

echo "[3/7] adding CIDR-scoped fw_netbird_access/block ..."
# Append a v2 override even when an older NetBird function already exists in a
# previously patched rootfs. Shell uses the last function definition, which
# makes this idempotent and safely upgrades broad wt0<->LAN rules.
if ! grep -q "# NetBird v2 CIDR-scoped" "$R/lib/firewall/tpcmd.sh" 2>/dev/null; then
  cat >> "$R/lib/firewall/tpcmd.sh" <<'EOF'

# NetBird v2 CIDR-scoped -- later definition intentionally overrides v1.
fw_netbird_access(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    fw_s_add 4 f INPUT ACCEPT 1 { "-p udp -m udp --dport $port" }
    fw_s_add 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_add 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }

    # Remove legacy broad forwarding before installing scoped rules.
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }

    if [ "$access" == "lan" ] && [ -n "$cidr" ]; then
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i wt0 -o $homeif -d $cidr" }
        fw_s_add 4 f FORWARD ACCEPT 1 { "-i $homeif -o wt0 -s $cidr" }
        fw_s_add 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
}

fw_netbird_block(){
    local port=$1
    local access=$2
    local homeif="$(uci_get_state firewall core lan_ifname)"
    local cidr="$(sed -n 's/^advertise_cidr=//p' /tp_data/netbird/settings 2>/dev/null | head -n 1)"

    fw_s_del 4 f INPUT ACCEPT { "-p udp -m udp --dport $port" }
    fw_s_del 4 f INPUT ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -m conntrack --ctstate ESTABLISHED,RELATED" }
    if [ -n "$cidr" ]; then
        fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif -d $cidr" }
        fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0 -s $cidr" }
        fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10 -d $cidr" }
    fi
    fw_s_del 4 f FORWARD ACCEPT { "-i wt0 -o $homeif" }
    fw_s_del 4 f FORWARD ACCEPT { "-i $homeif -o wt0" }
    fw_s_del 4 n POSTROUTING MASQUERADE { "-o $homeif -s 100.64.0.0/10" }
}
EOF
else
  echo "    (CIDR-scoped override already present, skipping)"
fi

echo "[4/7] wiring netbird_access|netbird_block into /sbin/fw ..."
if ! grep -q "netbird_access" "$R/sbin/fw" 2>/dev/null; then
  sed -i 's#openvpnc_access|openvpnc_block)#openvpnc_access|openvpnc_block|netbird_access|netbird_block)#' "$R/sbin/fw"
  grep -q "netbird_access" "$R/sbin/fw" || {
    echo "    fallback: patching via explicit replace"
    perl -0pi -e 's/(vpnc_access_accel_handle\|vpnc_block_accel_handle\|openvpnc_access\|openvpnc_block\))/$1|netbird_access|netbird_block)/' "$R/sbin/fw"
  }
else
  echo "    (already present, skipping)"
fi

echo "[5/7] factory-reset cleanup in /sbin/reset ..."
if ! grep -q "tp_data/netbird" "$R/sbin/reset" 2>/dev/null; then
  sed -i 's#^sleep 3$#rm -rf /tp_data/netbird\nsleep 3#' "$R/sbin/reset"
fi

echo "[6/7] enabling service (rc.d S99netbird) ..."
mkdir -p "$R/etc/rc.d"
ln -sfn "../init.d/netbird" "$R/etc/rc.d/S99netbird" 2>/dev/null || true

echo "[7/7] verifying installed files ..."
for f in lib/netbird/netbird.sh sbin/netbird-ctl sbin/xzmini etc/init.d/netbird \
         usr/lib/lua/luci/controller/admin/netbird.lua usr/lib/lua/luci/model/netbird.lua \
         www/webpages/js/VpnServerNetbirdForm-NB.js.gz; do
  [ -f "$R/$f" ] && echo "    ok  $f" || { echo "    MISSING $f" >&2; exit 1; }
done

echo "### NetBird backend/service/frontend integration complete ###"
