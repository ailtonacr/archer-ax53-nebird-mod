#!/usr/bin/env python3
"""Safely upload an AX53 firmware image through the stock TP-Link Web UI.

Default flow:
  * read BUILD and select BUILD - 1
  * validate the image and print SHA256
  * open the stock Web UI and wait for the SPA to hydrate
  * authenticate
  * navigate Advanced -> System -> Firmware Upgrade
  * select the image and advance to the stock confirmation step
  * STOP and require the literal token CONFIRMAR in the terminal
  * send the final UI confirmation and monitor reboot

The script never stores the router password. AX53_PASSWORD may be supplied in the
environment; otherwise getpass() is used. UI diagnostics deliberately omit input
values and redact session tokens such as LuCI's ;stok=... path component.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROUTER_URL = "http://192.168.10.1"
DEBUG_DIR = REPO_ROOT / "work" / "router-upload-debug"
CONFIRM_TOKEN = "CONFIRMAR"

ADVANCED_RE = re.compile(r"(?:^|\b)(Advanced|Avançado)(?:$|\b)", re.IGNORECASE)
SYSTEM_RE = re.compile(
    r"(?:^|\b)(System Tools|Ferramentas do Sistema|System|Sistema)(?:$|\b)",
    re.IGNORECASE,
)
FIRMWARE_RE = re.compile(
    r"(Firmware\s*(Upgrade|Update)|Atualiza(?:ção|cao)\s+(?:do\s+)?Firmware|Atualizar\s+Firmware)",
    re.IGNORECASE,
)
LOGIN_RE = re.compile(r"^(Log\s*In|Login|Entrar|Acessar)$", re.IGNORECASE)
UPGRADE_RE = re.compile(
    r"^(Upgrade|Update|Atualizar|Atualizar\s+Firmware|Upgrade\s+Firmware)$",
    re.IGNORECASE,
)
CONFIRM_RE = re.compile(
    r"^(Upgrade|Update|Atualizar|Yes|Sim|OK|Confirm|Confirmar|Continue|Continuar)$",
    re.IGNORECASE,
)
CANCEL_RE = re.compile(r"^(Cancel|Cancelar|No|Não|Nao|Close|Fechar)$", re.IGNORECASE)
SENSITIVE_ATTR_RE = re.compile(r"(pass|password|senha|token|secret|key|auth|cookie)", re.I)


@dataclass(frozen=True)
class FirmwareInfo:
    build: int
    path: Path
    size: int
    sha256: str


def die(message: str, code: int = 2) -> "None":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_build_number(build_file: Path) -> int:
    try:
        raw = build_file.read_text(encoding="utf-8").strip()
    except OSError as exc:
        die(f"não foi possível ler {build_file}: {exc}")
    if not raw.isdigit():
        die(f"{build_file} deve conter apenas um inteiro positivo; recebido {raw!r}")
    value = int(raw)
    if value < 2:
        die(f"BUILD={value}; não existe BUILD - 1 válido para upload.")
    return value


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve_firmware(build_file: Path, explicit_build: int | None) -> FirmwareInfo:
    next_build = read_build_number(build_file)
    build = explicit_build if explicit_build is not None else next_build - 1
    if build < 1:
        die(f"build inválido: {build}")
    if explicit_build is not None and build >= next_build:
        die(
            f"--build {build} ainda não é concluído segundo BUILD={next_build}; "
            f"o maior elegível é {next_build - 1}."
        )

    path = REPO_ROOT / "work" / f"Archer-AX53-NetBird-build-{build}.bin"
    if not path.is_file():
        die(
            f"firmware do build {build} não encontrado: {path}\n"
            f"BUILD atual={next_build}; esperado por padrão: BUILD - 1 = {next_build - 1}"
        )
    size = path.stat().st_size
    if size < 1024 * 1024:
        die(f"firmware parece vazio/truncado ({size} bytes): {path}")
    return FirmwareInfo(build, path.resolve(), size, sha256_file(path))


def parse_router_target(router_url: str) -> tuple[str, int]:
    parsed = urlparse(router_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        die(f"--router-url inválida: {router_url!r}")
    return parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)


def tcp_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def require_router_reachable(host: str, port: int) -> None:
    if not tcp_open(host, port):
        die(f"roteador não está acessível em {host}:{port}; ABORT antes do upload.")


def wait_for_reboot(host: str, port: int, timeout: int, *, already_down: bool = False) -> None:
    deadline = time.monotonic() + timeout
    if already_down:
        print("[reboot] queda da Web UI já detectada.")
    else:
        print(f"[reboot] aguardando {host}:{port} sair do ar ...")
        while time.monotonic() < deadline:
            if not tcp_open(host, port, timeout=1.0):
                print("[reboot] queda do serviço detectada.")
                break
            time.sleep(2)
        else:
            die("a Web UI não saiu do ar; não foi possível confirmar início do reboot.")

    print(f"[reboot] aguardando {host}:{port} voltar ...")
    while time.monotonic() < deadline:
        if tcp_open(host, port, timeout=1.0):
            print("[reboot] Web UI voltou a aceitar conexões.")
            return
        time.sleep(3)
    die(
        f"roteador não voltou em {host}:{port} dentro de {timeout}s. "
        "Não interrompa a energia; use recovery se necessário."
    )


def import_playwright():
    try:
        from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
        from playwright.sync_api import sync_playwright
    except ImportError:
        die(
            "Playwright não está instalado nesta virtualenv.\n"
            "Instale com:\n"
            "  python3 -m pip install playwright\n"
            "  python3 -m playwright install chromium"
        )
    return sync_playwright, PlaywrightTimeoutError


def validate_headed_environment(headed: bool) -> None:
    if headed and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        die(
            "--headed requer DISPLAY/WAYLAND_DISPLAY, mas esta shell é TTY.\n"
            "Rode sem --headed para usar Chromium headless."
        )


def all_frames(page):
    return list(page.frames)


def first_visible(locator):
    try:
        count = locator.count()
    except Exception:
        return None
    for idx in range(count):
        item = locator.nth(idx)
        try:
            if item.is_visible():
                return item
        except Exception:
            continue
    return None


def visible_in_frames(page, selector: str):
    for frame in all_frames(page):
        item = first_visible(frame.locator(selector))
        if item is not None:
            return item
    return None


def redact_url(url: str) -> str:
    value = re.sub(r";stok=[^/;?#]+", ";stok=<redacted>", url, flags=re.I)
    value = re.sub(
        r"([?&](?:token|auth|key|secret|session|sid)=)[^&#]+",
        r"\1<redacted>",
        value,
        flags=re.I,
    )
    return value


def safe_text(value: str | None, limit: int = 180) -> str:
    if not value:
        return ""
    value = re.sub(r"\s+", " ", value).strip()
    return value[:limit]


def wait_for_spa(page, timeout_ms: int = 20000) -> None:
    try:
        page.wait_for_load_state("load", timeout=min(timeout_ms, 10000))
    except Exception:
        pass
    try:
        page.wait_for_load_state("networkidle", timeout=min(timeout_ms, 10000))
    except Exception:
        pass

    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            try:
                if frame.locator("input, button, a, [role=button], [role=tab]").count() > 0:
                    page.wait_for_timeout(500)
                    return
            except Exception:
                continue
        page.wait_for_timeout(250)


def wait_visible_in_frames(page, selectors: tuple[str, ...], timeout_ms: int):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for selector in selectors:
            item = visible_in_frames(page, selector)
            if item is not None:
                return item
        page.wait_for_timeout(250)
    return None


def click_named(page, pattern: re.Pattern[str], *, timeout_ms: int = 8000):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            for role in ("button", "link", "tab", "menuitem"):
                try:
                    item = first_visible(frame.get_by_role(role, name=pattern))
                except Exception:
                    item = None
                if item is not None:
                    item.click()
                    return item

            # TP-Link's Vue menus are not consistently exposed with ARIA roles.
            for selector in ("a", "button", "li", "div", "span"):
                try:
                    items = frame.locator(selector).filter(has_text=pattern)
                    for idx in range(min(items.count(), 80)):
                        item = items.nth(idx)
                        text = safe_text(item.inner_text(timeout=300))
                        if text and pattern.search(text) and item.is_visible():
                            item.click()
                            return item
                except Exception:
                    continue
        page.wait_for_timeout(250)
    return None


def click_firmware_link(page, timeout_ms: int = 8000):
    deadline = time.monotonic() + timeout_ms / 1000
    route_re = re.compile(r"firmware|upgrade", re.I)
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            try:
                links = frame.locator("a[href]")
                for idx in range(min(links.count(), 200)):
                    link = links.nth(idx)
                    href = link.get_attribute("href") or ""
                    text = safe_text(link.inner_text(timeout=300))
                    if link.is_visible() and (FIRMWARE_RE.search(text) or route_re.search(href)):
                        link.click()
                        return link
            except Exception:
                continue
        page.wait_for_timeout(250)
    return None


def screenshot(page, name: str) -> Path | None:
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    out = DEBUG_DIR / name
    try:
        page.screenshot(path=str(out), full_page=True)
        return out
    except Exception:
        return None


def dump_ui(page, label: str, build: int) -> Path:
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = int(time.time())
    out = DEBUG_DIR / f"ui-{label}-build-{build}-{stamp}.json"
    payload: dict[str, object] = {
        "title": "",
        "url": redact_url(page.url),
        "frames": [],
    }
    try:
        payload["title"] = safe_text(page.title(), 250)
    except Exception:
        pass

    frame_dump = []
    for frame in all_frames(page):
        entry: dict[str, object] = {
            "url": redact_url(frame.url),
            "controls": [],
            "visible_text": [],
        }
        controls = []
        try:
            loc = frame.locator("input, button, a, [role=button], [role=tab], [role=menuitem]")
            for idx in range(min(loc.count(), 250)):
                el = loc.nth(idx)
                try:
                    if not el.is_visible():
                        continue
                    tag = el.evaluate("e => e.tagName.toLowerCase()")
                    attrs = {}
                    for name in ("type", "id", "name", "class", "placeholder", "role", "href", "aria-label"):
                        if SENSITIVE_ATTR_RE.search(name) and name not in {"type", "id", "name", "class", "placeholder", "role", "href", "aria-label"}:
                            continue
                        value = el.get_attribute(name)
                        if value:
                            attrs[name] = redact_url(safe_text(value, 220)) if name == "href" else safe_text(value, 220)
                    controls.append({
                        "tag": tag,
                        "text": safe_text(el.inner_text(timeout=300), 180) if tag != "input" else "",
                        "attrs": attrs,
                    })
                except Exception:
                    continue
        except Exception:
            pass
        entry["controls"] = controls

        try:
            body = frame.locator("body").inner_text(timeout=1500)
            seen = set()
            lines = []
            for raw in body.splitlines():
                text = safe_text(raw, 180)
                if not text or text in seen:
                    continue
                seen.add(text)
                lines.append(text)
                if len(lines) >= 100:
                    break
            entry["visible_text"] = lines
        except Exception:
            pass
        frame_dump.append(entry)
    payload["frames"] = frame_dump
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return out


def diagnose(page, label: str, build: int) -> tuple[Path | None, Path]:
    shot = screenshot(page, f"ui-{label}-build-{build}-{int(time.time())}.png")
    dump = dump_ui(page, label, build)
    print(f"[debug] UI dump sanitizado: {dump}")
    if shot:
        print(f"[debug] screenshot: {shot}")
    return shot, dump


def login(page, password: str, username: str | None, build: int) -> None:
    selectors = (
        'input[type="password"]',
        'input[autocomplete="current-password"]',
        'input[name*="pass" i]',
        'input[id*="pass" i]',
        'input[placeholder*="senha" i]',
        'input[placeholder*="password" i]',
    )
    password_input = wait_visible_in_frames(page, selectors, timeout_ms=20000)

    if password_input is None:
        # A fresh Playwright context has no persisted cookies. Treat absence of a
        # login field as unknown state, not as proof of authentication.
        print("[login] campo de senha não apareceu após a hidratação da SPA.")
        diagnose(page, "login-not-found", build)
        # Continue only if the authenticated shell is visibly present.
        shell_visible = False
        for pattern in (ADVANCED_RE, SYSTEM_RE):
            for frame in all_frames(page):
                try:
                    if first_visible(frame.get_by_text(pattern)) is not None:
                        shell_visible = True
                        break
                except Exception:
                    continue
            if shell_visible:
                break
        if shell_visible:
            print("[login] shell autenticado detectado; continuando sem novo login.")
            return
        die("estado de login não pôde ser determinado; veja o UI dump sanitizado.")

    if username:
        username_input = wait_visible_in_frames(
            page,
            (
                'input[type="text"]',
                'input[type="email"]',
                'input[name*="user" i]',
                'input[id*="user" i]',
            ),
            timeout_ms=1500,
        )
        if username_input is not None:
            username_input.fill(username)

    password_input.fill(password)
    if click_named(page, LOGIN_RE, timeout_ms=2500) is None:
        try:
            password_input.press("Enter")
        except Exception:
            form = password_input.locator("xpath=ancestor::form[1]")
            if form.count():
                form.evaluate("f => f.requestSubmit()")

    wait_for_spa(page, 20000)
    page.wait_for_timeout(1200)

    # The password input may remain in detached/hidden login markup. Only visible
    # login controls count as a failed login.
    if wait_visible_in_frames(page, selectors, timeout_ms=2500) is not None:
        diagnose(page, "login-rejected", build)
        die("a tela de login permaneceu ativa; senha não aceita ou login não concluiu.")
    print("[login] autenticação concluída.")


def navigate_to_firmware(page, build: int) -> None:
    print("[nav] abrindo Avançado / Advanced ...")
    advanced = click_named(page, ADVANCED_RE, timeout_ms=10000)
    if advanced is None:
        print("[nav] Avançado não localizado; procurando rota de firmware já exposta.")
    else:
        page.wait_for_timeout(800)

    print("[nav] abrindo Sistema / System Tools ...")
    system = click_named(page, SYSTEM_RE, timeout_ms=8000)
    if system is None:
        print("[nav] Sistema não localizado; procurando Firmware Upgrade diretamente.")
    else:
        page.wait_for_timeout(800)

    print("[nav] abrindo Atualização de Firmware / Firmware Upgrade ...")
    firmware = click_named(page, FIRMWARE_RE, timeout_ms=8000)
    if firmware is None:
        firmware = click_firmware_link(page, timeout_ms=5000)
    if firmware is None:
        diagnose(page, "firmware-nav-not-found", build)
        die("não encontrei a página de atualização; veja o UI dump sanitizado.")
    wait_for_spa(page, 15000)
    page.wait_for_timeout(700)


def find_file_input(page):
    for selector in (
        'input[type="file"][accept*=".bin"]',
        'input[type="file"][accept*="octet"]',
        'input[type="file"]',
    ):
        for frame in all_frames(page):
            try:
                loc = frame.locator(selector)
                if loc.count():
                    return loc.first
            except Exception:
                continue
    return None


def wait_upgrade_button(page, timeout_ms: int = 60000):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            for role in ("button", "link"):
                try:
                    loc = frame.get_by_role(role, name=UPGRADE_RE)
                    for idx in range(loc.count()):
                        item = loc.nth(idx)
                        if item.is_visible() and item.is_enabled():
                            return item
                except Exception:
                    continue
            try:
                candidates = frame.locator("button, a, [role=button]").filter(has_text=UPGRADE_RE)
                for idx in range(min(candidates.count(), 50)):
                    item = candidates.nth(idx)
                    if item.is_visible() and item.is_enabled():
                        return item
            except Exception:
                pass
        page.wait_for_timeout(500)
    return None


def confirmation_button(page):
    # Prefer buttons inside an actual modal/dialog.
    for frame in all_frames(page):
        for selector in ('[role="dialog"]', '.su-dialog', '.su-modal', '.modal'):
            try:
                dialogs = frame.locator(selector)
                for d_idx in range(dialogs.count()):
                    dialog = dialogs.nth(d_idx)
                    if not dialog.is_visible():
                        continue
                    buttons = dialog.locator("button, [role=button], a").filter(has_text=CONFIRM_RE)
                    for b_idx in range(buttons.count() - 1, -1, -1):
                        button = buttons.nth(b_idx)
                        if button.is_visible() and button.is_enabled():
                            return button
            except Exception:
                continue
    return None


def wait_confirmation_step(page, host: str, port: int, timeout_s: int = 90):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not tcp_open(host, port, timeout=1.0):
            return None, True
        button = confirmation_button(page)
        if button is not None:
            return button, False
        page.wait_for_timeout(400)
    return None, False


def cancel_confirmation_if_possible(page) -> None:
    for frame in all_frames(page):
        for selector in ('[role="dialog"]', '.su-dialog', '.su-modal', '.modal'):
            try:
                dialogs = frame.locator(selector)
                for idx in range(dialogs.count()):
                    dialog = dialogs.nth(idx)
                    if not dialog.is_visible():
                        continue
                    button = first_visible(dialog.locator("button, [role=button], a").filter(has_text=CANCEL_RE))
                    if button is not None and button.is_enabled():
                        button.click()
                        print("[confirm] modal cancelado na UI.")
                        return
            except Exception:
                continue


def ask_flash_confirmation(firmware: FirmwareInfo, router_url: str) -> bool:
    print("\n=== CONFIRMAÇÃO FINAL DE FLASH ===")
    print(f"Roteador : {router_url}")
    print(f"Build    : {firmware.build}")
    print(f"Arquivo  : {firmware.path.name}")
    print(f"Tamanho  : {firmware.size} bytes")
    print(f"SHA256   : {firmware.sha256}")
    print("\nA UI stock está no passo final de confirmação.")
    print("Após confirmar, NÃO interrompa a alimentação do AX53.")
    answer = input(f"\nDigite {CONFIRM_TOKEN} para iniciar o flash, ou Enter para cancelar: ").strip()
    return answer == CONFIRM_TOKEN


def run_browser(args, firmware: FirmwareInfo, password: str) -> None:
    validate_headed_environment(args.headed)
    sync_playwright, PlaywrightTimeoutError = import_playwright()
    host, port = parse_router_target(args.router_url)
    require_router_reachable(host, port)
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        context = browser.new_context(ignore_https_errors=True, viewport={"width": 1440, "height": 1000})
        page = context.new_page()
        page.set_default_timeout(args.ui_timeout * 1000)

        native_confirmation: dict[str, object] = {"seen": False, "accepted": False}

        def handle_native_dialog(dialog):
            native_confirmation["seen"] = True
            print(f"[confirm] diálogo nativo detectado: {safe_text(dialog.message, 220)}")
            if ask_flash_confirmation(firmware, args.router_url):
                native_confirmation["accepted"] = True
                dialog.accept()
            else:
                print("[confirm] flash CANCELADO pelo usuário.")
                dialog.dismiss()

        page.on("dialog", handle_native_dialog)

        try:
            print(f"[router] abrindo {args.router_url}")
            page.goto(args.router_url, wait_until="domcontentloaded")
            wait_for_spa(page, 20000)

            login(page, password, args.username, firmware.build)
            navigate_to_firmware(page, firmware.build)

            file_input = find_file_input(page)
            if file_input is None:
                diagnose(page, "file-input-not-found", firmware.build)
                die("input de firmware não encontrado; ABORT antes de qualquer flash.")

            print(f"[upload] selecionando {firmware.path.name}")
            file_input.set_input_files(str(firmware.path))
            page.wait_for_timeout(1200)

            try:
                value = file_input.input_value()
            except Exception:
                value = ""
            if value and firmware.path.name not in value:
                die(f"a UI associou um arquivo inesperado: {value!r}; ABORT.")

            upgrade_button = wait_upgrade_button(page)
            if upgrade_button is None:
                diagnose(page, "upgrade-button-not-found", firmware.build)
                die("arquivo selecionado, mas botão Upgrade/Atualizar não ficou disponível.")

            ready_shot = screenshot(page, f"build-{firmware.build}-ready.png")
            if ready_shot:
                print(f"[debug] screenshot com firmware selecionado: {ready_shot}")

            print("[upload] avançando até a confirmação stock do firmware ...")
            upgrade_button.click()

            # A native JS confirm is handled synchronously by handle_native_dialog.
            if native_confirmation["seen"]:
                if not native_confirmation["accepted"]:
                    return
                if not args.no_wait_reboot:
                    wait_for_reboot(host, port, args.reboot_timeout)
                return

            confirm_button, reboot_started = wait_confirmation_step(page, host, port)
            if reboot_started:
                diagnose(page, "unexpected-reboot-before-confirm", firmware.build)
                die(
                    "a Web UI caiu antes de detectarmos confirmação final. "
                    "Por segurança, não assumo que esse primeiro clique era reversível."
                )
            if confirm_button is None:
                diagnose(page, "confirm-not-found", firmware.build)
                die("nenhum passo final de confirmação foi detectado; ABORT.")

            confirm_shot = screenshot(page, f"build-{firmware.build}-confirm.png")
            if confirm_shot:
                print(f"[debug] screenshot do passo de confirmação: {confirm_shot}")

            if not ask_flash_confirmation(firmware, args.router_url):
                print("[confirm] flash CANCELADO; confirmação final não enviada.")
                cancel_confirmation_if_possible(page)
                return

            # Re-resolve to avoid a stale locator if Vue re-rendered while waiting.
            confirm_button = confirmation_button(page)
            if confirm_button is None:
                die("a confirmação final desapareceu antes do clique; ABORT.")
            print("[confirm] autorização recebida; enviando confirmação final ...")
            confirm_button.click()
            if not args.no_wait_reboot:
                wait_for_reboot(host, port, args.reboot_timeout)

        except SystemExit:
            raise
        except KeyboardInterrupt:
            print("\n[abort] cancelado pelo usuário; nenhuma confirmação adicional será enviada.")
            cancel_confirmation_if_possible(page)
            raise SystemExit(130)
        except PlaywrightTimeoutError as exc:
            diagnose(page, "playwright-timeout", firmware.build)
            die(f"timeout na UI do AX53: {exc}")
        except Exception as exc:
            diagnose(page, "unexpected-error", firmware.build)
            die(f"falha na automação da UI: {type(exc).__name__}: {exc}")
        finally:
            try:
                context.close()
            finally:
                browser.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Upload AX53 pelo Web UI stock. Usa BUILD - 1 por padrão, chega à "
            "confirmação final e exige CONFIRMAR no terminal."
        )
    )
    parser.add_argument("--router-url", default=DEFAULT_ROUTER_URL)
    parser.add_argument("--build-file", type=Path, default=REPO_ROOT / "BUILD")
    parser.add_argument("--build", type=int, help="reflash explícito de build já concluído")
    parser.add_argument("--username", help="usuário da UI quando aplicável")
    parser.add_argument("--password-env", default="AX53_PASSWORD")
    parser.add_argument("--headed", action="store_true", help="requer DISPLAY/WAYLAND_DISPLAY")
    parser.add_argument("--ui-timeout", type=int, default=15)
    parser.add_argument("--reboot-timeout", type=int, default=600)
    parser.add_argument("--no-wait-reboot", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    firmware = resolve_firmware(args.build_file.resolve(), args.build)
    host, port = parse_router_target(args.router_url)

    print("=== AX53 firmware uploader ===")
    print(f"Target     : {args.router_url} ({host}:{port})")
    print(f"BUILD file : {args.build_file.resolve()}")
    print(f"Build      : {firmware.build}")
    print(f"Firmware   : {firmware.path}")
    print(f"Size       : {firmware.size} bytes")
    print(f"SHA256     : {firmware.sha256}")
    print("Mode       : INTERACTIVE / STOP AT FINAL CONFIRMATION")

    password = os.environ.get(args.password_env)
    if password is None:
        password = getpass.getpass("Senha da UI do AX53: ")
    if not password:
        die("senha vazia; ABORT.")

    run_browser(args, firmware, password)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
