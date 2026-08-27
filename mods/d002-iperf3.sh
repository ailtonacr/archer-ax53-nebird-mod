#!/bin/bash -e

# Pin repo root -- see 001-telnet.sh for why.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== TP-Link AX53 iperf3 RAM-Bootstrap Injector ==="

# Ensure the project has been unpacked
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

echo "[1/2] Injecting non-blocking background fetcher into /etc/init.d/iperf3..."
cat << 'EOF' > "$ROOTFS_DIR/etc/init.d/iperf3"
#!/bin/sh /etc/rc.common
# Copyright (C) 2006-2011 OpenWrt.org

START=99

start_iperf_bg() {
        echo "iperf3: Waiting for WAN internet connectivity..."
        
        local retries=0
        while ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; do
                retries=$((retries + 1))
                if [ "$retries" -gt 36 ]; then
                        echo "iperf3: WAN timeout after 3 minutes. Aborting fetch."
                        return 1
                fi
                sleep 5
        done

        echo "iperf3: WAN online! Fetching static binary into RAM (/tmp)..."
        local url="https://github.com/userdocs/iperf3-static/releases/latest/download/iperf3-arm32v7"
        
        if command -v curl >/dev/null 2>&1; then
                curl -k -fLo /tmp/iperf3 "$url"
        elif command -v wget >/dev/null 2>&1; then
                # Fallback for HTTP-only mirrors; BusyBox wget can't do HTTPS
                wget -qO /tmp/iperf3 "$url"
        else
                echo "iperf3: Error - Neither curl nor wget found on router!"
                return 1
        fi

        if [ -s /tmp/iperf3 ]; then
                chmod +x /tmp/iperf3
                echo "iperf3: Download complete. Starting server daemon..."
                /tmp/iperf3 -s -D
        else
                echo "iperf3: Download failed or file is empty."
                rm -f /tmp/iperf3 2>/dev/null
        fi
}

start() {
        # CRITICAL: Must be sent to background (&) so it doesn't freeze the router boot sequence!
        start_iperf_bg &
}

stop() {
        killall iperf3 2>/dev/null
        rm -f /tmp/iperf3 2>/dev/null
}
EOF

chmod +x "$ROOTFS_DIR/etc/init.d/iperf3"

echo "[2/2] Creating auto-start symlink in /etc/rc.d..."
mkdir -p "$ROOTFS_DIR/etc/rc.d"
ln -sf ../init.d/iperf3 "$ROOTFS_DIR/etc/rc.d/S99iperf3"

echo "==================================="
echo "Success! iperf3 RAM-bootstrap service installed (~800 bytes)."
echo "You can now run a repack script without exceeding flash budget!"
