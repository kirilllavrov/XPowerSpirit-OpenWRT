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
import concurrent.futures
import json
import os
import random
import socket
import ssl
import struct
import subprocess
import sys
import time

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


# -----------------------------
#   ОТБОР BYPASS-УЗЛОВ
# -----------------------------
LEDGER_VERSION = 1
LEDGER_FAIL_LIMIT = 3


def node_key(ob: dict) -> str:
    """
    Идентичность узла для журнала: адрес:порт + SNI.

    В реальной подписке один и тот же IP используется узлами с разными SNI
    (www.vk.com / yandex.ru) — оператор фильтрует по SNI, поэтому «работает
    или нет» относится к паре (IP, SNI), а не к адресу.
    """
    vnext = ((ob.get("settings") or {}).get("vnext") or [{}])[0]
    addr = vnext.get("address") or ""
    port = vnext.get("port") or 0
    stream = ob.get("streamSettings") or {}
    sni = ((stream.get("realitySettings") or {}).get("serverName")
           or (stream.get("tlsSettings") or {}).get("serverName") or "")
    return f"{addr}:{port}|{sni}"


def bypass_nodes(config_path: str, pattern: str) -> list:
    """Прокси-узлы из готового профиля, чей тег содержит pattern."""
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (OSError, ValueError) as e:
        log(f"[X] Не удалось прочитать {config_path}: {e}")
        return []
    pat = (pattern or "").lower()
    nodes = []
    for ob in cfg.get("outbounds") or []:
        if (ob.get("protocol") or "") in ("freedom", "blackhole", "dns", "loopback"):
            continue
        if pat and pat not in str(ob.get("tag") or "").lower():
            continue
        key = node_key(ob)
        if key.startswith(":"):
            continue
        nodes.append(ob)
    return nodes


def load_ledger(path: str) -> dict:
    """Журнал рабочих узлов; при чтении ошибки — пустой."""
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("networks"), dict):
            return data
    except (OSError, ValueError):
        pass
    return {"version": LEDGER_VERSION, "networks": {}}


def save_ledger(path: str, ledger: dict, max_per_network: int) -> None:
    """Чистка и атомарная запись журнала."""
    networks = ledger.get("networks") or {}
    for net in list(networks):
        block = networks[net] or {}
        nodes = [n for n in block.get("nodes", [])
                 if int(n.get("fail_count", 0)) < LEDGER_FAIL_LIMIT]
        nodes.sort(key=lambda n: n.get("ok_at", 0), reverse=True)
        block["nodes"] = nodes[:max_per_network]
        block["updated"] = int(time.time())
        if not nodes:
            networks.pop(net, None)
    tmp = f"{path}.tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(ledger, f, ensure_ascii=False, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError as e:
        log(f"[!] Не удалось записать {path}: {e}")


def detect_network_key() -> str:
    """
    Грубый признак сети оператора — первые два октета WAN-адреса.
    Нужен потому, что у разных операторов работают разные bypass-узлы.
    """
    ip = ""
    try:
        raw = subprocess.run(["ubus", "call", "network.interface.wan", "status"],
                             capture_output=True, timeout=5).stdout
        data = json.loads(raw or b"{}")
        addrs = ((data.get("data") or {}).get("ipv4-address") or [])
        if addrs:
            ip = str(addrs[0].get("address") or "")
    except (OSError, ValueError, subprocess.SubprocessError):
        pass

    if not ip:
        try:
            out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"],
                                 capture_output=True, timeout=5).stdout.decode()
            toks = out.split()
            if "src" in toks:
                ip = toks[toks.index("src") + 1]
        except (OSError, subprocess.SubprocessError):
            pass

    parts = [p for p in ip.split(".") if p.isdigit()]
    return ".".join(parts[:2]) if len(parts) >= 2 else "unknown"


def probe_node(ob: dict, mark: int, timeout: float) -> dict:
    """
    Проверка узла напрямую (SO_MARK обходит TProxy).

    reality проверяется только TCP-коннектом: сервер подставляет чужой
    сертификат, и полноценная TLS-проверка всегда дала бы ложный отказ.
    """
    vnext = ((ob.get("settings") or {}).get("vnext") or [{}])[0]
    addr = str(vnext.get("address") or "")
    port = int(vnext.get("port") or 0)
    stream = ob.get("streamSettings") or {}
    security = str(stream.get("security") or "none").lower()
    sni = ((stream.get("realitySettings") or {}).get("serverName")
           or (stream.get("tlsSettings") or {}).get("serverName") or "")

    res = {"tag": ob.get("tag"), "key": node_key(ob), "ok": False, "error": None}
    if not addr or not port:
        res["error"] = "no-endpoint"
        return res

    ips = resolve(addr)
    if not ips and addr.replace(".", "").isdigit():
        ips = [addr]
    last = "connect"
    for ip in ips[:3]:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if mark:
                sock.setsockopt(socket.SOL_SOCKET, SO_MARK, mark)
            sock.settimeout(timeout)
            sock.connect((ip, port))
            if security == "tls" and sni:
                # интересует только завершённость хендшейка, не валидность сертификата
                sock = ssl._create_unverified_context().wrap_socket(sock, server_hostname=sni)
            res["ok"] = True
            return res
        except ssl.SSLError as e:
            last = f"tls:{e.__class__.__name__}"
        except OSError as e:
            last = f"net:{e.__class__.__name__}"
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
    res["error"] = last
    return res


def ledger_update(ledger: dict, net: str, results: list) -> None:
    """Успехи закрепляем, неудачи копим и чистим при 3 подряд."""
    block = ledger.setdefault("networks", {}).setdefault(net, {"nodes": []})
    by_key = {n.get("key"): n for n in block.get("nodes", []) if n.get("key")}
    now = int(time.time())

    for res in results:
        node = by_key.get(res["key"])
        if res["ok"]:
            if node is None:
                node = {"key": res["key"], "tag": res["tag"], "fail_count": 0}
                by_key[res["key"]] = node
            node["ok_at"] = now
            node["tag"] = res["tag"]
            node["fail_count"] = 0
        elif node is not None:
            node["fail_count"] = int(node.get("fail_count", 0)) + 1

    block["nodes"] = list(by_key.values())
    block["updated"] = now


def select_nodes(args) -> int:
    """Режим --select-nodes: отобрать рабочие bypass-узлы и обновить журнал."""
    mark = 0 if args.no_mark else max(0, args.mark)
    nodes = bypass_nodes(args.from_config, args.tag_pattern)
    if not nodes:
        log(f"[X] В {args.from_config} нет узлов с '{args.tag_pattern}'")
        return 2

    ledger = load_ledger(args.ledger)
    net = args.network or detect_network_key()
    known = {n.get("key") for n in
             ((ledger.get("networks") or {}).get(net) or {}).get("nodes", [])}
    # Сначала проверяем то, что уже работало в этой сети
    ordered = sorted(nodes, key=lambda ob: node_key(ob) not in known)

    selected, failed, results = [], [], []
    workers = max(1, args.workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        idx = 0
        while idx < len(ordered) and len(selected) < args.want:
            chunk = ordered[idx:idx + workers]
            idx += workers
            futures = {pool.submit(probe_node, ob, mark, args.timeout): ob for ob in chunk}
            for fut in concurrent.futures.as_completed(futures):
                res = fut.result()
                results.append(res)
                (selected if res["ok"] else failed).append(res)

    ledger_update(ledger, net, results)
    save_ledger(args.ledger, ledger, max(1, args.ledger_max))

    # В профиль берём только need-узлов, но в журнал попадают все успешные
    selected = selected[:max(1, args.want)]

    out = {
        "network": net,
        "ts": int(time.time()),
        "pattern": args.tag_pattern,
        "want": args.want,
        "candidates": len(nodes),
        "probed": len(results),
        "selected": selected,
        "failed": failed,
    }
    try:
        with open(args.out, "w") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
            f.write("\n")
    except OSError as e:
        log(f"[X] Не удалось записать {args.out}: {e}")
        return 2

    log(f"[i] сеть {net}: проверено {len(results)} из {len(nodes)}, "
        f"рабочих {len(selected)} (нужно {args.want})")
    for res in selected:
        log(f"    OK   {res['tag']}  {res['key']}")
    for res in failed[:5]:
        log(f"    FAIL {res['tag']}  {res['key']}  {res['error']}")

    return 0 if selected else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Проба доступности: normal / bs / unknown")
    parser.add_argument("--json", action="store_true", help="машиночитаемый вывод")
    parser.add_argument("--mark", type=int, default=2,
                        help="SO_MARK для обхода TProxy (0 — не ставить, по умолчанию 2)")
    parser.add_argument("--no-mark", action="store_true", help="не ставить SO_MARK (для тестов)")
    parser.add_argument("--timeout", type=float, default=4.0, help="таймаут одной пробы, с")
    parser.add_argument("--dns-server", default="",
                        help="резолвить пробы напрямую через этот DNS (например 77.88.8.8)")
    parser.add_argument("--select-nodes", action="store_true",
                        help="отобрать рабочие bypass-узлы и обновить журнал")
    parser.add_argument("--from", dest="from_config", default="/etc/xray/config.normal.json",
                        help="профиль, из которого берутся узлы (по умолчанию config.normal.json)")
    parser.add_argument("--tag-pattern", default="bypass",
                        help="подстрока тега bypass-узла (по умолчанию bypass)")
    parser.add_argument("--out", default="/etc/xray/state/bs-nodes.json",
                        help="результат отбора")
    parser.add_argument("--ledger", default="/etc/xray/state/bs-good.json",
                        help="журнал рабочих узлов")
    parser.add_argument("--network", default="", help="ключ сети (по умолчанию — WAN /16)")
    parser.add_argument("--want", type=int, default=5, help="сколько рабочих узлов отобрать")
    parser.add_argument("--workers", type=int, default=8, help="параллельных проб")
    parser.add_argument("--ledger-max", type=int, default=10, help="записей журнала на сеть")
    args = parser.parse_args()

    if args.select_nodes:
        return select_nodes(args)

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
