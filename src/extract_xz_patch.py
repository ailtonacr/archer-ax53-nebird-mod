#!/usr/bin/env python3
"""
extract_xz_patch.py <input.ubifs> <output_dir>

Runs ubireader's extract_files with a runtime monkey-patch applied to
ubireader.ubifs.misc.decompress, correcting for this vendor kernel's
UBIFS compression type reuse: type ID 3 (mainline = zstd) is actually
XZ on this device (TP-Link AX53 / IPQ5018-family, confirmed via direct
byte inspection — real files start with the genuine XZ container magic
FD 37 7A 58 5A 00).

This patch lives here, in the project repo, and is applied in-memory
at runtime — it never touches ubi_reader's own source.

--- Self-contained loading ---
ubi_reader is loaded from vendor/ubi_reader/src/ubi_reader-<version>/ in
this repo, NOT from a pip-installed package on PATH/site-packages. This
means the exact ubi_reader source this project depends on is pinned and
versioned in-repo (see vendor/ubi_reader/README.md for the upstream
version, sha256, and license), the same way vendor/mtd-utils/ pins the
mtd-utils source. Override with UBIREADER_SRC_OVERRIDE=/path/to/src if
you need to test against a different checkout.

NOTE this does NOT eliminate every external dependency: ubi_reader's own
ubireader/ubifs/misc.py unconditionally imports lzallright, zstandard,
and cryptography at module load time (compiled packages, not pure
Python), and those still have to be importable from wherever this script
runs -- see vendor/ubi_reader/README.md for what that currently means in
practice and options for going further (vendoring pinned wheels).
fakeroot is a separate, non-Python system dependency and isn't addressed
by any of this.

Also builds a manifest (xz_chunks_manifest.txt) logging every chunk
where the XZ interception actually fired, for audit purposes — see the
note in the project conversation about why this isn't strictly required
for repacking to work (mkfs.ubifs recompresses fresh from plain input
regardless of the original file's compression state), but is still
useful to keep around.
"""
import sys
import os
import runpy
import lzma
from pathlib import Path

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input.ubifs> <output_dir>", file=sys.stderr)
    sys.exit(1)

# --- Locate and load the vendored ubi_reader source ---
# This file lives at <repo>/src/extract_xz_patch.py, so the repo root is
# one level up. Adjust UBIREADER_VERSION if vendor/ubi_reader/ is ever
# re-pinned to a different upstream release.
REPO_ROOT = Path(__file__).resolve().parent.parent
UBIREADER_VERSION = "0.8.14"
DEFAULT_UBIREADER_SRC = REPO_ROOT / "vendor" / "ubi_reader" / "src" / f"ubi_reader-{UBIREADER_VERSION}"
UBIREADER_SRC = Path(os.environ.get("UBIREADER_SRC_OVERRIDE", DEFAULT_UBIREADER_SRC))

if not (UBIREADER_SRC / "ubireader").is_dir():
    print(f"Error: vendored ubi_reader source not found at {UBIREADER_SRC}", file=sys.stderr)
    print("       See vendor/ubi_reader/README.md to (re)populate it, or set", file=sys.stderr)
    print("       UBIREADER_SRC_OVERRIDE=/path/to/ubi_reader/src to point elsewhere.", file=sys.stderr)
    sys.exit(1)

sys.path.insert(0, str(UBIREADER_SRC))

try:
    import ubireader.ubifs.misc as misc
except ImportError as e:
    print(f"Error: found vendored source at {UBIREADER_SRC} but couldn't import it: {e}", file=sys.stderr)
    print("       This is almost certainly one of ubi_reader's own compiled deps", file=sys.stderr)
    print("       (lzallright / zstandard / cryptography) missing from this Python", file=sys.stderr)
    print("       environment -- vendoring the ubi_reader source doesn't vendor", file=sys.stderr)
    print("       those. See vendor/ubi_reader/README.md.", file=sys.stderr)
    sys.exit(1)
# -------------------------------------------------------

# Confirmed real signature: decompress(ctype, unc_len, data)
# (verify yourself: grep -n "^def decompress" vendor/ubi_reader/src/ubi_reader-*/ubireader/ubifs/misc.py)
_original_decompress = misc.decompress

_XZ_MAGIC = bytes.fromhex('fd377a585a00')
_manifest_lines = []
_xz_hits = 0
_total_calls = 0


def _patched_decompress(ctype, unc_len, data):
    global _xz_hits, _total_calls
    _total_calls += 1

    if ctype == 3 and isinstance(data, (bytes, bytearray)) and data[:6] == _XZ_MAGIC:
        try:
            out = lzma.decompress(data, format=lzma.FORMAT_XZ)
            _xz_hits += 1
            _manifest_lines.append(f"ctype=3(xz) compressed_len={len(data)} decompressed_len={len(out)}")
            return out
        except Exception as e:
            try:
                dec = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
                out = dec.decompress(data)
                _xz_hits += 1
                _manifest_lines.append(
                    f"ctype=3(xz,incremental) compressed_len={len(data)} "
                    f"decompressed_len={len(out)} unused_data_len={len(dec.unused_data)}"
                )
                return out
            except Exception as e2:
                print(f"[!] XZ decompress failed even with incremental fallback: {e2}", file=sys.stderr)
                # fall through to original behavior below

    return _original_decompress(ctype, unc_len, data)


misc.decompress = _patched_decompress

# -k/--keep-permissions: without this, ubireader's extract_dents() runs
# with perms=False and never calls chmod/chown at all -- every extracted
# file (not just device/socket special files) lands at the umask default
# instead of its real UBIFS inode mode. This is what was stripping +x off
# every script in rootfs/. Must be paired with fakeroot (applied in
# 01-unpack.sh) since setting uid/gid back to their real values (usually
# 0:0) requires root privileges ubireader doesn't have otherwise.
sys.argv = ['ubireader_extract_files', '-k', sys.argv[1], '-o', sys.argv[2]]

try:
    # Runs the vendored ubireader/scripts/ubireader_extract_files.py's
    # main() exactly as the pip-installed console-script entry point
    # would, just resolved via the vendored copy on sys.path instead of
    # an installed package -- no dependency on ubi_reader being pip
    # installed anywhere.
    runpy.run_module('ubireader.scripts.ubireader_extract_files', run_name='__main__')
finally:
    print(f"\n[extract_xz_patch] decompress() called {_total_calls} times, "
          f"XZ interception fired {_xz_hits} times", file=sys.stderr)
    with open('rootfs_xz_chunks_manifest.txt', 'w') as f:
        f.write(f"# Total decompress() calls: {_total_calls}\n")
        f.write(f"# XZ interception fired: {_xz_hits}\n")
        f.write("\n".join(_manifest_lines) + "\n")
        