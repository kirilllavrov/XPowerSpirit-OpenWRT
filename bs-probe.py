#!/usr/bin/env python3
"""
Проба доступности для определения режима белых списков (БС) у мобильного оператора.

Логика:
  * внешняя проба (gstatic generate_204) проходит  → normal
  * внешняя проба не проходит, а БС-проба (ya.ru/vk.com) проходит → bs
  * не прошло ничего                               → unknown (нет линка / лежит Xray)

ВАЖНО: пробы ставят SO_MARK = 2 на сокет. В nft-правилах проекта обе цепочки
начинаются с `meta mark 2 return`, поэтому такой пакет уходит напрямую и не
перехватывается TProxy. Без отметки проба пошла бы через прокси и всегда
показывала бы «доступно».

Зависимости: только stdlib. Для HTTPS-проб нужен модуль `ssl`.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import ssl
import struct
import sys

# Путь переопределяется в тестах (на устройстве — /etc/xray/settings.json)
SETTINGS_FILE = os.environ.get("BS_PROBE_SETTINGS", "/etc/xray/settings.json")

# socket.SO_MARK есть в Python 3.6+ на Linux; значение одинаковое для всех
SO_MARK = getattr(socket, "SO_MARK", 36)

DEFAULT_EXTERNAL = [
    {"host": "connectivitycheck.gstatic.com", "port": 80,
     "path": "/generate_204", "tls": False},
]
DEFAULT_BS = [
    {"host": "ya.ru", "port": 443, "path": "/", "tls": True},
    {"host": "vk.com", "port": 443, "path": "/", "tls": True},
]

OK_STATUSES = {200, 204, 301, 302, 303, 307, 308}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


# -----------------------------
# DNS (только A, опционально мимо dnsmasq)
# -----------------------------
def _build_dns_query(name: str, qid: int) -> bytes:
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(
        bytes([len(part)]) + part.encode("idna")
        for part in name.rstrip(".").split(".")
        if part
    ) + b"\x00"
    return header + qname + struct.pack(">HH", 1, 1)


def _parse_dns_answer(data: bytes) -> list:
    """Минимальный разбор ответа: только A-записи, с поддержкой сжатия имён."""
    if len(data) < 12:
        return []
    _, _, qdcount, ancount = struct.unpack(">HHHH", data[:8])
    offset = 12

    def skip_name(pos: int) -> int:
        while pos < len(data):
            length = data[pos]
            if length == 0:
                return pos + 1
            if length & 0xC0 == 0xC0:  # указатель сжатия — имя кончается
                return pos + 2
            pos += 1 + length
        return pos

    for _ in range(qdcount):
        offset = skip_name(offset) + 4  # + qtype + qclass

    ips = []
    for _ in range(ancount):
        if offset >= len(data):
            break
        offset = skip_name(offset)
        if offset + 10 > len(data):
            break
        rtype, _rclass, _ttl, rdlength = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlength]
        offset += rdlength
        if rtype == 1 and rdlength == 4:
            ips.append(".".join(str(b) for b in rdata))
    return ips


def resolve_direct(host: str, server: str, mark: int, timeout: float) -> list:
    """A-запрос напрямую на указанный DNS-сервер (мимо dnsmasq и Xray)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        if mark:
            sock.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
        sock.settimeout(timeout)
        qid = random.randint(0, 0xFFFF)
        sock.sendto(_build_dns_query(host, qid), (server, 53))
        data, _ = sock.recvfrom(1500)
        return _parse_dns_answer(data)
    except OSError:
        return []
    finally:
        sock.close()


def resolve(host: str, dns_server: str = "", mark: int = 0, timeout: float = 3.0) -> list:
    """IP-адреса хоста: напрямую через dns_server либо системным резолвером."""
    if dns_server:
        ips = resolve_direct(host, dns_server, mark, timeout)
        if ips:
            return ips
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        return [info[4][0] for info in infos]
    except OSError as e:
        log(f"    DNS {host}: {e}")
        return []


# -----------------------------
# HTTP(S)-проба
# -----------------------------
def probe(item: dict, mark: int, timeout: float, dns_server: str = "") -> dict:
    """
    Проверяет доступность URL по host:port/path.

    Возвращает {"probe": "host:port", "ok": bool, "status": int|None, "error": str|None}.
    """
    host = item["host"]
    port = int(item.get("port", 443 if item.get("tls") else 80))
    path = item.get("path", "/")
    use_tls = bool(item.get("tls", False))
    label = f"{host}:{port}"
    result = {"probe": label, "ok": False, "status": None, "error": None}

    ips = resolve(host, dns_server, mark, timeout)
    if not ips:
        result["error"] = "dns"
        return result

    last_error = "connect"
    for ip in ips:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if mark:
                sock.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
            sock.settimeout(timeout)
            sock.connect((ip, port))
            if use_tls:
                ctx = ssl.create_default_context()
                sock = ctx.wrap_socket(sock, server_hostname=host)
            request = (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                "User-Agent: XPowerSpirit-probe/1.0\r\n"
                "Connection: close\r\n\r\n"
            )
            sock.sendall(request.encode())
            head = sock.recv(64).decode("latin1", "replace")
            parts = head.split(" ")
            status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            result["status"] = status or None
            result["ok"] = status in OK_STATUSES
            if not result["ok"]:
                result["error"] = f"http/{status or '?'}"
            return result
        except ssl.SSLError as e:
            last_error = f"tls:{e.__class__.__name__}"
        except OSError as e:
            last_error = f"net:{e.__class__.__name__}"
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass

    result["error"] = last_error
    return result


# -----------------------------
# Конфигурация проб
# -----------------------------
def load_probes() -> tuple:
    """Пробы из settings.json → bs, иначе значения по умолчанию."""
    external, whitelist = DEFAULT_EXTERNAL, DEFAULT_BS
    if os.path.isfile(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE) as f:
                conf = (json.load(f) or {}).get("bs") or {}
            external = conf.get("probe_external") or external
            whitelist = conf.get("probe_bs") or whitelist
        except (OSError, ValueError) as e:
            log(f"[!] Не удалось прочитать {SETTINGS_FILE}: {e}")
    return external, whitelist


def classify(external_ok: bool, bs_ok: bool) -> str:
    """Состояние сети: normal, bs или unknown (ничего не доступно)."""
    if external_ok:
        return "normal"
    if bs_ok:
        return "bs"
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Проба доступности: normal / bs / unknown")
    parser.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    parser.add_argument("--mark", type=int, default=2,
                        help="SO_MARK для обхода TProxy (0 — не ставить, по умолчанию 2)")
    parser.add_argument("--no-mark", action="store_true", help="не ставить SO_MARK (для тестов)")
    parser.add_argument("--timeout", type=float, default=4.0, help="таймаут одной пробы, с")
    parser.add_argument("--dns-server", default="",
                        help="резолвить пробы напрямую через этот DNS (например 77.88.8.8)")
    args = parser.parse_args()

    mark = 0 if args.no_mark else max(0, args.mark)
    external_probes, bs_probes = load_probes()

    external_results = [probe(p, mark, args.timeout, args.dns_server) for p in external_probes]
    bs_results = [probe(p, mark, args.timeout, args.dns_server) for p in bs_probes]

    external_ok = any(r["ok"] for r in external_results)
    bs_ok = any(r["ok"] for r in bs_results)
    state = classify(external_ok, bs_ok)

    if args.json:
        print(json.dumps({
            "state": state,
            "mark": mark,
            "external_ok": external_ok,
            "bs_ok": bs_ok,
            "external": external_results,
            "bs": bs_results,
        }, ensure_ascii=False))
    else:
        print(f"state={state} external_ok={int(external_ok)} bs_ok={int(bs_ok)} mark={mark}")
        for r in external_results + bs_results:
            print(f"  {r['probe']:<34} ok={int(r['ok'])} status={r['status']} error={r['error']}")

    return {"normal": 0, "bs": 1}.get(state, 2)


if __name__ == "__main__":
    sys.exit(main())
