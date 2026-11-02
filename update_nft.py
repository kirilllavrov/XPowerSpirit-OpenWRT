#!/usr/bin/env python3
"""
OpenWrt — обновление правил nftables для Xray TProxy.

Параметры (порт, метки, номер таблицы, подсети bypass, блокировка QUIC) берутся
из settings.json → tproxy и routing: те же значения попадают в config.json, и
рассогласование порта или метки даёт трафик «в никуда» без ошибок в журнале.

--dry-run — напечатать правила, ничего не применяя (используется в тестах).
"""
from __future__ import annotations

import json
import os
import random
import re
import shutil
import socket
import struct
import subprocess
import sys
import time

# Общие данные и проверки: те же значения читает генератор config.json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xray_settings import (  # noqa: E402  (путь к модулю выставляется выше)
    DEFAULT_SETTINGS_FILE,
    MODES,
    SettingsError,
    bypass_cidrs_defaults,
    defaults_section,
    field,
    mode_defaults,
    proxy_router_traffic_default,
    tproxy_defaults,
)

CONF = os.environ.get("XRAY_CONFIG_JSON", "/etc/xray/config.json")
SETTINGS_JSON = os.environ.get("XRAY_SETTINGS_JSON", DEFAULT_SETTINGS_FILE)
STATE_FILE = os.environ.get("XRAY_TPROXY_STATE", "/etc/xray/state/tproxy.state")
RT_TABLES = "/etc/iproute2/rt_tables"

TAG = "update-nft"
NFT_TABLE = "inet xray_self"
FW4_CHAIN = "inet fw4 xray_tproxy"
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
# Правило bypass, как его печатает `nft list chain`:
# `ip daddr { 1.1.1.1, 8.8.8.8 } return`; набор может печататься с переносами
BYPASS_RULE_RE = re.compile(r"ip daddr \{([^}]*)\}[ \t\n]*return")

DRY_RUN = False


# ============================================
#   ВЫВОД И ВНЕШНИЕ КОМАНДЫ
# ============================================

def log(msg: str) -> None:
    """Сообщение в журнал системы (syslog) и в stderr"""
    print(msg, file=sys.stderr)
    logger = shutil.which("logger")
    if logger:
        subprocess.run([logger, "-t", TAG, msg], check=False)


def _run(command: list, capture: bool, quiet: bool):
    """
    subprocess.run с одним ограничением: capture_output нельзя сочетать с
    явными stdout/stderr — Python 3.13 бросает ValueError. Поэтому вывод
    запрашивается через stdout=PIPE, а не через capture_output.
    """
    if capture:
        return subprocess.run(command, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL if quiet else None,
                              text=True)
    return subprocess.run(command, stderr=subprocess.DEVNULL if quiet else None)


def nft(*args: str, capture: bool = False, quiet: bool = False) -> str:
    """nft-команда: в dry-run печатается, иначе выполняется"""
    if DRY_RUN:
        if not capture:
            print("nft " + " ".join(args))
        return ""
    result = _run(["nft", *args], capture, quiet)
    return (result.stdout or "") if capture else ""


def ip(*args: str, capture: bool = False, quiet: bool = False) -> str:
    """ip-команда: в dry-run печатается, `rule del` всегда завершает цикл"""
    if DRY_RUN:
        if not capture:
            print("ip " + " ".join(args))
        return ""
    result = _run(["ip", *args], capture, quiet)
    return (result.stdout or "") if capture else ""


def ip_ok(*args: str) -> bool:
    """Проверка существования интерфейса: `ip link show` без вывода ошибок"""
    try:
        return subprocess.run(["ip", *args], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except FileNotFoundError:
        return False


def uci_get(*paths: str) -> str:
    """Первое непустое значение из UCI, иначе пустая строка"""
    for path in paths:
        try:
            result = subprocess.run(["uci", "-q", "get", path], capture_output=True,
                                    text=True)
        except FileNotFoundError:
            return ""
        value = (result.stdout or "").strip()
        if value:
            return value.split()[0]
    return ""


# ============================================
#   НАСТРОЙКИ
# ============================================

def read_settings() -> dict:
    """
    Параметры TProxy: значения settings.json перекрывают эталон
    settings.default.json. На загрузке settings.json может отсутствовать, поэтому
    дефолты берутся из эталона — второго набора чисел в коде нет. Нечисловое
    значение в существующем файле фатально: оно дало бы битые правила вместо
    понятного сообщения.
    """
    try:
        cfg = dict(tproxy_defaults())
        cfg["block_quic"] = defaults_section("routing").get("block_quic")
        cfg["bypass_cidrs"] = bypass_cidrs_defaults()
        # Режим меняет только набор правил: в gateway трафик самого шлюза обычно
        # не проксируется, а IPv6 от клиентов отбрасывается (иначе он идёт мимо
        # прокси — правила TProxy в проекте только для IPv4)
        cfg["mode"] = mode_defaults()
        cfg["proxy_router_traffic"] = proxy_router_traffic_default()
        if not isinstance(cfg["block_quic"], bool):
            raise SettingsError(
                f"routing.block_quic: ожидалось true или false"
            )
    except SettingsError as e:
        print(f"[X] {e}", file=sys.stderr)
        sys.exit(1)
    cfg.pop("dns_port", None)  # nftables DNS не перенаправляет, порт нужен только Xray

    if not os.path.isfile(SETTINGS_JSON):
        return cfg

    try:
        with open(SETTINGS_JSON) as f:
            data = json.load(f)
    except Exception as e:
        log(f"не удалось прочитать {SETTINGS_JSON} ({e}) — параметры из эталона")
        return cfg
    if not isinstance(data, dict):
        log(f"{SETTINGS_JSON}: ожидался объект — параметры из эталона")
        return cfg

    tproxy = data.get("tproxy") if isinstance(data.get("tproxy"), dict) else {}
    routing = data.get("routing") if isinstance(data.get("routing"), dict) else {}

    if "mode" in data:
        try:
            cfg["mode"] = field("str", enum=MODES).check("mode", data["mode"])
        except SettingsError as e:
            print(f"[X] {e}", file=sys.stderr)
            sys.exit(1)

    if "proxy_router_traffic" in tproxy:
        try:
            cfg["proxy_router_traffic"] = field("bool").check(
                "tproxy.proxy_router_traffic", tproxy["proxy_router_traffic"])
        except SettingsError as e:
            print(f"[X] {e}", file=sys.stderr)
            sys.exit(1)

    for key, maximum in (("port", 65535), ("mark", None), ("fwmark", None),
                         ("route_table", None)):
        if key not in tproxy:
            continue
        value = tproxy[key]
        try:
            cfg[key] = field("int", minimum=1, maximum=maximum).check(f"tproxy.{key}", value)
        except SettingsError as e:
            print(f"[X] {e}", file=sys.stderr)
            sys.exit(1)

    if "block_quic" in routing:
        if not isinstance(routing["block_quic"], bool):
            print(f"[X] В {SETTINGS_JSON} → routing.block_quic: ожидалось true или false",
                  file=sys.stderr)
            sys.exit(1)
        cfg["block_quic"] = routing["block_quic"]

    cidrs = routing.get("bypass_cidrs")
    if isinstance(cidrs, list) and cidrs:
        cfg["bypass_cidrs"] = field("cidr_list").check("routing.bypass_cidrs", cidrs)

    return cfg


# ============================================
#   АДРЕСА ИЗ CONFIG.JSON
# ============================================

def _config() -> dict:
    try:
        with open(CONF) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def is_ipv4(value) -> bool:
    if not isinstance(value, str) or not IPV4_RE.match(value):
        return False
    return all(int(part) <= 255 for part in value.split("."))


# Резолв адресов серверов прокси. Одиночный UDP-запрос теряется (проверено:
# один потерянный пакет оставлял адрес узла без bypass до следующего запуска),
# поэтому попытки повторяются в пределах общего бюджета на имя.
DNS_ATTEMPT_TIMEOUT = 2.0   # на одну попытку
DNS_TOTAL_TIMEOUT = 6.0     # на имя целиком, включая повторы
DNS_ATTEMPTS = 3


def _resolvers() -> list:
    """
    Резолверы, которым можно задать вопрос: те, что в /etc/resolv.conf (на
    OpenWrt это dnsmasq на 127.0.0.1), и резервный из settings.json
    → dns.dnsmasq_fallback. Резервный нужен при загрузке: init.d применяет
    правила до старта Xray, и первый сервер dnsmasq в этот момент молчит.
    """
    servers = []
    try:
        with open("/etc/resolv.conf", encoding="utf-8", errors="replace") as source:
            for line in source:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "nameserver" and is_ipv4(parts[1]):
                    servers.append(parts[1])
    except OSError:
        pass
    try:
        with open(SETTINGS_JSON, encoding="utf-8") as source:
            fallback = (json.load(source).get("dns") or {}).get("dnsmasq_fallback")
        if is_ipv4(fallback):
            servers.append(fallback)
    except (OSError, ValueError, AttributeError):
        pass
    return list(dict.fromkeys(servers)) or ["127.0.0.1"]


def _read_name(data: bytes, offset: int) -> tuple:
    """
    Читает имя в формате DNS и возвращает (метки, позиция после имени).
    Указатели сжатия (0xC0) поддерживаются: имя может ссылаться на уже
    прочитанную часть пакета.
    """
    labels = []
    end = offset
    jumped = False
    for _ in range(128):                            # защита от зацикливания
        if offset >= len(data):
            break
        length = data[offset]
        if length == 0:
            offset += 1
            if not jumped:
                end = offset
            break
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                break
            if not jumped:
                end = offset + 2
            jumped = True
            offset = ((length & 0x3F) << 8) | data[offset + 1]
            continue
        labels.append(data[offset + 1:offset + 1 + length])
        offset += length + 1
        if not jumped:
            end = offset
    return labels, end


def _name_text(labels: list) -> str:
    return ".".join(label.decode("ascii", "replace") for label in labels).lower()


def _dns_query_a(name: str, server: str) -> list:
    """
    A-записи имени одним UDP-запросом.

    socket.getaddrinfo здесь не годится: в OpenWrt стоит python3-light без модуля
    encodings.idna, и любой вызов падает с LookupError: unknown encoding: idna
    (проверено на устройстве).
    """
    labels = name.rstrip(".").split(".")
    if not labels or any(not label or len(label) > 63 for label in labels):
        return []
    txid = random.getrandbits(16)
    query = bytearray(struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0))
    for label in labels:
        query += bytes([len(label)]) + label.encode("ascii", "ignore")
    query += b"\x00" + struct.pack(">HH", 1, 1)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(DNS_ATTEMPT_TIMEOUT)
        sock.sendto(bytes(query), (server, 53))
        data, _ = sock.recvfrom(2048)
    if len(data) < 12 or struct.unpack(">H", data[:2])[0] != txid:
        return []                                   # чужой или испорченный ответ
    if data[3] & 0x0F:                              # rcode != 0: NXDOMAIN и прочее
        return []
    qdcount, ancount = struct.unpack(">HH", data[4:8])
    offset = 12
    if qdcount:                                     # проверяем, что спросили именно это
        labels, offset = _read_name(data, offset)
        if _name_text(labels) != name.rstrip(".").lower():
            return []
        offset += 4                                 # QTYPE + QCLASS
    found = []
    for _ in range(ancount):                        # ответы: тут только A
        if offset >= len(data):
            break
        _, offset = _read_name(data, offset)
        if offset + 10 > len(data):
            break
        rtype, _, _, rdlength = struct.unpack(">HHIH", data[offset:offset + 10])
        offset += 10
        if rtype == 1 and rdlength == 4 and offset + 4 <= len(data):
            found.append(".".join(str(byte) for byte in data[offset:offset + 4]))
        offset += rdlength
    return sorted(set(found))


def resolve_ipv4(host: str) -> list:
    """
    IPv4-адреса имени. Повторы нужны из-за потерь UDP: без них один потерянный
    пакет оставлял адрес узла без bypass (наблюдалось на устройстве).
    """
    deadline = time.monotonic() + DNS_TOTAL_TIMEOUT
    for server in _resolvers():
        for _ in range(DNS_ATTEMPTS):
            if time.monotonic() >= deadline:
                return []
            try:
                addrs = _dns_query_a(host, server)
            except (OSError, ValueError, struct.error):
                addrs = []
            if addrs:
                return addrs
    return []


def server_ips() -> list:
    """
    IPv4-адреса прокси-серверов: их трафик не должен попадать в TProxy, иначе
    соединение с сервером заворачивается само в себя. В подписках адрес часто
    задан доменом, поэтому имена резолвятся; если не удалось — работаем без них,
    правила TProxy от этого не перестают быть верными.
    """
    addrs = set()
    unresolved = []
    for ob in _config().get("outbounds", []):
        settings = ob.get("settings") if isinstance(ob, dict) else None
        if not isinstance(settings, dict):
            continue
        targets = list(settings.get("vnext") or [])
        # Shadowsocks/ Trojan задают сервер в servers[].address
        targets += list(settings.get("servers") or [])
        for target in targets:
            if not isinstance(target, dict):
                continue
            addr = target.get("address")
            if is_ipv4(addr):
                addrs.add(addr)
            elif isinstance(addr, str) and addr:
                resolved = resolve_ipv4(addr)
                if resolved:
                    addrs.update(resolved)
                else:
                    unresolved.append(addr)
    if unresolved:
        log("не удалось определить IP серверов прокси: " + ", ".join(unresolved) +
            " — их трафик пойдёт через TProxy")
    return sorted(addrs)


def dns_ips() -> list:
    """
    IP резолверов из config.json (dns.hosts и литеральные адреса в dns.servers):
    запросы DoH должны идти мимо TProxy, иначе получается петля.
    """
    dns = _config().get("dns") or {}
    ips = set()
    hosts = dns.get("hosts") if isinstance(dns.get("hosts"), dict) else {}
    for value in hosts.values():
        for addr in (value if isinstance(value, list) else [value]):
            if is_ipv4(addr):
                ips.add(addr)
    for server in dns.get("servers") or []:
        addr = server.get("address") if isinstance(server, dict) else server
        if is_ipv4(addr):
            ips.add(addr)
    return sorted(ips)


# ============================================
#   ОТКАТ
# ============================================

def rollback(reason: str) -> None:
    """
    Снимает маркировку и правила. Иначе трафик роутера остаётся с fwmark без
    TProxy-правил: уходит в таблицу маршрутизации → lo и теряется, роутер
    остаётся без интернета.
    """
    log(reason)
    print(f"[X] {reason}", file=sys.stderr)
    nft("delete", "table", NFT_TABLE, quiet=True)
    nft("flush", "chain", FW4_CHAIN, quiet=True)
    nft("delete", "chain", FW4_CHAIN, quiet=True)
    while ip_del_rule_true(CFG["fwmark"], CFG["route_table"]):
        pass
    ip("route", "flush", "table", str(CFG["route_table"]), quiet=True)
    print("[X] Правила TProxy откатены, трафик идёт напрямую", file=sys.stderr)
    sys.exit(1)


def ip_del_rule_true(fwmark: int, table: int) -> bool:
    """`ip rule del` в цикле: True, пока правило существовало"""
    if DRY_RUN:
        print(f"ip rule del fwmark {fwmark} table {table}")
        return False
    return subprocess.run(["ip", "rule", "del", "fwmark", str(fwmark),
                           "table", str(table)],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


# ============================================
#   ПРИМЕНЕНИЕ ПРАВИЛ
# ============================================

def detect_lan() -> str:
    if ip_ok("link", "show", "br-lan"):
        return "br-lan"
    return uci_get("network.lan.device", "network.lan.ifname") or "br-lan"


def detect_optional(ifname: str, uci_keys: tuple) -> str:
    if ip_ok("link", "show", ifname):
        return ifname
    return uci_get(*uci_keys)


def write_state(fwmark: int, table: int) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        f.write(f"{fwmark} {table}\n")


def cleanup_previous_state(fwmark: int, table: int) -> None:
    """
    При смене tproxy.fwmark / tproxy.route_table старые ip rule и таблица
    маршрутизации остались бы висеть в системе.
    """
    if not os.path.isfile(STATE_FILE):
        return
    try:
        with open(STATE_FILE) as f:
            old_fwmark, old_table = (f.read().split() + ["", ""])[:2]
    except OSError:
        return
    if not old_fwmark.isdigit() or not old_table.isdigit():
        return
    if int(old_fwmark) == fwmark and int(old_table) == table:
        return
    while ip_del_rule_true(int(old_fwmark), int(old_table)):
        pass
    ip("route", "flush", "table", old_table, quiet=True)
    log(f"сняты правила прежней конфигурации: fwmark {old_fwmark} → table {old_table}")


def update_rt_tables(table: int) -> None:
    """
    Имя таблицы для `ip rule show`: без него печатается номер, а после смены
    номера старое имя осталось бы висеть.
    """
    if not os.path.isfile(RT_TABLES):
        return
    with open(RT_TABLES) as f:
        lines = f.read().splitlines()
    if any(re.match(rf"^{table}\s+xray$", line) for line in lines):
        return
    lines = [line for line in lines if not re.search(r"\sxray$", line)]
    lines.append(f"{table} xray")
    with open(RT_TABLES, "w") as f:
        f.write("\n".join(lines) + "\n")


def ensure_fw4_chain() -> None:
    """Цепочка xray_tproxy в fw4 с jump из prerouting"""
    listing = nft("list", "chain", FW4_CHAIN, capture=True, quiet=True)
    if "chain xray_tproxy" in listing:
        nft("flush", "chain", FW4_CHAIN)
    else:
        nft("add", "chain", FW4_CHAIN)
    # fw4 пересобирает свои цепочки при каждом reload (`ifup`, `service firewall
    # reload`, смена UCI): jump пропадает, а наша цепочка остаётся. Без jump
    # трафик уходит мимо прокси молча, поэтому проверяем его всегда, а не только
    # при создании цепочки.
    prerouting = nft("list", "chain", "inet fw4 prerouting", capture=True, quiet=True)
    if "jump xray_tproxy" not in prerouting:
        nft("add", "rule", "inet", "fw4", "prerouting", "jump", "xray_tproxy")


def apply_rules(lan: str, guest: str, iot: str) -> None:
    port, mark = CFG["port"], CFG["mark"]
    fwmark, table = CFG["fwmark"], CFG["route_table"]
    bypass = ", ".join(CFG["bypass_cidrs"])
    dns_list = ",".join(RESOLVERS)

    # ---------- PREROUTING (xray_tproxy) ----------
    # Пакеты, уже отмаркированные Xray, пропускаем — защита от петель
    nft("add", "rule", "inet", "fw4", "xray_tproxy", "meta", "mark", str(mark), "return")
    nft("add", "rule", "inet", "fw4", "xray_tproxy", "ip", "daddr", "{", bypass, "}", "return")
    if dns_list:
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "ip", "daddr", "{", dns_list, "}",
            "return")
    nft("add", "rule", "inet", "fw4", "xray_tproxy", "udp", "dport", "{", "67,", "68", "}",
        "return")
    for addr in SERVER_IPS:
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "ip", "daddr", addr, "return")
    if guest:
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "iifname", guest, "return")
    if iot:
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "iifname", iot, "return")

    # QUIC блокируется ДО TProxy, иначе пакет уйдёт в Xray до проверки.
    # Тот же переключатель (routing.block_quic) убирает правило и из config.json
    if CFG["block_quic"]:
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "iifname", lan,
            "udp", "dport", "443", "drop")

    # В gateway-режиме IPv6 клиентам раздаёт основной роутер, а правила TProxy
    # здесь только для IPv4 — без этого правила IPv6-трафик уходил бы мимо прокси
    if CFG["mode"] == "gateway":
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "iifname", lan,
            "meta", "nfproto", "ipv6", "drop")

    for proto in ("tcp", "udp"):
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "iifname", lan,
            "meta", "l4proto", proto, "tproxy", "ip", "to", f"127.0.0.1:{port}",
            "meta", "mark", "set", str(fwmark), "accept")

    if not CFG["proxy_router_traffic"]:
        # Таблица могла остаться от прежней настройки или другого режима
        nft("delete", "table", NFT_TABLE, quiet=True)
        return

    # Трафик самого роутера приходит сюда уже отмаркированным из xray_self
    for proto in ("tcp", "udp"):
        nft("add", "rule", "inet", "fw4", "xray_tproxy", "meta", "mark", str(fwmark),
            "meta", "l4proto", proto, "tproxy", "ip", "to", f"127.0.0.1:{port}", "accept")

    # ---------- OUTPUT (трафик самого роутера) ----------
    # Отдельная таблица с type route hook output priority mangle: в цепочке fw4
    # (type filter) mark не влияет на маршрутизацию
    nft("delete", "table", NFT_TABLE, quiet=True)
    nft("add", "table", NFT_TABLE)
    nft("add", "chain", NFT_TABLE, "output",
        "{", "type", "route", "hook", "output", "priority", "mangle;",
        "policy", "accept;", "}")
    nft("add", "rule", NFT_TABLE, "output", "meta", "mark", str(mark), "return")
    nft("add", "rule", NFT_TABLE, "output", "ip", "daddr", "{", bypass, "}", "return")
    if dns_list:
        nft("add", "rule", NFT_TABLE, "output", "ip", "daddr", "{", dns_list, "}", "return")
    nft("add", "rule", NFT_TABLE, "output", "udp", "dport", "{", "67,", "68", "}", "return")
    for addr in SERVER_IPS:
        nft("add", "rule", NFT_TABLE, "output", "ip", "daddr", addr, "return")
    # fwmark → table: пакет возвращается в prerouting, где его ловит TProxy
    for proto in ("tcp", "udp"):
        nft("add", "rule", NFT_TABLE, "output", "meta", "l4proto", proto,
            "meta", "mark", "set", str(fwmark))


def bypass_targets(chain_listing: str) -> set:
    """
    Адреса из правил `ip daddr { … } return` — bypass-список цепочки.
    Поиск подстроки здесь не годится: тот же IP встречается и в правиле для
    серверов прокси, и в правиле без `return`, поэтому разбирается набор адресов.
    """
    targets = set()
    for match in BYPASS_RULE_RE.finditer(chain_listing):
        targets.update(part.strip() for part in match.group(1).split(",") if part.strip())
    return targets


def verify_rules() -> None:
    """
    Проверяет, что ключевые правила реально применились: иначе init.d сочтёт
    правила готовыми и запустит Xray без TProxy (прокси молча не работает).
    """
    port, mark = CFG["port"], CFG["mark"]
    fwmark, table = CFG["fwmark"], CFG["route_table"]

    chain = nft("list", "chain", FW4_CHAIN, capture=True, quiet=True)
    if f"tproxy ip to 127.0.0.1:{port}" not in chain:
        rollback(f"В цепочке xray_tproxy нет правила: tproxy ip to 127.0.0.1:{port}")
    if CFG["block_quic"] and "udp dport 443 drop" not in chain:
        rollback("В цепочке xray_tproxy нет правила: udp dport 443 drop")
    if not re.search(rf"mark (0x0*{mark}|{mark}) return", chain):
        rollback(f"В цепочке xray_tproxy нет защиты от петель (mark {mark} return)")
    bypass = bypass_targets(chain)
    missing = [address for address in RESOLVERS if address not in bypass]
    if missing:
        rollback("В цепочке xray_tproxy нет bypass для DNS-серверов ("
                 f"{', '.join(missing)})")
    # Адреса серверов прокси добавляются отдельными правилами (без набора { }),
    # поэтому ищутся по строке, а не через bypass_targets
    missing_servers = [address for address in SERVER_IPS
                       if not re.search(rf"ip daddr {re.escape(address)}\s+return", chain)]
    if missing_servers:
        rollback("В цепочке xray_tproxy нет bypass для серверов прокси ("
                 f"{', '.join(missing_servers)})")
    if CFG["mode"] == "gateway" and "meta nfproto ipv6 drop" not in chain:
        rollback("В цепочке xray_tproxy нет блокировки IPv6 от клиентов "
                 "(meta nfproto ipv6 drop)")

    # Трафик самого устройства проксируется только при proxy_router_traffic
    if not CFG["proxy_router_traffic"]:
        log("Xray TProxy rules applied (gateway: трафик шлюза не проксируется)"
            if CFG["mode"] == "gateway" else
            "Xray TProxy rules applied (без проксирования трафика устройства)")
        return

    self_chain = nft("list", "chain", NFT_TABLE, "output", capture=True, quiet=True)
    # nft печатает метку в hex с ведущими нулями: 0x00000001
    if f"mark set 0x{fwmark:08x}" not in self_chain:
        rollback(f"В цепочке xray_self нет правила маркировки (mark set {fwmark})")
    if "type route hook output priority mangle" not in self_chain:
        rollback("Цепочка xray_self должна быть type route hook output priority mangle")
    log("Xray TProxy rules applied")


def main() -> None:
    global DRY_RUN, CFG, SERVER_IPS, RESOLVERS

    args = sys.argv[1:]
    if args == ["--dry-run"]:
        DRY_RUN = True
    elif args:
        print(f"Использование: {sys.argv[0]} [--dry-run]", file=sys.stderr)
        sys.exit(1)

    CFG = read_settings()
    lan = detect_lan()
    if not DRY_RUN and not ip_ok("link", "show", lan):
        rollback(f"LAN-интерфейс '{lan or '<пусто>'}' не существует")
    guest = detect_optional("br-guest", ("network.guest.device", "network.guest.ifname"))
    iot = detect_optional("br-iot", ("network.iot.device", "network.iot.ifname"))

    SERVER_IPS = server_ips()
    RESOLVERS = dns_ips()
    if not RESOLVERS:
        log("DNS bypass list is empty — check dns.hosts/servers in config.json")

    fwmark, table = CFG["fwmark"], CFG["route_table"]
    by_iface = guest and ip_ok("link", "show", guest)
    by_iface_iot = iot and ip_ok("link", "show", iot)

    cleanup_previous_state(fwmark, table)

    # Policy routing: пакет с fwmark уходит в таблицу, где default → lo,
    # то есть возвращается в prerouting и попадает под TProxy
    while ip_del_rule_true(fwmark, table):
        pass
    ip("route", "flush", "table", str(table), quiet=True)
    ip("rule", "add", "fwmark", str(fwmark), "table", str(table))
    ip("route", "add", "local", "0.0.0.0/0", "dev", "lo", "table", str(table))

    if not DRY_RUN:
        write_state(fwmark, table)
        update_rt_tables(table)

    ensure_fw4_chain()
    apply_rules(lan, guest if by_iface else "", iot if by_iface_iot else "")

    if not DRY_RUN:
        verify_rules()


CFG = {}
SERVER_IPS = []
RESOLVERS = []

if __name__ == "__main__":
    main()
