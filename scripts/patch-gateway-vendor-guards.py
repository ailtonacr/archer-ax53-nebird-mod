#!/usr/bin/env python3
"""Install exact-anchor guards in the extracted vendor root, not the Git stock snapshot."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
marker = "# AX53_GATEWAY_VENDOR_GUARD_V1"
source = '. /usr/lib/gateway-failover/vendor-guard.sh'
guard = 'ax53_vendor_allowed || { logger -t ax53-switch "vendor writer blocked by gateway policy"; return 1; }'
exitguard = 'ax53_vendor_allowed || { lock -u /var/run/switch-set.lock; logger -t ax53-switch "vendor VLAN writer blocked"; exit 1; }'

def patch(path, edits):
    target = root / path
    text = target.read_text()
    for anchor, replacement in edits:
        if replacement in text:
            continue
        if text.count(anchor) != 1:
            raise SystemExit("vendor guard anchor mismatch: " + path + ": " + repr(anchor))
        text = text.replace(anchor, replacement, 1)
    target.write_text(text)

# This hook is called directly by IPTV as well as via hotplug-call.
# Do not run custom apply from here: it would nest the vendor lock.
patch("etc/hotplug.d/switch/65-iptv", [
    ("lock /var/run/switch-set.lock\n", "lock /var/run/switch-set.lock\n" + marker + "\n" + source + "\n" + exitguard + "\n"),
])
# Block the other observed entrypoints before mutation. These guards are not
# proof that all proprietary writers are covered; auto is still gated.
patch("etc/init.d/switch", [
    ("start() {\n", "start() {\n    " + marker + "\n    " + source + "\n    " + guard + "\n"),
    ("stop() {\n", "stop() {\n    " + marker + "\n    " + source + "\n    " + guard + "\n"),
])
patch("lib/iptv/iptv_core.sh", [
    (name + "()\n{\n", name + "()\n{\n    " + marker + "\n    " + source + "\n    " + guard + "\n")
    for name in ("iptv_start", "iptv_stop", "iptv_restart")
])
