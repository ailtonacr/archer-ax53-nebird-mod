#!/usr/bin/env python3
"""Bind TP-Link's visible native Save button to NetBird persistence while dirty.

Hardware validation on Build 8 proved the previous DOM-only approach was
insufficient: the physical click reached the button and Vue invoker, but the
SuButton callback resolved to undefined because the stock modal never marked the
custom NetBird form dirty. Therefore the native button looked enabled but did
nothing.

NetBird already owns dedicated CRUD through /admin/netbird, while built-in VPN
profiles remain on the untouched stock controller. This patch keeps the same
visible TP-Link Save button, but while the NetBird form is dirty it installs a
capture listener supplied by the NetBird form. The listener validates and
persists the NetBird draft directly, then removes itself after successful save.
Other VPN forms are untouched.
"""
from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
PATH = os.path.join(ROOT, "www/webpages/js/VpnServerNetbirdForm-NB.js.gz")

NEW = '''function syncNativeSaveButton(isDirty, onSave) {
  if (typeof document === "undefined") return;
  const apply = function () {
    const modalCandidates = Array.from(document.querySelectorAll(".su-modal-mask,.su-dialog,dialog"));
    const modal = modalCandidates.length ? modalCandidates[modalCandidates.length - 1] : document;
    const candidates = Array.from(modal.querySelectorAll("button,[role=button],input[type=button],input[type=submit]"));
    const visible = candidates.filter(function (node) {
      const text = String(node.textContent || node.value || node.getAttribute && node.getAttribute("aria-label") || "").trim();
      if (!/^(salvar|save)$/i.test(text)) return false;
      if (typeof node.getBoundingClientRect !== "function") return true;
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    const save = visible.length ? visible[visible.length - 1] : null;
    if (!save) return;

    const detach = function () {
      if (save.__netbirdSaveListener && typeof save.removeEventListener === "function") {
        save.removeEventListener("click", save.__netbirdSaveListener, true);
      }
      save.__netbirdSaveListener = null;
      save.__netbirdSaveCallback = null;
    };

    if (isDirty) {
      if ("disabled" in save) save.disabled = false;
      if (typeof save.removeAttribute === "function") {
        save.removeAttribute("disabled");
        save.removeAttribute("aria-disabled");
      }
      if (save.classList) {
        ["is-disabled", "disabled", "su-disabled", "su-button-disabled"].forEach(function (name) {
          if (typeof save.classList.remove === "function") save.classList.remove(name);
        });
      }
      if (save.style) save.style.pointerEvents = "";
      if (typeof save.setAttribute === "function") save.setAttribute("data-netbird-dirty", "1");

      if (typeof onSave === "function" && save.__netbirdSaveCallback !== onSave) {
        detach();
        const listener = async function (event) {
          if (event) {
            if (typeof event.preventDefault === "function") event.preventDefault();
            if (typeof event.stopImmediatePropagation === "function") event.stopImmediatePropagation();
            else if (typeof event.stopPropagation === "function") event.stopPropagation();
          }
          await onSave();
        };
        save.__netbirdSaveListener = listener;
        save.__netbirdSaveCallback = onSave;
        if (typeof save.addEventListener === "function") save.addEventListener("click", listener, true);
      }
    } else {
      detach();
      if (typeof save.getAttribute === "function" && save.getAttribute("data-netbird-dirty") === "1") {
        if (typeof save.removeAttribute === "function") save.removeAttribute("data-netbird-dirty");
      }
    }
  };
  if (typeof queueMicrotask === "function") queueMicrotask(apply);
  else Promise.resolve().then(apply);
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(apply);
}'''

STARTS = ("function syncNativeSaveButton(isDirty) {", "function syncNativeSaveButton(isDirty, onSave) {")
END = "\n\nexport default defineComponent({"


def replace_structurally(text: str) -> str:
    if NEW in text:
        return text

    found = [(marker, text.find(marker)) for marker in STARTS if text.find(marker) >= 0]
    if len(found) != 1:
        raise RuntimeError(f"native Save bridge: expected one implementation, found {len(found)}")
    marker, start = found[0]
    for other in STARTS:
        if other != marker and text.find(other, start + 1) >= 0:
            raise RuntimeError("native Save bridge: multiple implementations found")

    end = text.find(END, start)
    if end < 0:
        raise RuntimeError("native Save bridge: form export marker not found")
    current = text[start:end]
    if "syncNativeSaveButton" not in current:
        raise RuntimeError("native Save bridge: unexpected function structure")
    return text[:start] + NEW + text[end:]


def main() -> None:
    with gzip.open(PATH, "rt", encoding="utf-8") as fh:
        text = fh.read()

    text = replace_structurally(text)

    check = subprocess.run(
        ["node", "--input-type=module", "--check"],
        input=text.encode(), capture_output=True,
    )
    if check.returncode:
        raise RuntimeError("node --check failed for native Save patch:\n" + check.stderr.decode()[:2000])

    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode())
    with open(PATH, "wb") as fh:
        fh.write(buf.getvalue())

    print("NetBird native Save button bound to dedicated settings persistence")


if __name__ == "__main__":
    main()
