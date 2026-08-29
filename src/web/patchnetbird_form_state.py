#!/usr/bin/env python3
"""Post-patch NetBird form state integration inside TP-Link's stock VPN modal.

Hardware-observed UI contracts handled here:
- TP-Link can re-render/re-disable the native Save button after a field change,
  so a dirty NetBird form must keep the native footer synchronized until the
  draft is saved/reset/closed. The actual AX53 DOM uses `.su-modal-mask`; do not
  depend on a specific button style class.
- The current backend stores exactly one NetBird profile. Opening Add Profile
  must therefore create a clean unenrolled draft and explicitly refuse a
  second NetBird profile instead of silently loading/overwriting the existing
  singleton identity.
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

    # Hardware screenshot/DevTools shows TP-Link's active dialog under
    # `.su-modal-mask`. Previous code only preferred dialog/.su-dialog and then
    # filtered for `button.su-button-primary`, which did not match the actual
    # Save control in this build. Match the active modal and identify Save by
    # its visible/accessibility label instead; the click handler remains the
    # original TP-Link handler.
    text = replace_once(
        text,
        '    const scopes = Array.from(document.querySelectorAll("dialog,.su-dialog"));\n'
        '    const scope = scopes.length ? scopes[scopes.length - 1] : document;\n'
        '    const buttons = Array.from(scope.querySelectorAll("button.su-button-primary"));\n'
        '    const save = buttons.find(function (button) {\n'
        '      return /salvar|save/i.test(String(button.textContent || "").trim());\n'
        '    }) || buttons[buttons.length - 1];',
        '    const scopes = Array.from(document.querySelectorAll(".su-modal-mask,.su-dialog,dialog"));\n'
        '    const scope = scopes.length ? scopes[scopes.length - 1] : document;\n'
        '    const controls = Array.from(scope.querySelectorAll("button,[role=button],input[type=button],input[type=submit]"));\n'
        '    const save = controls.find(function (control) {\n'
        '      const label = [control.textContent, control.value, control.getAttribute && control.getAttribute("aria-label")].filter(Boolean).join(" ");\n'
        '      return /salvar|save/i.test(String(label).trim());\n'
        '    });',
        "native TP-Link Save selector",
    )

    text = replace_once(
        text,
        '      save.disabled = false;\n'
        '      if (typeof save.removeAttribute === "function") save.removeAttribute("disabled");\n'
        '      if (save.classList && typeof save.classList.remove === "function") save.classList.remove("is-disabled");\n'
        '      if (typeof save.setAttribute === "function") save.setAttribute("data-netbird-dirty", "1");',
        '      save.disabled = false;\n'
        '      if (typeof save.removeAttribute === "function") { save.removeAttribute("disabled"); save.removeAttribute("aria-disabled"); }\n'
        '      if (typeof save.setAttribute === "function") { save.setAttribute("aria-disabled", "false"); save.setAttribute("data-netbird-dirty", "1"); }\n'
        '      if (save.classList && typeof save.classList.remove === "function") {\n'
        '        save.classList.remove("is-disabled", "disabled", "su-disabled", "su-button-disabled");\n'
        '      }',
        "native Save disabled state cleanup",
    )

    text = replace_once(
        text,
        '    const dirty = ref(false);\n    let stockFormInitialized = false;\n    let statusRequestPending = false;',
        '    const dirty = ref(false);\n    const creating = ref(false);\n    let stockFormInitialized = false;\n    let statusRequestPending = false;\n    let netbirdSaveSyncTimer = null;\n\n    function stopDirtySaveSync() {\n      if (netbirdSaveSyncTimer) clearInterval(netbirdSaveSyncTimer);\n      netbirdSaveSyncTimer = null;\n    }\n\n    function startDirtySaveSync() {\n      syncNativeSaveButton(true);\n      if (netbirdSaveSyncTimer) return;\n      netbirdSaveSyncTimer = setInterval(function () {\n        if (!dirty.value) { stopDirtySaveSync(); return; }\n        syncNativeSaveButton(true);\n      }, 100);\n    }',
        "persistent native Save synchronization",
    )

    text = replace_once(
        text,
        '      notifyParent();\n      syncNativeSaveButton(true);',
        '      notifyParent();\n      startDirtySaveSync();',
        "dirty update synchronization",
    )

    text = replace_once(
        text,
        '        else if (!dirty.value) {\n          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";\n          draft.value.enable = settings.value.enable || draft.value.enable || "0";\n        }',
        '        else if (!dirty.value && !creating.value) {\n          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";\n          draft.value.enable = settings.value.enable || draft.value.enable || "0";\n        }',
        "do not hydrate add draft from singleton profile",
    )

    text = replace_once(
        text,
        '        if (dirty.value) syncNativeSaveButton(true);',
        '        if (dirty.value) startDirtySaveSync();',
        "polling dirty synchronization",
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
        '    function setForm(value) {\n      stockFormInitialized = true;\n      const existing = !!(value && (value.key === "netbird" || value.id === "netbird"));\n      creating.value = !existing;\n      draft.value = normalizeForm(value || {}, creating.value ? {} : (settings.value || {}));\n      if (creating.value) {\n        draft.value.enable = "0";\n        draft.value.enrolled = "0";\n      }\n      dirty.value = false; error.value = ""; message.value = "";\n      stopDirtySaveSync();\n      syncNativeSaveButton(false);\n      return true;\n    }',
        "add versus edit form initialization",
    )

    text = replace_once(
        text,
        '      dirty.value = false; error.value = ""; message.value = "";\n      syncNativeSaveButton(false);\n      return true;\n    }\n\n    function clearValidate()',
        '      dirty.value = false; error.value = ""; message.value = "";\n      stopDirtySaveSync();\n      syncNativeSaveButton(false);\n      return true;\n    }\n\n    function clearValidate()',
        "reset stops Save synchronizer",
    )

    text = replace_once(
        text,
        '    onUnmounted(function () { if (timer) clearInterval(timer); syncNativeSaveButton(false); });',
        '    onUnmounted(function () { if (timer) clearInterval(timer); stopDirtySaveSync(); syncNativeSaveButton(false); });',
        "unmount Save cleanup",
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

    print("NetBird form dirty-state + singleton add semantics patched")


if __name__ == "__main__":
    main()
