#!/usr/bin/env python3
"""
Upload the latest completed AX53 firmware build through the stock TP-Link Web UI.

Default behavior is deliberately non-destructive:
  * read BUILD
  * select BUILD - 1
  * validate the firmware image
  * log in and navigate to Firmware Upgrade
  * attach the image to the file input
  * STOP before clicking Upgrade

Pass --apply to explicitly authorize the destructive Upgrade/confirmation click.

Credentials are never stored by this script. AX53_PASSWORD may be supplied in the
environment; otherwise the password is requested with getpass().
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
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

ADVANCED_RE = re.compile(r"^(Advanced|Avançado)$", re.IGNORECASE)
SYSTEM_RE = re.compile(
    r"^(System Tools|Ferramentas do Sistema|System|Sistema)$", re.IGNORECASE
)
FIRMWARE_RE = re.compile(
    r"^(Firmware Upgrade|Atualização de Firmware|Atualização do Firmware|"
    r"Atualizar Firmware|Firmware Update)$",
    re.IGNORECASE,
)
LOGIN_RE = re.compile(r"^(Log ?In|Login|Entrar)$", re.IGNORECASE)
UPGRADE_RE = re.compile(
    r"^(Upgrade|Atualizar|Atualizar Firmware|Upgrade Firmware)$", re.IGNORECASE
)
CONFIRM_RE = re.compile(
    r"^(Upgrade|Atualizar|Yes|Sim|OK|Confirm|Confirmar)$", re.IGNORECASE
)


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
        die(
            f"BUILD={value}; não existe BUILD - 1 válido para upload. "
            "É necessário pelo menos BUILD=2."
        )
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
            f"--build {build} ainda não é um build concluído segundo BUILD={next_build}. "
            f"O maior build elegível é {next_build - 1}."
        )

    path = REPO_ROOT / "work" / f"Archer-AX53-NetBird-build-{build}.bin"
    if not path.is_file():
        die(
            f"firmware do build {build} não encontrado: {path}\n"
            f"BUILD atual={next_build}; esperado por padrão: BUILD - 1 = {next_build - 1}"
        )

    size = path.stat().st_size
    # A firmware image is tens of MiB. This threshold only rejects obvious
    # empty/truncated artifacts without hard-coding a stock-version-specific size.
    if size < 1024 * 1024:
        die(f"firmware parece vazio/truncado ({size} bytes): {path}")

    return FirmwareInfo(build=build, path=path.resolve(), size=size, sha256=sha256_file(path))


def parse_router_target(router_url: str) -> tuple[str, int]:
    parsed = urlparse(router_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        die(f"--router-url inválida: {router_url!r}; use http://host ou https://host")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    return parsed.hostname, port


def tcp_open(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def require_router_reachable(host: str, port: int) -> None:
    if not tcp_open(host, port):
        die(
            f"roteador não está acessível em {host}:{port}. "
            "ABORT antes de autenticar ou enviar firmware."
        )


def wait_for_reboot(host: str, port: int, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    print(f"[reboot] aguardando {host}:{port} sair do ar ...")

    down_seen = False
    while time.monotonic() < deadline:
        if not tcp_open(host, port, timeout=1.0):
            down_seen = True
            print("[reboot] queda do serviço detectada; firmware entrou em reboot.")
            break
        time.sleep(2)

    if not down_seen:
        die(
            "o serviço Web não saiu do ar dentro do timeout; "
            "não é possível confirmar que o upgrade/reboot iniciou."
        )

    print(f"[reboot] aguardando {host}:{port} voltar ...")
    while time.monotonic() < deadline:
        if tcp_open(host, port, timeout=1.0):
            print("[reboot] serviço Web voltou a aceitar conexões.")
            return
        time.sleep(3)

    die(
        f"roteador não voltou em {host}:{port} dentro de {timeout}s. "
        "Não interrompa a energia; use console/recovery se necessário."
    )


def import_playwright():
    try:
        from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
        from playwright.sync_api import sync_playwright
    except ImportError:
        die(
            "Playwright não está instalado.\n"
            "Instale com:\n"
            "  python3 -m pip install --user playwright\n"
            "  python3 -m playwright install chromium"
        )
    return sync_playwright, PlaywrightTimeoutError


def all_frames(page):
    # page.frames is cheap and also covers router UIs that place content in frames.
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


def click_named(page, pattern: re.Pattern[str], *, timeout_ms: int = 8000):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            for role in ("button", "link", "tab"):
                try:
                    item = first_visible(frame.get_by_role(role, name=pattern))
                except Exception:
                    item = None
                if item is not None:
                    item.click()
                    return item

            try:
                item = first_visible(frame.get_by_text(pattern, exact=True))
            except Exception:
                item = None
            if item is not None:
                item.click()
                return item
        time.sleep(0.25)
    return None


def find_file_input(page):
    preferred = (
        'input[type="file"][accept*=".bin"]',
        'input[type="file"][accept*="octet"]',
        'input[type="file"]',
    )
    for selector in preferred:
        for frame in all_frames(page):
            loc = frame.locator(selector)
            try:
                if loc.count():
                    return loc.first
            except Exception:
                continue
    return None


def login_if_needed(page, password: str, username: str | None) -> None:
    password_input = visible_in_frames(page, 'input[type="password"]')
    if password_input is None:
        print("[login] campo de senha não encontrado; sessão pode já estar autenticada.")
        return

    if username:
        # Some TP-Link generations ask for a username; modern AX53 builds usually
        # use only a local-admin password. Fill only when explicitly requested.
        username_input = visible_in_frames(
            page,
            'input[type="text"], input[type="email"], input:not([type])',
        )
        if username_input is not None:
            username_input.fill(username)

    password_input.fill(password)
    if click_named(page, LOGIN_RE, timeout_ms=2500) is None:
        password_input.press("Enter")

    try:
        page.wait_for_load_state("domcontentloaded", timeout=8000)
    except Exception:
        pass
    page.wait_for_timeout(1800)

    still_visible = visible_in_frames(page, 'input[type="password"]')
    if still_visible is not None:
        body = ""
        try:
            body = page.locator("body").inner_text(timeout=2000)
        except Exception:
            pass
        if re.search(
            r"(incorrect|invalid|failed|wrong|incorret|inválid|falhou|senha)",
            body,
            re.IGNORECASE,
        ):
            die("login não foi aceito pela interface do AX53.")
        die("a tela de login permaneceu ativa; ABORT antes do upload.")

    print("[login] autenticação concluída.")


def navigate_to_firmware(page) -> None:
    print("[nav] abrindo Avançado / Advanced ...")
    if click_named(page, ADVANCED_RE, timeout_ms=10000) is None:
        # It may already be on the Advanced tree after a saved browser state.
        print("[nav] menu Avançado não localizado; tentando menu de sistema atual.")

    page.wait_for_timeout(700)

    print("[nav] abrindo Sistema / System Tools ...")
    if click_named(page, SYSTEM_RE, timeout_ms=8000) is None:
        # Some firmwares expose Firmware Upgrade directly below Advanced.
        print("[nav] menu Sistema não localizado; tentando Firmware Upgrade diretamente.")

    page.wait_for_timeout(700)

    print("[nav] abrindo Atualização de Firmware / Firmware Upgrade ...")
    if click_named(page, FIRMWARE_RE, timeout_ms=10000) is None:
        die(
            "não encontrei o item Firmware Upgrade/Atualização de Firmware. "
            "A UI pode ter mudado; rode novamente com --headed e veja o screenshot de erro."
        )

    page.wait_for_timeout(1200)


def wait_upgrade_button(page, timeout_ms: int = 60000):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        for frame in all_frames(page):
            for role in ("button", "link"):
                try:
                    loc = frame.get_by_role(role, name=UPGRADE_RE)
                    count = loc.count()
                except Exception:
                    continue
                for idx in range(count):
                    item = loc.nth(idx)
                    try:
                        if item.is_visible() and item.is_enabled():
                            return item
                    except Exception:
                        continue
        time.sleep(0.5)
    return None


def click_confirmation(page) -> bool:
    # Prefer buttons inside an actual dialog to avoid clicking a cloud-update
    # control elsewhere on the firmware page.
    for frame in all_frames(page):
        try:
            dialogs = frame.get_by_role("dialog")
            for d_idx in range(dialogs.count()):
                dialog = dialogs.nth(d_idx)
                if not dialog.is_visible():
                    continue
                buttons = dialog.get_by_role("button", name=CONFIRM_RE)
                for b_idx in range(buttons.count() - 1, -1, -1):
                    button = buttons.nth(b_idx)
                    if button.is_visible() and button.is_enabled():
                        button.click()
                        return True
        except Exception:
            pass

    # TP-Link custom modal implementations don't always expose ARIA dialog roles.
    # In that case the confirmation button is normally appended later in DOM;
    # choose the last visible exact-name match.
    for frame in all_frames(page):
        try:
            buttons = frame.get_by_role("button", name=CONFIRM_RE)
            candidates = []
            for idx in range(buttons.count()):
                item = buttons.nth(idx)
                if item.is_visible() and item.is_enabled():
                    candidates.append(item)
            if candidates:
                candidates[-1].click()
                return True
        except Exception:
            continue
    return False


def screenshot(page, name: str) -> Path | None:
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)
    out = DEBUG_DIR / name
    try:
        page.screenshot(path=str(out), full_page=True)
        return out
    except Exception:
        return None


def run_browser(args, firmware: FirmwareInfo, password: str) -> None:
    sync_playwright, PlaywrightTimeoutError = import_playwright()
    host, port = parse_router_target(args.router_url)

    require_router_reachable(host, port)
    DEBUG_DIR.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=not args.headed)
        context = browser.new_context(
            ignore_https_errors=True,
            viewport={"width": 1440, "height": 1000},
        )
        page = context.new_page()
        page.set_default_timeout(args.ui_timeout * 1000)

        try:
            print(f"[router] abrindo {args.router_url}")
            page.goto(args.router_url, wait_until="domcontentloaded")

            login_if_needed(page, password, args.username)
            navigate_to_firmware(page)

            file_input = find_file_input(page)
            if file_input is None:
                die(
                    "input de firmware (input[type=file]) não encontrado. "
                    "ABORT antes de qualquer ação destrutiva."
                )

            print(f"[upload] selecionando {firmware.path.name}")
            file_input.set_input_files(str(firmware.path))
            page.wait_for_timeout(1200)

            try:
                value = file_input.input_value()
            except Exception:
                value = ""
            if firmware.path.name not in value and value:
                die(
                    f"a UI associou um arquivo inesperado ao input: {value!r}; "
                    "ABORT antes do Upgrade."
                )

            upgrade_button = wait_upgrade_button(page)
            if upgrade_button is None:
                die(
                    "arquivo foi selecionado, mas o botão Upgrade/Atualizar "
                    "não ficou disponível dentro de 60s."
                )

            ready_shot = screenshot(page, f"build-{firmware.build}-ready.png")
            if ready_shot:
                print(f"[debug] screenshot pré-upgrade: {ready_shot}")

            if not args.apply:
                print(
                    "\nSTOP POINT: firmware selecionado e botão Upgrade disponível, "
                    "mas --apply não foi informado.\n"
                    "Nenhuma atualização foi iniciada."
                )
                return

            print("[apply] --apply presente: iniciando Upgrade ...")
            upgrade_button.click()

            # Keep Chromium alive while the firmware upload/validation is in flight.
            # Closing the browser too early can abort a multipart upload before the
            # router receives the complete image.
            confirm_deadline = time.monotonic() + 90
            confirmation_sent = False
            reboot_started = False
            while time.monotonic() < confirm_deadline:
                if not tcp_open(host, port, timeout=1.0):
                    reboot_started = True
                    print("[apply] Web UI caiu; o upgrade/reboot já iniciou sem confirmação adicional.")
                    break
                if click_confirmation(page):
                    confirmation_sent = True
                    print("[apply] confirmação do modal enviada.")
                    break
                page.wait_for_timeout(500)

            if not confirmation_sent and not reboot_started:
                die(
                    "após clicar Upgrade, o roteador permaneceu online e nenhum "
                    "modal de confirmação apareceu em 90s. ABORT sem fechar a "
                    "sessão prematuramente; use --headed para inspecionar a UI."
                )

            if not args.no_wait_reboot:
                # Deliberately wait with the browser/context still alive so any
                # pending upload request is not cancelled by browser shutdown.
                wait_for_reboot(host, port, args.reboot_timeout)

        except SystemExit:
            raise
        except PlaywrightTimeoutError as exc:
            shot = screenshot(page, f"failed-build-{firmware.build}-{int(time.time())}.png")
            extra = f" Screenshot: {shot}" if shot else ""
            die(f"timeout na UI do AX53: {exc}.{extra}")
        except Exception as exc:
            shot = screenshot(page, f"failed-build-{firmware.build}-{int(time.time())}.png")
            extra = f" Screenshot: {shot}" if shot else ""
            die(f"falha na automação da UI: {type(exc).__name__}: {exc}.{extra}")
        finally:
            try:
                context.close()
            finally:
                browser.close()

def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Upload do firmware AX53 pelo Web UI stock. "
            "Por padrão usa o último build concluído (BUILD - 1)."
        )
    )
    parser.add_argument(
        "--router-url",
        default=DEFAULT_ROUTER_URL,
        help=f"URL da UI do roteador (default: {DEFAULT_ROUTER_URL})",
    )
    parser.add_argument(
        "--build-file",
        type=Path,
        default=REPO_ROOT / "BUILD",
        help="arquivo contador BUILD (default: <repo>/BUILD)",
    )
    parser.add_argument(
        "--build",
        type=int,
        help="reflash explícito de um build concluído; default é BUILD - 1",
    )
    parser.add_argument(
        "--username",
        help="usuário da UI quando o firmware exigir; não é assumido por padrão",
    )
    parser.add_argument(
        "--password-env",
        default="AX53_PASSWORD",
        help="nome da variável de ambiente da senha (default: AX53_PASSWORD)",
    )
    parser.add_argument(
        "--headed",
        action="store_true",
        help="abre o Chromium visível para diagnóstico",
    )
    parser.add_argument(
        "--ui-timeout",
        type=int,
        default=15,
        help="timeout padrão da UI em segundos (default: 15)",
    )
    parser.add_argument(
        "--reboot-timeout",
        type=int,
        default=600,
        help="timeout total para detectar reboot/retorno (default: 600s)",
    )
    parser.add_argument(
        "--no-wait-reboot",
        action="store_true",
        help="não monitora a queda/retorno da UI depois de --apply",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="AUTORIZA clicar Upgrade/confirmar e iniciar o flash",
    )
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
    print(f"Mode       : {'APPLY / FLASH' if args.apply else 'VALIDATE ONLY / STOP BEFORE UPGRADE'}")

    password = os.environ.get(args.password_env)
    if password is None:
        password = getpass.getpass("Senha da UI do AX53: ")
    if not password:
        die("senha vazia; ABORT.")

    run_browser(args, firmware, password)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
