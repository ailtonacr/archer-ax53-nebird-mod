#!/usr/bin/env python3
"""API-first firmware uploader for the stock TP-Link Archer AX53 UI backend.

Safety model:
  * reads BUILD and selects BUILD - 1 by default;
  * validates artifact existence, minimum size and SHA256 locally;
  * authenticates through the router's encrypted LuCI API using tplinkrouterc6u;
  * reads firmware metadata before upload;
  * uploads the image to the authenticated stock firmware endpoint;
  * STOPS after upload/pre-check and requires the literal token CONFIRMAR;
  * only then sends the stock upgrade operation and monitors reboot.

No password, stok, sysauth cookie or other secret is persisted by this script.
The stock API is undocumented, so endpoint/operation names are centralized and
can be overridden from the CLI without editing code. The defaults match the
modern AX53/AX-series LuCI contract discovered from the stock firmware family.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import socket
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROUTER_URL = "http://192.168.10.1"
DEFAULT_API_PATH = "admin/firmware?form=upgrade"
DEFAULT_UPLOAD_OPERATION = "upload"
DEFAULT_UPLOAD_FIELD = "file"
DEFAULT_FLASH_OPERATION = "upgrade"
CONFIRM_TOKEN = "CONFIRMAR"


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
        die(f"BUILD={value}; não existe BUILD - 1 válido.")
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
            f"--build {build} não é concluído segundo BUILD={next_build}; "
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


def wait_for_reboot(host: str, port: int, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    print(f"[reboot] aguardando {host}:{port} sair do ar ...")
    while time.monotonic() < deadline:
        if not tcp_open(host, port, timeout=1.0):
            print("[reboot] queda da Web UI detectada.")
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


def import_dependencies():
    try:
        import requests
        from tplinkrouterc6u import TplinkRouterProvider
    except ImportError as exc:
        die(
            f"dependência ausente: {exc}.\n"
            "Instale nesta virtualenv com:\n"
            "  python3 -m pip install tplinkrouterc6u requests"
        )
    return requests, TplinkRouterProvider


def get_private_auth(router) -> tuple[str, str | None]:
    """Return stok and sysauth from tplinkrouterc6u without logging either value."""
    stok = getattr(router, "_stok", None)
    sysauth = getattr(router, "_sysauth", None)
    if not stok:
        die(
            "a biblioteca autenticou, mas não expôs o stok esperado; "
            "ABORT sem tentar upload bruto."
        )
    return str(stok), str(sysauth) if sysauth else None


def api_read_firmware(router, api_path: str) -> dict:
    print(f"[api] lendo {api_path} ...")
    try:
        result = router.request(api_path, "operation=read", ignore_errors=True)
    except Exception as exc:
        die(f"falha ao ler metadata de firmware via API: {type(exc).__name__}: {exc}")

    if result is None:
        die("endpoint de firmware retornou resposta vazia; ABORT antes do upload.")
    print("[api] endpoint autenticado respondeu.")
    if isinstance(result, dict):
        # Print only non-secret firmware-ish metadata.
        safe = {
            k: v
            for k, v in result.items()
            if any(token in k.lower() for token in ("firmware", "hardware", "version", "upgrade", "time"))
        }
        if safe:
            print("[api] metadata:")
            print(json.dumps(safe, ensure_ascii=False, indent=2)[:4000])
    return result if isinstance(result, dict) else {"value": result}


def build_authenticated_url(router_url: str, stok: str, api_path: str) -> str:
    return f"{router_url.rstrip('/')}/cgi-bin/luci/;stok={stok}/{api_path.lstrip('/')}"


def upload_firmware_raw(
    requests,
    router,
    router_url: str,
    api_path: str,
    firmware: FirmwareInfo,
    upload_operation: str,
    upload_field: str,
    timeout: int,
) -> dict:
    """Upload through the authenticated LuCI multipart endpoint.

    Large firmware payloads are not sent through router.request(), because that
    method encrypts URL-encoded API payloads and is unsuitable for a ~40 MiB
    multipart body. Authentication is nevertheless the same stock session:
    stok in the URL plus sysauth cookie from the encrypted login handshake.
    """
    stok, sysauth = get_private_auth(router)
    url = build_authenticated_url(router_url, stok, api_path)

    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": f"{router_url.rstrip('/')}/webpages/index.html",
        "User-Agent": "AX53-Firmware-Uploader/1.0",
    }
    cookies = {"sysauth": sysauth} if sysauth else {}

    data = {"operation": upload_operation}
    print(
        f"[upload] enviando {firmware.path.name} ({firmware.size} bytes) "
        f"para o endpoint stock ..."
    )
    started = time.monotonic()
    try:
        with firmware.path.open("rb") as fh:
            files = {
                upload_field: (
                    firmware.path.name,
                    fh,
                    "application/octet-stream",
                )
            }
            response = requests.post(
                url,
                data=data,
                files=files,
                headers=headers,
                cookies=cookies,
                timeout=(10, timeout),
                verify=False,
            )
    except Exception as exc:
        die(f"falha durante upload HTTP: {type(exc).__name__}: {exc}")

    elapsed = time.monotonic() - started
    print(f"[upload] HTTP {response.status_code} em {elapsed:.1f}s")
    if response.status_code < 200 or response.status_code >= 300:
        die(f"upload rejeitado pelo roteador: HTTP {response.status_code}")

    text = (response.text or "").strip()
    if not text:
        # Some stock upload handlers intentionally return an empty body. Treat a
        # successful HTTP status as upload-complete, but never as flash approval.
        print("[upload] corpo de resposta vazio; upload HTTP concluído, flash ainda NÃO autorizado.")
        return {"http_status": response.status_code, "body": ""}

    try:
        parsed = response.json()
    except Exception:
        # Never echo arbitrary router HTML because it may contain session data.
        print("[upload] resposta não-JSON recebida; conteúdo omitido por segurança.")
        return {"http_status": response.status_code, "body_type": "non-json"}

    print("[upload] resposta JSON recebida.")
    return parsed if isinstance(parsed, dict) else {"value": parsed}


def precheck_after_upload(router, api_path: str) -> dict:
    """Ask the stock firmware controller to validate the uploaded image.

    The firmware backend itself exposes fwup_check internally. On web-facing
    builds this may be reachable as an operation on the same form. If the current
    firmware rejects that operation, we fail closed instead of guessing.
    """
    print("[check] solicitando validação stock do firmware ...")
    try:
        result = router.request(api_path, "operation=fwup_check", ignore_errors=True)
    except Exception as exc:
        die(f"pre-check stock falhou: {type(exc).__name__}: {exc}")

    if result is None:
        die("pre-check retornou resposta vazia; ABORT antes da confirmação final.")

    print("[check] resposta do pre-check recebida.")
    if isinstance(result, dict):
        print(json.dumps(result, ensure_ascii=False, indent=2)[:4000])
        # Explicit negative signals are always fatal. Unknown shapes are shown to
        # the operator but do not trigger the flash automatically.
        if result.get("success") is False:
            die("pre-check stock reportou success=false; ABORT.")
        for key in ("errorcode", "error_code", "code"):
            value = result.get(key)
            if value not in (None, 0, "0", "success", "ok"):
                die(f"pre-check stock retornou {key}={value!r}; ABORT.")
    return result if isinstance(result, dict) else {"value": result}


def ask_flash_confirmation(firmware: FirmwareInfo, router_url: str) -> bool:
    print("\n=== CONFIRMAÇÃO FINAL DE FLASH ===")
    print(f"Roteador : {router_url}")
    print(f"Build    : {firmware.build}")
    print(f"Arquivo  : {firmware.path.name}")
    print(f"Tamanho  : {firmware.size} bytes")
    print(f"SHA256   : {firmware.sha256}")
    print("\nO arquivo já foi enviado e passou pelo pre-check stock.")
    print("A próxima chamada é a operação destrutiva de upgrade.")
    print("Após confirmar, NÃO interrompa a alimentação do AX53.")
    answer = input(
        f"\nDigite {CONFIRM_TOKEN} para iniciar o flash, ou Enter para cancelar: "
    ).strip()
    return answer == CONFIRM_TOKEN


def flash(router, api_path: str, flash_operation: str) -> None:
    print(f"[flash] enviando operation={flash_operation} ...")
    try:
        # The request may drop because the router begins its reboot immediately.
        router.request(
            api_path,
            f"operation={flash_operation}",
            ignore_response=True,
            ignore_errors=True,
        )
    except Exception as exc:
        print(
            "[flash] conexão terminou durante a chamada de upgrade "
            f"({type(exc).__name__}); validarei pelo reboot."
        )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Uploader API-first do AX53. Usa BUILD - 1, faz login/API/upload/pre-check, "
            "e exige CONFIRMAR antes da operação final de flash."
        )
    )
    parser.add_argument("--router-url", default=DEFAULT_ROUTER_URL)
    parser.add_argument("--build-file", type=Path, default=REPO_ROOT / "BUILD")
    parser.add_argument("--build", type=int, help="reflash explícito de build já concluído")
    parser.add_argument("--username", default="admin")
    parser.add_argument("--password-env", default="AX53_PASSWORD")
    parser.add_argument("--api-path", default=DEFAULT_API_PATH)
    parser.add_argument("--upload-operation", default=DEFAULT_UPLOAD_OPERATION)
    parser.add_argument("--upload-field", default=DEFAULT_UPLOAD_FIELD)
    parser.add_argument("--flash-operation", default=DEFAULT_FLASH_OPERATION)
    parser.add_argument("--upload-timeout", type=int, default=180)
    parser.add_argument("--reboot-timeout", type=int, default=600)
    parser.add_argument(
        "--skip-precheck",
        action="store_true",
        help="não recomendado: pula fwup_check; ainda exige CONFIRMAR",
    )
    parser.add_argument(
        "--no-wait-reboot",
        action="store_true",
        help="não monitora queda/retorno da Web UI após a operação final",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    firmware = resolve_firmware(args.build_file.resolve(), args.build)
    host, port = parse_router_target(args.router_url)
    require_router_reachable(host, port)

    print("=== AX53 firmware uploader (API-first) ===")
    print(f"Target     : {args.router_url} ({host}:{port})")
    print(f"BUILD file : {args.build_file.resolve()}")
    print(f"Build      : {firmware.build}")
    print(f"Firmware   : {firmware.path}")
    print(f"Size       : {firmware.size} bytes")
    print(f"SHA256     : {firmware.sha256}")
    print(f"API path   : {args.api_path}")
    print("Mode       : API / STOP BEFORE FINAL UPGRADE")

    password = os.environ.get(args.password_env)
    if password is None:
        password = getpass.getpass("Senha LOCAL da UI do AX53: ")
    if not password:
        die("senha vazia; ABORT.")

    requests, TplinkRouterProvider = import_dependencies()
    # Local AX53 HTTP is expected; suppress only HTTPS warnings when verify=False.
    try:
        requests.packages.urllib3.disable_warnings(  # type: ignore[attr-defined]
            requests.packages.urllib3.exceptions.InsecureRequestWarning  # type: ignore[attr-defined]
        )
    except Exception:
        pass

    print("[auth] autenticando na API criptografada TP-Link ...")
    try:
        router = TplinkRouterProvider.get_client(
            args.router_url,
            password,
            args.username,
            verify_ssl=False,
            timeout=30,
        )
        router.authorize()
    except Exception as exc:
        die(f"autenticação API falhou: {type(exc).__name__}: {exc}")

    print(f"[auth] autenticado via {type(router).__name__}; sessão obtida.")

    try:
        api_read_firmware(router, args.api_path)
        upload_firmware_raw(
            requests,
            router,
            args.router_url,
            args.api_path,
            firmware,
            args.upload_operation,
            args.upload_field,
            args.upload_timeout,
        )

        if args.skip_precheck:
            print("[check] AVISO: pre-check foi pulado por --skip-precheck.")
        else:
            precheck_after_upload(router, args.api_path)

        if not ask_flash_confirmation(firmware, args.router_url):
            print("[confirm] flash CANCELADO; operação final não enviada.")
            return 0

        flash(router, args.api_path, args.flash_operation)

        if not args.no_wait_reboot:
            wait_for_reboot(host, port, args.reboot_timeout)

        print("[done] roteador voltou após a chamada de upgrade.")
        return 0
    except KeyboardInterrupt:
        print("\n[abort] cancelado pelo usuário. Se a operação final ainda não foi enviada, não há flash.")
        return 130
    finally:
        # Logout is intentionally best-effort: after a successful upgrade the
        # router may already be rebooting and the session endpoint unavailable.
        try:
            router.logout()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
