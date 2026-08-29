#!/usr/bin/env python3
"""Align the generated NetBird subform with TP-Link's native VPN form contract."""
from __future__ import annotations

import gzip
import io
import os
import subprocess
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "rootfs"
PATH = os.path.join(ROOT, "www/webpages/js/VpnServerNetbirdForm-NB.js.gz")


def remove_between(text: str, start_marker: str, end_marker: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        return text
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError(f"{label}: end marker not found")
    return text[:start] + text[end:]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one occurrence, found {count}")
    return text.replace(old, new, 1)


def patch(text: str) -> str:
    # Remove every historical DOM-level Save bridge. The stock dialog must own
    # the Save button, disabled state and click lifecycle.
    for marker in (
        "function syncNativeSaveButton(isDirty, onSave) {",
        "function syncNativeSaveButton(isDirty) {",
    ):
        if marker in text:
            text = remove_between(text, marker, "\n\nexport default defineComponent({", "DOM Save bridge")
            break

    # Keep CREATE-vs-EDIT singleton state from the previous stage, but remove
    # its 100ms Save polling and synthetic change/update bridge.
    text = remove_between(text, "    let netbirdSaveSyncTimer = null;", "    function notifyParent() {", "Save polling")
    text = remove_between(text, "    function notifyParent() {", "    function updateDraft(key, value) {", "synthetic parent events")
    for old in (
        "      notifyParent();\n",
        "      startDirtySaveSync();\n",
        "        if (dirty.value) startDirtySaveSync();\n",
        "      stopDirtySaveSync();\n",
        "      syncNativeSaveButton(false);\n",
    ):
        text = text.replace(old, "")
    text = text.replace(
        "    onUnmounted(function () { if (timer) clearInterval(timer); stopDirtySaveSync(); syncNativeSaveButton(false); });",
        "    onUnmounted(function () { if (timer) clearInterval(timer); });",
    )
    text = text.replace(
        "    onUnmounted(function () { if (timer) clearInterval(timer); syncNativeSaveButton(false); });",
        "    onUnmounted(function () { if (timer) clearInterval(timer); });",
    )

    # Native parent awaits validate() but ignores a resolved false. Match stock
    # forms: invalid state rejects, valid state resolves.
    start = text.find("    async function validate() {")
    end = text.find("\n\n    function setForm(value) {", start)
    if start < 0 or end < 0:
        raise RuntimeError("validate block not found")
    validate = '''    async function validate() {
      error.value = "";
      const s = draft.value || settings.value || {};
      if (creating.value && profileExists.value) {
        error.value = "Esta versão suporta um único perfil NetBird. Exclua o perfil existente antes de criar outro.";
        throw new Error(error.value);
      }
      if (!validHostname(s.hostname)) {
        error.value = "Hostname inválido. Use apenas letras, números, ponto, hífen ou sublinhado (máx. 64 caracteres).";
        throw new Error(error.value);
      }
      if (!validWireGuardPort(s.wireguard_port)) {
        error.value = "Informe uma porta WireGuard entre 1 e 65535.";
        throw new Error(error.value);
      }
      if (!validManagementUrl(s.management_url)) {
        error.value = "Informe uma URL de gerenciamento válida (http:// ou https://).";
        throw new Error(error.value);
      }
      if (s.advertise_lan === "1" && !validCidr(s.advertise_cidr)) {
        error.value = "Informe uma rede LAN válida em CIDR, por exemplo 192.168.10.0/24.";
        throw new Error(error.value);
      }
      return true;
    }'''
    text = text[:start] + validate + text[end:]

    # The stock base form owns description/type. The protocol subform returns
    # only NetBird-specific fields, exactly like WireGuard/PPTP/L2TP.
    text = replace_once(
        text,
        "    function getForm() { return stockForm(draft.value || settings.value || {}); }",
        '''    function getForm() {
      const s = draft.value || settings.value || {};
      return {
        enable: s.enable === "1" ? "on" : "off",
        enabled: s.enable === "1",
        enrolled: s.enrolled || "0",
        management_url: s.management_url || "",
        server: s.management_url || "",
        hostname: s.hostname || "",
        disable_dns: s.disable_dns || "1",
        disable_firewall: s.disable_firewall || "1",
        disable_client_routes: s.disable_client_routes || "1",
        disable_server_routes: s.disable_server_routes || "1",
        disable_ipv6: s.disable_ipv6 || "1",
        network_monitor: s.network_monitor || "0",
        advertise_lan: s.advertise_lan || "0",
        advertise_cidr: s.advertise_cidr || "",
        wireguard_port: s.wireguard_port || "51820",
      };
    }''',
        "protocol-only getForm",
    )

    # This is the state the stock VpnServerFormDialog reads to compute
    # ok-disabled. Vue exposes refs as public-instance properties just like the
    # stock WireGuard form does.
    text = replace_once(
        text,
        "      context.expose({ validate, setForm, getForm, resetForm, clearValidate });",
        "      context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate });",
        "isChanged exposure",
    )

    # Description is rendered/validated by VpnServerBaseForm. Remove the
    # duplicate Description field injected into the protocol subform.
    desc = text.find('        field("Descrição", _h("input", {')
    if desc >= 0:
        url = text.find('        field("URL de gerenciamento", _h("input", {', desc)
        if url < 0:
            raise RuntimeError("duplicate description field found without URL field")
        text = text[:desc] + text[url:]

    forbidden = (
        "syncNativeSaveButton",
        "netbirdSaveSyncTimer",
        "startDirtySaveSync",
        "stopDirtySaveSync",
        "data-netbird-dirty",
        "__netbirdSaveListener",
        "stopImmediatePropagation",
    )
    leaked = [token for token in forbidden if token in text]
    if leaked:
        raise RuntimeError("legacy Save interception leaked: " + ", ".join(leaked))

    required = (
        "context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate })",
        "throw new Error(error.value)",
        'management_url: s.management_url || ""',
        'wireguard_port: s.wireguard_port || "51820"',
        "const creating = ref(false)",
    )
    missing = [token for token in required if token not in text]
    if missing:
        raise RuntimeError("native form contract incomplete: " + ", ".join(missing))
    return text


def main() -> None:
    with gzip.open(PATH, "rt", encoding="utf-8") as fh:
        text = fh.read()
    text = patch(text)
    check = subprocess.run(["node", "--input-type=module", "--check"], input=text.encode(), capture_output=True)
    if check.returncode:
        raise RuntimeError("node --check failed:\n" + check.stderr.decode()[:2000])
    buf = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buf, mtime=0) as gz:
        gz.write(text.encode())
    with open(PATH, "wb") as fh:
        fh.write(buf.getvalue())
    print("NetBird subform aligned to TP-Link native isChanged/validate/getForm contract")


if __name__ == "__main__":
    main()
