#!/usr/bin/env python3
"""Make NetBird dirty-state control TP-Link's visible native Save button reliably.

Hardware validation showed that changing the description enables Save through a
stock TP-Link path, while NetBird-only fields/toggles do not. Earlier code tried
to compensate by querying `button.su-button-primary`, but the current AX53 modal
uses a different DOM shape, so the native Save was never found.

This post-patch deliberately keeps the stock Save/click handler. It only finds
the visible Save control by its localized text (SALVAR/Save) while the NetBird
form is dirty, then clears the disabled presentation/state. The existing dirty
synchronizer reapplies this if Vue replaces the footer node.
"""
from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
PATH = os.path.join(ROOT, "www/webpages/js/VpnServerNetbirdForm-NB.js.gz")

OLD = '''function syncNativeSaveButton(isDirty) {
  if (typeof document === "undefined") return;
  const apply = function () {
    const scopes = Array.from(document.querySelectorAll("dialog,.su-dialog"));
    const scope = scopes.length ? scopes[scopes.length - 1] : document;
    const buttons = Array.from(scope.querySelectorAll("button.su-button-primary"));
    const save = buttons.find(function (button) {
      return /salvar|save/i.test(String(button.textContent || "").trim());
    }) || buttons[buttons.length - 1];
    if (!save) return;
    if (isDirty) {
      save.disabled = false;
      if (typeof save.removeAttribute === "function") save.removeAttribute("disabled");
      if (save.classList && typeof save.classList.remove === "function") save.classList.remove("is-disabled");
      if (typeof save.setAttribute === "function") save.setAttribute("data-netbird-dirty", "1");
    } else if (typeof save.getAttribute === "function" && save.getAttribute("data-netbird-dirty") === "1") {
      if (typeof save.removeAttribute === "function") save.removeAttribute("data-netbird-dirty");
    }
  };
  if (typeof queueMicrotask === "function") queueMicrotask(apply);
  else Promise.resolve().then(apply);
}'''

NEW = '''function syncNativeSaveButton(isDirty) {
  if (typeof document === "undefined") return;
  const apply = function () {
    const candidates = Array.from(document.querySelectorAll("button,[role=button]"));
    const visible = candidates.filter(function (node) {
      const text = String(node.textContent || "").trim();
      if (!/^(salvar|save)$/i.test(text)) return false;
      if (typeof node.getBoundingClientRect !== "function") return true;
      const rect = node.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    const save = visible.length ? visible[visible.length - 1] : null;
    if (!save) return;
    if (isDirty) {
      if ("disabled" in save) save.disabled = false;
      if (typeof save.removeAttribute === "function") {
        save.removeAttribute("disabled");
        save.removeAttribute("aria-disabled");
      }
      if (save.classList) {
        ["is-disabled", "disabled", "su-button-disabled"].forEach(function (name) {
          if (typeof save.classList.remove === "function") save.classList.remove(name);
        });
      }
      if (save.style) save.style.pointerEvents = "";
      if (typeof save.setAttribute === "function") save.setAttribute("data-netbird-dirty", "1");
    } else if (typeof save.getAttribute === "function" && save.getAttribute("data-netbird-dirty") === "1") {
      if (typeof save.removeAttribute === "function") save.removeAttribute("data-netbird-dirty");
    }
  };
  if (typeof queueMicrotask === "function") queueMicrotask(apply);
  else Promise.resolve().then(apply);
  if (typeof requestAnimationFrame === "function") requestAnimationFrame(apply);
}'''


def main() -> None:
    with gzip.open(PATH, "rt", encoding="utf-8") as fh:
        text = fh.read()
    if NEW not in text:
        count = text.count(OLD)
        if count != 1:
            raise RuntimeError(f"native Save selector: expected one old implementation, found {count}")
        text = text.replace(OLD, NEW, 1)

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

    print("NetBird native Save selector patched for visible TP-Link footer")


if __name__ == "__main__":
    main()
