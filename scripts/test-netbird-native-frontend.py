#!/usr/bin/env python3
"""Execute the native frontend finalizer against an isolated rootfs fixture."""
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
            'const existing = !!(value && (value.key || value.id))',
            'const creating = ref(true)',
            'i=async()=>{const{data:e,maxRules:t}=await J();a.value=e,l.value=t}',
            'async function J(e,n){await function(e,n){return a.remove(y,{key:e,index:n},{preventSuccess:!0})}(e,n),await nbDelete()}',
            'stockComponent(this, "su-form")',
            'stockComponent(this, "su-form-item")',
            'stockComponent(this, "su-input")',
            'stockComponent(this, "su-checkbox")',
            'stockComponent(this, "su-button")',
        ]
        for token in required:
            assert token in combined, f"final native frontend missing {token!r}"

        forbidden = [
            'a.value=_nb.concat(e)',
            'it.Netbird===i.type?await Nbs(i)',
            'e==="netbird"?a.request("/admin/netbird",{operation:"connected_status"}',
            'e==="netbird"&&await nbDelete()',
            'new URL(n).host}',
            'value.type === "netbirdvpn"',
            "netbirdvpn-new",
            "NETBIRD_CSS",
            'type: "checkbox"',
            'class: "netbird-input"',
        ]
        for token in forbidden:
            assert token not in combined, f"hybrid/custom frontend bridge leaked: {token!r}"

        for name in FILES:
            body = read_gz(js / name)
            subprocess.run(["node", "--input-type=module", "--check"], input=body.encode(), check=True)

    print("netbird final stock-component/native CRUD frontend contract ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
