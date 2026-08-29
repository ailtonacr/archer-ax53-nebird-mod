#!/usr/bin/env python3
"""Post-patch NetBird CREATE-vs-EDIT state inside TP-Link's stock VPN modal.

This stage intentionally does not touch the Save button or footer. Save state is
owned by VpnServerFormDialog through the native subFormRef.isChanged contract,
which is applied by patchnetbird_native_contract.py.

The current backend stores exactly one NetBird identity. Opening Add Profile
must therefore create a clean unenrolled draft and refuse a second NetBird
profile instead of silently loading/overwriting the existing singleton.
"""
from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
PATH = os.path.join(ROOT, "www/webpages/js/VpnServerNetbirdForm-NB.js.gz")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    with gzip.open(PATH, "rt", encoding="utf-8") as fh:
        text = fh.read()

    text = replace_once(
        text,
        '    const dirty = ref(false);\n    let stockFormInitialized = false;\n    let statusRequestPending = false;',
        '    const dirty = ref(false);\n    const creating = ref(false);\n    let stockFormInitialized = false;\n    let statusRequestPending = false;',
        "CREATE/EDIT state",
    )

    text = replace_once(
        text,
        '        else if (!dirty.value) {\n          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";\n          draft.value.enable = settings.value.enable || draft.value.enable || "0";\n        }',
        '        else if (!dirty.value && !creating.value) {\n          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";\n          draft.value.enable = settings.value.enable || draft.value.enable || "0";\n        }',
        "do not hydrate add draft from singleton profile",
    )

    text = replace_once(
        text,
        '    async function enroll() {\n      if (!setupKey.value) return;',
        '    async function enroll() {\n      if (creating.value && profileExists.value) {\n        error.value = "Esta versão suporta um único perfil NetBird. Exclua o perfil existente antes de criar outro.";\n        return;\n      }\n      if (!setupKey.value) return;',
        "singleton enrollment guard",
    )

    text = replace_once(
        text,
        '      const s = draft.value || settings.value || {};\n      if (!String(s.description || "").trim()) {',
        '      const s = draft.value || settings.value || {};\n      if (creating.value && profileExists.value) {\n        error.value = "Esta versão suporta um único perfil NetBird. Exclua o perfil existente antes de criar outro.";\n        return false;\n      }\n      if (!String(s.description || "").trim()) {',
        "singleton Save guard",
    )

    text = replace_once(
        text,
        '    function setForm(value) {\n      stockFormInitialized = true;\n      draft.value = normalizeForm(value || {}, settings.value || {});\n      dirty.value = false; error.value = ""; message.value = "";\n      syncNativeSaveButton(false);\n      return true;\n    }',
        '    function setForm(value) {\n      stockFormInitialized = true;\n      const existing = !!(value && (value.key === "netbird" || value.id === "netbird"));\n      creating.value = !existing;\n      draft.value = normalizeForm(value || {}, creating.value ? {} : (settings.value || {}));\n      if (creating.value) {\n        draft.value.enable = "0";\n        draft.value.enrolled = "0";\n      }\n      dirty.value = false; error.value = ""; message.value = "";\n      syncNativeSaveButton(false);\n      return true;\n    }',
        "add versus edit form initialization",
    )

    text = replace_once(
        text,
        '          type: "button", disabled: props.disabled || busy.value || !setupKey.value || dirty.value || !profileExists.value,',
        '          type: "button", disabled: props.disabled || busy.value || !setupKey.value || dirty.value || !profileExists.value || (creating.value && profileExists.value),',
        "singleton enrollment button guard",
    )

    text = replace_once(
        text,
        '      if (!profileExists.value) feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "Salve o perfil primeiro. Depois, reabra-o para fazer o enrollment. O perfil é persistido pelo botão SALVAR do diálogo através do controller NetBird dedicado."));\n      else if (dirty.value)',
        '      if (creating.value && profileExists.value) feedback.push(_h("div", { class: "netbird-feedback netbird-feedback-error" }, "Já existe um perfil NetBird neste roteador. Esta versão ainda usa uma única identidade persistente; exclua o perfil existente antes de adicionar outro."));\n      else if (!profileExists.value) feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "Salve o perfil primeiro. Depois, reabra-o para fazer o enrollment. O perfil é persistido pelo botão SALVAR do diálogo através do controller NetBird dedicado."));\n      else if (dirty.value)',
        "singleton add feedback",
    )

    check = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode(), capture_output=True,
    )
    if check.returncode:
        raise RuntimeError("node --check failed for NetBird form state patch:\n" + check.stderr.decode()[:2000])

    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode())
    with open(PATH, "wb") as fh:
        fh.write(buf.getvalue())

    print("NetBird CREATE/EDIT singleton semantics patched")


if __name__ == "__main__":
    main()
