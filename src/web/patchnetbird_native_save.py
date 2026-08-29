#!/usr/bin/env python3
"""Compatibility entrypoint for the native TP-Link form-contract patch.

Historical versions of this file manipulated/intercepted the visible Save
button. That strategy is retired. Keep this filename only because the firmware
mod pipeline already invokes it; delegate to patchnetbird_native_contract.py,
which exposes the stock isChanged/validate/getForm contract and leaves the
TP-Link dialog/button untouched.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOTFS = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
SCRIPT = pathlib.Path(__file__).with_name("patchnetbird_native_contract.py")

result = subprocess.run([sys.executable, str(SCRIPT), ROOTFS])
raise SystemExit(result.returncode)
