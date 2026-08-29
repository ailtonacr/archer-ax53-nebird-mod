#!/usr/bin/env python3
"""Execute the native frontend finalizer against an isolated rootfs fixture.

The component source is intentionally still the historical/hybrid input used by
010-netbird.sh. This test validates the artifact contract after 012 finalizes it,
which is the code that actually ships in firmware.
"""
from __future__ import annotations

import gzip
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_JS = ROOT / "rootfs" / "www" / "webpages" / "js"
PATCHER = ROOT / "src" / "web" / "patchnetbird_native_crud.py"
FILES = [
    "update-store-DQkZxaRI.js.gz",
    "model-CI6Gt3Hz.js.gz",
    "index-DTNtPvwx.js.gz",
    "VpnServerNetbirdForm-NB.js.gz",
]


def read_gz(path: pathlib.Path) -> str:
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return fh.read()


def main() -> int:
    missing = [name for name in FILES if not (SOURCE_JS / name).is_file()]
    if missing:
        raise AssertionError("rootfs frontend fixture missing: " + ", ".join(missing))

    with tempfile.TemporaryDirectory(prefix="netbird-native-frontend-") as tmp:
        fixture = pathlib.Path(tmp)
        js = fixture / "www" / "webpages" / "js"
        js.mkdir(parents=True)
        for name in FILES:
            shutil.copy2(SOURCE_JS / name, js / name)

        subprocess.run([sys.executable, str(PATCHER), str(fixture)], check=True)

        update = read_gz(js / FILES[0])
        model = read_gz(js / FILES[1])
        page = read_gz(js / FILES[2])
        form = read_gz(js / FILES[3])
        combined = "\n".join((update, model, page, form))

        required = [
            'e.Netbird="netbirdvpn"',
            'function f(e){return a.request(y,{operation:"connected_status",key:e},{preventSuccess:!0})}',
            'new URL(n).hostname',
            'type: "netbirdvpn", proto: "netbird"',
            'value.type === "netbirdvpn"',
            'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
            'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete()}',
        ]
        for token in required:
            assert token in combined, f"final native frontend missing {token!r}"

        forbidden = [
            'a.value=_nb.concat(e)',
            'it.Netbird===i.type?await Nbs(i)',
            'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}',
            'e==="netbird"&&await nbDelete()',
            'new URL(n).host}',
        ]
        for token in forbidden:
            assert token not in combined, f"hybrid frontend bridge leaked: {token!r}"

        for name in FILES:
            body = read_gz(js / name)
            subprocess.run(
                ["node", "--input-type=module", "--check"],
                input=body.encode(),
                check=True,
            )

    print("netbird final native frontend migration contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
