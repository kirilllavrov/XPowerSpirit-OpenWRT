#!/usr/bin/env python3
"""
Xray Config Generator for OpenWrt TProxy

Принимает унифицированный JSON из xray-sub-parser.py:
  {"hole": bool, "outbounds": [...]}

Специальная обработка "hole":
  Если в подписке обнаружен outbound с address="hole", генерируется DIRECT-конфиг
  (весь трафик идёт напрямую, прокси отключены). Это сигнал об окончании срока подписки.

Балансировка:
  Используется стратегия leastLoad с burstObservatory для выбора наиболее стабильного прокси.

Настройки:
  Читает /etc/xray/settings.json — единый конфигурационный файл.
"""

from __future__ import annotations

import json
import sys
import argparse
import os
import ipaddress

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# XRAY_SETTINGS_FILE — только для тестов и ручных прогонов вне устройства
SETTINGS_FILE = os.environ.get("XRAY_SETTINGS_FILE", "/etc/xray/settings.json")

# Эталон правил роутинга: из него доливаются недостающие ключи на устройстве
SETTINGS_DEFAULT_URL = ("https://raw.githubusercontent.com/kirilllavrov/"
                        "XPowerSpirit-OpenWRT/main/settings.default.json")

# Категория geosite с доменами проверки «какой у меня IP» (ifconfig.me, api.ipify.org,
# 2ip.ru и подобные). Провайдеры и сервисы используют их для детекта VPN, поэтому
# такие домены обязаны идти напрямую. Сами домены живут в geosite.dat, не в settings.json.
IP_CHECK_GEOSITE = "geosite:category-ipcheck"

# Правила роутинга задаются только в settings.json → routing (единственный источник:
# settings.default.json). Здесь — лишь перечень обязательных ключей: без них правила
# получились бы пустыми (RU-трафик ушёл бы в прокси, реклама не блокировалась), поэтому
# генератор отказывается работать, а не собирает тихо неверный конфиг.
ROUTING_CONFIG = {}

ROUTING_KEYS = (
    "domainStrategy",
    "doh_domains",
    "block_domains",
    "direct_ips",
    "direct_domains",
    "proxy_domains",
)

# Необязательные ключи routing: без них конфиг остаётся корректным, правило просто
# не создаётся. Обязательными их делать нельзя — старые settings.json на роутерах
# не содержат этих ключей, и генератор начал бы отказываться работать.
ROUTING_OPTIONAL_KEYS = {
    # Протоколы (sniffing), которым разрешён прямой выход — например bittorrent
    "direct_protocols": [],
    # QUIC (UDP/443) блокируется и в Xray, и в nftables — переключатель общий
    "block_quic": True,
}

# Значения, документированные для RuleObject.protocol
ROUTING_PROTOCOLS = ("http", "tls", "quic", "bittorrent")

# Подсети, которые nftables не заворачивает в TProxy (локальные и служебные)
DEFAULT_BYPASS_CIDRS = [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
]

# Пресеты журналирования Xray. Роутер пишет минимум (журналы живут в tmpfs, то есть
# в RAM), стенд в контейнере — подробно. Значения полей log.* — из официальной
# документации: access/error — путь, спецзначение "none" отключает журнал;
# loglevel — none|error|warning|info|debug, влияет только на журнал ошибок,
# а на access влияет только значение "none".
LOG_PRESETS = {
    "quiet": {"loglevel": "none", "access": "none", "error": "none"},
    "normal": {"loglevel": "warning", "access": "none", "error": "/tmp/log/xray-error.log"},
    "debug": {
        "loglevel": "info",
        "access": "/tmp/log/xray-access.log",
        "error": "/tmp/log/xray-error.log",
    },
}
# Отсутствие log.preset в settings.json (старый файл) = quiet: поведение как раньше
DEFAULT_LOG_PRESET = "quiet"

# Подписки приходят в старой нотации: поле streamSettings.network и ключи
# *Settings к нему. В документации поле называется method, а транспорт TCP
# переименован в RAW («更名自曾经的 TCP 传输层»). Оставляем в конфиге только
# документированные имена; значения без документированного эквивалента не трогаем.
NETWORK_TO_METHOD = {
    "tcp": "raw",
    "ws": "websocket",
    "kcp": "mkcp",
    "grpc": "grpc",
    "httpupgrade": "httpupgrade",
    "xhttp": "xhttp",
    "hysteria": "hysteria",
    "masque": "masque",
}
# Ключи настроек транспорта, которые переименованы вместе с транспортом
NETWORK_SETTINGS_KEYS = {"tcp": ("tcpSettings", "rawSettings")}

LOG_CONFIG = {}

# DNS: hosts (прибитые IP для DoH-доменов) и servers (адреса резолверов).
# Живут в settings.json → dns, потому что это данные, а не логика: адреса
# меняются у провайдеров, а правка кода требует обновления скриптов на роутере.
# DEFAULT_DNS_* применяются только к старым settings.json без секции dns —
# иначе после обновления роутер остался бы без резолверов.
DEFAULT_DNS_HOSTS = {
    "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
    "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
    "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"],
}
DEFAULT_DNS_SERVERS = [
    {
        "address": "https+local://common.dot.dns.yandex.net/dns-query",
        "domains": ["geosite:category-ru"],
        "expectedIPs": ["geoip:ru"],
        "skipFallback": True,
    },
    {
        "address": "https+local://cloudflare-dns.com/dns-query",
        "skipFallback": False,
    },
    {
        "address": "https+local://dns.nextdns.io",
        "skipFallback": False,
    },
]

# Схемы адреса DNS-сервера, описанные в документации (раздел DNS)
DNS_ADDRESS_SCHEMES = (
    "https+local://",
    "https://",
    "h2c://",
    "tcp+local://",
    "tcp://",
    "quic+local://",
    "udp://",
)

# Настройки DNS-модуля (раздел DNS документации). Имена — как в Xray, чтобы
# значение переносилось в конфиг без переименования: settings — это данные.
DNS_TUNING_DEFAULTS = {
    "queryStrategy": "UseIPv4",
    "disableCache": False,
    "serveStale": True,
    "serveExpiredTTL": 600,
    "disableFallback": False,
    "disableFallbackIfMatch": True,
    "enableParallelQuery": True,
}
DNS_QUERY_STRATEGIES = ("UseIP", "UseIPv4", "UseIPv6", "UseSystem")
DNS_BOOL_KEYS = ("disableCache", "serveStale", "disableFallback",
                 "disableFallbackIfMatch", "enableParallelQuery")
# Резервный апстрим dnsmasq: нужен, когда Xray ещё не поднялся
DEFAULT_DNSMASQ_FALLBACK = "77.88.8.8"

DNS_CONFIG = {}

# Параметры TProxy. Продублированы в nftables, init.d, диагностике и на стенде —
# поэтому живут в settings, а не в коде: рассогласование порта или метки даёт
# трафик «в никуда» без единой ошибки в журнале.
DEFAULT_TPROXY = {
    "port": 12345,     # tproxy-in в Xray + цель tproxy в nftables
    "dns_port": 5353,  # dns-local в Xray + апстрим dnsmasq
    "mark": 2,         # метка пакетов самого Xray (loop prevention)
    "fwmark": 1,       # метка трафика роутера для policy routing
    "route_table": 100,  # таблица, куда уходит fwmark
}
TPROXY_CONFIG = {}


def load_tproxy(section: dict) -> dict:
    """
    Читает параметры TProxy из settings.json → tproxy.
    Значения попадают не только в config.json, но и в nftables/init.d, поэтому
    проверяются здесь: опечатка в метке ломает маршрутизацию молча.
    """
    cfg = dict(DEFAULT_TPROXY)
    cfg.update({k: v for k, v in section.items() if k in DEFAULT_TPROXY})

    unknown = [k for k in section if k not in DEFAULT_TPROXY]
    if unknown:
        print(f"  [!] В settings.json → tproxy неизвестные ключи проигнорированы: "
              f"{', '.join(unknown)}", file=sys.stderr)

    for key, value in cfg.items():
        if not isinstance(value, int) or isinstance(value, bool):
            log_error(f"В {SETTINGS_FILE} → tproxy.{key} должно быть целым числом")
            sys.exit(1)
        if value <= 0:
            log_error(f"В {SETTINGS_FILE} → tproxy.{key} должно быть больше нуля")
            sys.exit(1)
        if key in ("port", "dns_port") and value > 65535:
            log_error(f"В {SETTINGS_FILE} → tproxy.{key} вне диапазона 1..65535")
            sys.exit(1)

    # mark — метка пакетов Xray, fwmark — метка трафика роутера. Совпадение
    # означает, что правило loop prevention пропустит весь трафик роутера мимо
    # TProxy, а трафик Xray попадёт в policy routing — прокси перестанет работать.
    if cfg["mark"] == cfg["fwmark"]:
        log_error(f"В {SETTINGS_FILE} → tproxy.mark и tproxy.fwmark совпадают "
                  f"({cfg['mark']}): трафик Xray и роутера нельзя маркировать одинаково")
        sys.exit(1)

    return cfg


# Проверка probe-URL балансировщика: один адрес на observatory и на LED-индикатор.
DEFAULT_PROBE_URL = "https://connectivitycheck.gstatic.com/generate_204"
PROBE_URL = DEFAULT_PROBE_URL

# Балансировщик: strategy/strategySettings — из BalancerObject, pingConfig — из
# burstObservatory.pingConfig. destination намеренно НЕ читается из pingConfig:
# единственный источник — health.probe_url, иначе получаются два разных URL.
BALANCER_STRATEGIES = ("random", "roundRobin", "leastPing", "leastLoad")
BALANCER_STRATEGY_SETTINGS_KEYS = ("expected", "maxRTT", "tolerance", "baselines", "costs")
PING_CONFIG_KEYS = ("connectivity", "interval", "sampling", "timeout", "httpMethod")
DEFAULT_BALANCER = {
    "strategy": "leastLoad",
    "strategySettings": {},
    "pingConfig": {
        "interval": "1m",
        "sampling": 10,
        "timeout": "15s",
        "httpMethod": "GET",
    },
}
BALANCER_CONFIG = {}


def load_health(section: dict) -> str:
    """Читает health.probe_url — адрес проверки доступности для observatory и LED"""
    url = section.get("probe_url")
    if url is None:
        return DEFAULT_PROBE_URL
    if not isinstance(url, str) or not url.startswith(("http://", "https://")):
        log_error(f"В {SETTINGS_FILE} → health.probe_url должен быть http(s)-адресом")
        sys.exit(1)
    return url


def load_balancer(section: dict) -> dict:
    """
    Читает balancer: strategy, strategySettings, pingConfig.
    Неизвестные ключи — ошибка, а не молчаливый пропуск: опечатка в strategy
    оставила бы конфиг с недокументированным значением, который ядро отвергнет.
    """
    unknown = [k for k in section if k not in ("strategy", "strategySettings", "pingConfig")]
    if unknown:
        log_error(f"В {SETTINGS_FILE} → balancer неизвестные ключи: {', '.join(unknown)}")
        log_error("Допустимые ключи: strategy, strategySettings, pingConfig")
        sys.exit(1)

    cfg = {
        "strategy": section.get("strategy", DEFAULT_BALANCER["strategy"]),
        "strategySettings": dict(section.get("strategySettings") or {}),
        "pingConfig": dict(DEFAULT_BALANCER["pingConfig"]),
    }

    if cfg["strategy"] not in BALANCER_STRATEGIES:
        log_error(f"В {SETTINGS_FILE} → balancer.strategy недопустимое значение: "
                  f"{cfg['strategy']!r}")
        log_error(f"Документированные значения: {', '.join(BALANCER_STRATEGIES)}")
        sys.exit(1)

    # strategySettings документированы только для leastLoad
    if cfg["strategySettings"] and cfg["strategy"] != "leastLoad":
        log_error(f"В {SETTINGS_FILE} → balancer.strategySettings применимы только "
                  f"к strategy=leastLoad, а выбрано {cfg['strategy']!r}")
        sys.exit(1)
    bad = [k for k in cfg["strategySettings"] if k not in BALANCER_STRATEGY_SETTINGS_KEYS]
    if bad:
        log_error(f"В {SETTINGS_FILE} → balancer.strategySettings неизвестные ключи: "
                  f"{', '.join(bad)}")
        log_error(f"Документированные ключи: {', '.join(BALANCER_STRATEGY_SETTINGS_KEYS)}")
        sys.exit(1)
    expected = cfg["strategySettings"].get("expected")
    if expected is not None and (not isinstance(expected, int) or isinstance(expected, bool)
                                 or expected <= 0):
        log_error(f"В {SETTINGS_FILE} → balancer.strategySettings.expected "
                  f"должно быть целым числом больше нуля")
        sys.exit(1)

    ping = section.get("pingConfig") or {}
    if not isinstance(ping, dict):
        log_error(f"В {SETTINGS_FILE} → balancer.pingConfig должен быть объектом")
        sys.exit(1)
    if "destination" in ping:
        log_error(f"В {SETTINGS_FILE} → balancer.pingConfig.destination не поддерживается: "
                  f"адрес проверки задаётся один раз в health.probe_url")
        sys.exit(1)
    bad = [k for k in ping if k not in PING_CONFIG_KEYS]
    if bad:
        log_error(f"В {SETTINGS_FILE} → balancer.pingConfig неизвестные ключи: {', '.join(bad)}")
        log_error(f"Документированные ключи: {', '.join(PING_CONFIG_KEYS)}")
        sys.exit(1)
    cfg["pingConfig"].update(ping)

    sampling = cfg["pingConfig"].get("sampling")
    if not isinstance(sampling, int) or isinstance(sampling, bool) or sampling <= 0:
        log_error(f"В {SETTINGS_FILE} → balancer.pingConfig.sampling "
                  f"должно быть целым числом больше нуля")
        sys.exit(1)

    return cfg


def load_dns(dns_section: dict) -> dict:
    """
    Читает hosts, servers и настройки DNS-модуля из settings.json → dns и проверяет их.
    Пустая секция (старый settings.json) — встроенные значения по умолчанию.
    Ошибка в адресе сервера фатальна: с невалидным DNS роутер останется без
    резолвинга, а xray run -test такую ошибку увидит уже после записи конфига.
    """
    hosts = dns_section.get("hosts")
    servers = dns_section.get("servers")

    cfg = dict(DNS_TUNING_DEFAULTS)
    for key in DNS_TUNING_DEFAULTS:
        if key in dns_section:
            cfg[key] = dns_section[key]

    if cfg["queryStrategy"] not in DNS_QUERY_STRATEGIES:
        log_error(f"В {SETTINGS_FILE} → dns.queryStrategy недопустимое значение: "
                  f"{cfg['queryStrategy']!r}")
        log_error(f"Документированные значения: {', '.join(DNS_QUERY_STRATEGIES)}")
        sys.exit(1)
    for key in DNS_BOOL_KEYS:
        if not isinstance(cfg[key], bool):
            log_error(f"В {SETTINGS_FILE} → dns.{key} должно быть true или false")
            sys.exit(1)
    ttl = cfg["serveExpiredTTL"]
    if not isinstance(ttl, int) or isinstance(ttl, bool) or ttl < 0:
        log_error(f"В {SETTINGS_FILE} → dns.serveExpiredTTL должно быть целым числом "
                  f"секунд (0 и больше)")
        sys.exit(1)

    fallback = dns_section.get("dnsmasq_fallback", DEFAULT_DNSMASQ_FALLBACK)
    if not isinstance(fallback, str) or not fallback:
        log_error(f"В {SETTINGS_FILE} → dns.dnsmasq_fallback должен быть непустой строкой")
        sys.exit(1)
    cfg["dnsmasq_fallback"] = fallback

    unknown = [k for k in dns_section
               if k not in ("hosts", "servers", "dnsmasq_fallback", *DNS_TUNING_DEFAULTS)]
    if unknown:
        print(f"  [!] В settings.json → dns неизвестные ключи проигнорированы: "
              f"{', '.join(unknown)}", file=sys.stderr)

    if hosts is None and servers is None:
        print("  [!] В settings.json нет секции dns — используются встроенные DNS",
              file=sys.stderr)
        cfg["hosts"] = dict(DEFAULT_DNS_HOSTS)
        cfg["servers"] = [dict(s) for s in DEFAULT_DNS_SERVERS]
        return cfg

    if hosts is None:
        hosts = {}
    if servers is None:
        servers = []

    if not isinstance(hosts, dict):
        log_error(f"В {SETTINGS_FILE} → dns.hosts должен быть объектом")
        sys.exit(1)
    if not isinstance(servers, list):
        log_error(f"В {SETTINGS_FILE} → dns.servers должен быть массивом")
        sys.exit(1)

    clean_hosts = {}
    for name, value in hosts.items():
        values = value if isinstance(value, list) else [value]
        if not values or not all(isinstance(v, str) and v for v in values):
            log_error(f"В {SETTINGS_FILE} → dns.hosts[{name!r}]: нужен IP или список IP")
            sys.exit(1)
        clean_hosts[name] = list(values)

    if not servers:
        log_error(f"В {SETTINGS_FILE} → dns.servers пуст: без резолверов конфиг нерабочий")
        sys.exit(1)

    clean_servers = []
    for i, server in enumerate(servers):
        if not isinstance(server, dict) or not isinstance(server.get("address"), str):
            log_error(f"В {SETTINGS_FILE} → dns.servers[{i}]: нужен объект с полем address")
            sys.exit(1)
        address = server["address"]
        if "://" in address and not address.startswith(DNS_ADDRESS_SCHEMES):
            log_error(f"В {SETTINGS_FILE} → dns.servers[{i}].address: "
                      f"недокументированная схема {address!r}")
            log_error(f"Документированные схемы: {', '.join(DNS_ADDRESS_SCHEMES)}")
            sys.exit(1)
        clean_servers.append(dict(server))

    # DOHL-сервер резолвится сам собой: если его адрес не прибит в hosts,
    # получается петля (документация: «注意可能的回环问题, hosts 可能有帮助»)
    unpinned = [s["address"].split("://", 1)[1].split("/")[0]
                for s in clean_servers
                if s["address"].startswith(("https+local://", "tcp+local://", "quic+local://"))
                and "." in s["address"].split("://", 1)[1].split("/")[0]
                and s["address"].split("://", 1)[1].split("/")[0] not in clean_hosts]
    if unpinned:
        print(f"  [!] Адреса резолверов не прибиты в dns.hosts: {', '.join(unpinned)} — "
              f"возможна петля при резолвинге", file=sys.stderr)

    cfg["hosts"] = clean_hosts
    cfg["servers"] = clean_servers
    return cfg


def load_settings():
    """Загружает routing, пресет журналирования и DNS из settings.json"""
    global ROUTING_CONFIG, LOG_CONFIG, DNS_CONFIG, TPROXY_CONFIG, BALANCER_CONFIG, PROBE_URL

    if not os.path.isfile(SETTINGS_FILE):
        log_error(f"Нет {SETTINGS_FILE} — правила роутинга задаются только там")
        sys.exit(1)

    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
    except Exception as e:
        log_error(f"Не удалось прочитать {SETTINGS_FILE}: {e}")
        sys.exit(1)

    routing = settings.get("routing") or {}
    missing = [key for key in ROUTING_KEYS if key not in routing]
    if missing:
        log_error(f"В {SETTINGS_FILE} → routing нет обязательных ключей: {', '.join(missing)}")
        log_error("Правила роутинга задаются только в settings.json; без этих ключей")
        log_error("правила получились бы пустыми, поэтому конфиг не собирается.")
        log_error("Долейте недостающие ключи, сохранив свои значения:")
        log_error(f"  curl -fsSL {SETTINGS_DEFAULT_URL} -o /tmp/settings.default.json")
        log_error("  jq --slurpfile def /tmp/settings.default.json \\")
        log_error("     '.routing = ($def[0].routing + (.routing // {}))' \\")
        log_error(f"     {SETTINGS_FILE} > /tmp/s.json && mv /tmp/s.json {SETTINGS_FILE}")
        sys.exit(1)

    ROUTING_CONFIG = {key: routing[key] for key in ROUTING_KEYS}
    ROUTING_CONFIG.update({k: routing.get(k, v) for k, v in ROUTING_OPTIONAL_KEYS.items()})

    invalid = [p for p in ROUTING_CONFIG["direct_protocols"] if p not in ROUTING_PROTOCOLS]
    if invalid:
        log_error(f"В {SETTINGS_FILE} → routing.direct_protocols недопустимые значения: "
                  f"{', '.join(map(str, invalid))}")
        log_error(f"Документированные значения RuleObject.protocol: {', '.join(ROUTING_PROTOCOLS)}")
        sys.exit(1)

    if not isinstance(ROUTING_CONFIG["block_quic"], bool):
        log_error(f"В {SETTINGS_FILE} → routing.block_quic должно быть true или false")
        sys.exit(1)

    # bypass_cidrs читает update-nft.sh (сам по себе он не умеет проверять CIDR),
    # поэтому проверка здесь: update-xray.sh запускает генератор раньше nftables и
    # не даст применить правила с битой подсетью.
    bypass_cidrs = routing.get("bypass_cidrs", DEFAULT_BYPASS_CIDRS)
    if not isinstance(bypass_cidrs, list) or not bypass_cidrs:
        log_error(f"В {SETTINGS_FILE} → routing.bypass_cidrs должен быть непустым массивом")
        sys.exit(1)
    for cidr in bypass_cidrs:
        try:
            ipaddress.ip_network(str(cidr), strict=False)
        except ValueError:
            log_error(f"В {SETTINGS_FILE} → routing.bypass_cidrs: не подсеть {cidr!r}")
            sys.exit(1)
    ROUTING_CONFIG["bypass_cidrs"] = [str(c) for c in bypass_cidrs]

    log_section = settings.get("log") or {}
    preset = log_section.get("preset") or DEFAULT_LOG_PRESET
    if preset not in LOG_PRESETS:
        log_error(f"В {SETTINGS_FILE} → log.preset неизвестное значение: {preset!r}")
        log_error(f"Допустимые значения: {', '.join(LOG_PRESETS)}")
        sys.exit(1)
    LOG_CONFIG = LOG_PRESETS[preset]
    print(f"  → Пресет журналирования: {preset}", file=sys.stderr)

    DNS_CONFIG = load_dns(settings.get("dns") or {})
    TPROXY_CONFIG = load_tproxy(settings.get("tproxy") or {})
    BALANCER_CONFIG = load_balancer(settings.get("balancer") or {})
    PROBE_URL = load_health(settings.get("health") or {})


# ============================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def normalize_stream_settings(stream: dict) -> None:
    """
    Приводит выбор транспорта к документированному виду: network → method.
    Если в подписке уже есть method, ничего не меняем и предупреждаем только при
    расхождении: угадывать, какой из двух селекторов верный, нельзя.
    """
    if "network" not in stream:
        return

    network = stream.pop("network")
    method = stream.get("method")

    if method:
        if method != NETWORK_TO_METHOD.get(str(network), network):
            print(
                f"  [!] В подписке указаны и network={network!r}, и method={method!r} — "
                f"оставлен method, как документированное поле",
                file=sys.stderr,
            )
        return

    mapped = NETWORK_TO_METHOD.get(str(network))
    if not mapped:
        stream["network"] = network
        print(
            f"  [!] Транспорт network={network!r} не имеет документированного имени "
            f"в method — оставлен как есть",
            file=sys.stderr,
        )
        return

    stream["method"] = mapped

    old_key = NETWORK_SETTINGS_KEYS.get(str(network))
    if old_key and old_key[0] in stream:
        src, dst = old_key
        stream[dst] = stream.pop(src)


def normalize_reality(reality: dict) -> None:
    """
    publicKey — прежнее имя ключа REALITY, в документации поле называется password.
    Оставляем документированное имя; если пришли оба, побеждает password.
    """
    if "publicKey" not in reality:
        return
    legacy = reality.pop("publicKey")
    if not reality.get("password"):
        reality["password"] = legacy


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}

    normalize_stream_settings(ob["streamSettings"])

    reality = ob["streamSettings"].get("realitySettings")
    if isinstance(reality, dict):
        normalize_reality(reality)
    
    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}
    
    ob["streamSettings"]["sockopt"]["mark"] = TPROXY_CONFIG["mark"]
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30
    
    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False
    
    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    dns = {
        "tag": "dns-inbuilt",
        # hosts и servers, а также настройки DNS-модуля — из settings.json → dns
        "hosts": {k: list(v) for k, v in DNS_CONFIG["hosts"].items()},
        "servers": [dict(s) for s in DNS_CONFIG["servers"]],
    }
    dns.update({key: DNS_CONFIG[key] for key in DNS_TUNING_DEFAULTS})
    return {
        "log": dict(LOG_CONFIG),
        "dns": dns,
        # Протокол inbound документирован как tunnel (см. xray-config-reference.md);
        # dokodemo-door — его прежнее название, в перечне protocol его больше нет
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": TPROXY_CONFIG["port"],
                "protocol": "tunnel",
                "settings": {
                    "allowedNetwork": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": True
                }
            },
            {
                "tag": "dns-local",
                "listen": "127.0.0.1",
                "port": TPROXY_CONFIG["dns_port"],
                "protocol": "tunnel",
                "settings": {
                    "allowedNetwork": "tcp,udp"
                }
            }
        ]
    }


def build_direct_config() -> dict:
    """Создаёт DIRECT-конфиг (без прокси) для режима 'hole'"""
    cfg = base_config()
    cfg["outbounds"] = [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg["routing"] = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules([], direct_mode=True)
    }
    return cfg


def build_dns_outbound() -> dict:
    """Создаёт outbound 'dns-out' с hijack во встроенный DNS"""
    return {
        "protocol": "dns",
        "tag": "dns-out",
        "settings": {
            "rules": [
                {
                    "action": "hijack",
                    "qType": "1,28"
                }
            ]
        }
    }


def make_direct_outbound() -> dict:
    """Стандартный direct (freedom) outbound"""
    return {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {},
        "streamSettings": {
            "sockopt": {
                "mark": TPROXY_CONFIG["mark"],
                "domainStrategy": "UseIPv4",
                "tcpKeepAliveInterval": 30
            }
        }
    }


def make_block_outbound() -> dict:
    """Стандартный block (blackhole) outbound"""
    return {
        "protocol": "blackhole",
        "tag": "block",
        "settings": {"response": {"type": "http"}}
    }


def save_config(cfg: dict, output: str) -> None:
    """Сохраняет конфиг в файл"""
    with open(output, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг сохранён: {output}", file=sys.stderr)


def build_proxy_config(proxy_outbounds: list) -> dict:
    """
    Собирает полный конфиг с прокси, burstObservatory, balancer и routing.
    Используется всеми форматами (unified, json, vless).
    """
    cfg = base_config()
    cfg["outbounds"] = proxy_outbounds + [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg.update(build_burst_observatory(proxy_outbounds))
    routing = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules(proxy_outbounds),
        "balancers": [build_balancer(proxy_outbounds)]
    }
    cfg["routing"] = routing
    return cfg


def print_proxy_summary(proxy_outbounds: list) -> None:
    """Выводит сводку о количестве прокси и балансировщике"""
    print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
    if len(proxy_outbounds) > 1:
        print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)
    else:
        tag = proxy_outbounds[0].get("tag", "proxy") if proxy_outbounds else "proxy"
        print(f"  ✓ Выбран сервер: {tag}", file=sys.stderr)
        print(f"  ✓ Балансировщик: 1 сервер + fallback DIRECT", file=sys.stderr)


def geosite_has_category(category: str) -> bool:
    """
    Есть ли категория в geosite.dat. Имена категорий хранятся в файле как строки,
    поэтому достаточно поиска по бинарнику. Неизвестная категория делает конфиг
    невалидным (xray run -test падает), поэтому проверяем до генерации.
    """
    asset_dir = os.environ.get("XRAY_LOCATION_ASSET", "/usr/share/xray")
    try:
        with open(os.path.join(asset_dir, "geosite.dat"), "rb") as f:
            data = f.read()
    except OSError:
        return False
    # в geosite.dat коды категорий хранятся в верхнем регистре (CATEGORY-ADS)
    return category.upper().encode() in data or category.lower().encode() in data


def ip_check_geosite_available() -> bool:
    """Правило проверки IP включаем только если категория реально есть в geosite.dat"""
    if geosite_has_category(IP_CHECK_GEOSITE.split(":", 1)[1]):
        return True
    print(
        f"  [!] {IP_CHECK_GEOSITE} отсутствует в geosite.dat — правило проверки IP пропущено.\n"
        f"      Пересоберите геофайлы, иначе сервисы проверки IP пойдут через прокси.",
        file=sys.stderr,
    )
    return False


def build_rules(proxy_outbounds: list, direct_mode: bool = False) -> list:
    """
    Строит правила маршрутизации.
    Значения берутся только из settings.json → routing (проверка обязательных
    ключей — в load_settings), готовых дефолтов в коде нет.
    Если несколько прокси, использует балансировщик.
    Если один прокси, использует прямой outboundTag.
    """
    rules = [
        # Клиентский DNS (от dnsmasq) → dns-out (hijack → dns-inbuilt)
        {
            "inboundTag": ["dns-local"],
            "outboundTag": "dns-out"
        }
    ]

    # Домены проверки IP — всегда напрямую и раньше остальных правил:
    # иначе провайдер/сервис увидит IP прокси и определит VPN
    if ip_check_geosite_available():
        rules.append({
            "domain": [IP_CHECK_GEOSITE],
            "outboundTag": "direct"
        })

    rules += [
        # Ловим DNS через DoH, которые прошли мимо dnsmasq (от браузера)
        {
            "domain": ROUTING_CONFIG["doh_domains"],
            "outboundTag": "direct"
        },
        # Блокировка рекламы
        {
            "domain": ROUTING_CONFIG["block_domains"],
            "outboundTag": "block"
        },
        # NTP (порт 123) — напрямую
        {
            "port": "123",
            "network": "udp",
            "outboundTag": "direct"
        },
    ]

    # QUIC (UDP/443): VLESS+XTLS не поддерживает UDP, поэтому по умолчанию
    # блокируем. Тот же переключатель управляет drop-правилом в nftables.
    if ROUTING_CONFIG["block_quic"]:
        rules.append({
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
        })

    rules += [
        # Локальные и российские IP — напрямую
        {
            "ip": ROUTING_CONFIG["direct_ips"],
            "outboundTag": "direct"
        },
        # Локальные и российские домены — напрямую
        {
            "domain": ROUTING_CONFIG["direct_domains"],
            "outboundTag": "direct"
        },
    ]

    # Протоколы по результатам sniffing — напрямую (по умолчанию bittorrent).
    # Требует включённого sniffing во входящем: без него protocol не определяется.
    if ROUTING_CONFIG["direct_protocols"]:
        rules.append({
            "protocol": ROUTING_CONFIG["direct_protocols"],
            "outboundTag": "direct"
        })

    if not direct_mode and proxy_outbounds:
        # Всегда через balancer — даже для одного прокси (observatory следит, fallback на direct)
        rules.append({
            "domain": ROUTING_CONFIG["proxy_domains"],
            "balancerTag": "balancer"
        })
        
        rules.append({
            "network": "tcp,udp",
            "balancerTag": "balancer"
        })
    else:
        rules.append({
            "network": "tcp,udp",
            "outboundTag": "direct"
        })
    
    return rules


def build_balancer(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию балансировщика (стратегия — из settings.json → balancer).
    leastLoad выбирает наиболее стабильные серверы на основе данных burstObservatory.
    Если все серверы не проходят — fallback на direct.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    strategy = {"type": BALANCER_CONFIG["strategy"]}
    if BALANCER_CONFIG["strategySettings"]:
        strategy["settings"] = dict(BALANCER_CONFIG["strategySettings"])
    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": strategy,
        "fallbackTag": "direct"
    }


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.

    Пингует адрес из settings.json → health.probe_url — он же используется
    LED-индикатором, чтобы проверка доступности была одна на всю систему.
    GET вместо HEAD — лучше совместимость с прокси-протоколами.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    ping_config = {"destination": PROBE_URL}
    ping_config.update({k: v for k, v in BALANCER_CONFIG["pingConfig"].items()})
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": ping_config
        }
    }


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for OpenWrt TProxy')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--format', default='unified', help=argparse.SUPPRESS)  # обратная совместимость, не используется
    return parser.parse_args()


def main():
    args = parse_args()
    
    # Загружаем настройки из единого JSON-конфига
    load_settings()
    
    print("  → Обработка унифицированной подписки", file=sys.stderr)
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        log_error(f"Failed to parse unified input: {e}")
        sys.exit(1)
    
    if data.get("hole", False):
        print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
        print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
        save_config(build_direct_config(), args.output)
        return
    
    raw_outbounds = data.get("outbounds", [])
    if not raw_outbounds:
        log_error("No outbounds in unified input — switching to DIRECT")
        save_config(build_direct_config(), args.output)
        return
    
    # loopback возвращает трафик в маршрутизацию — в балансировщике он недопустим
    raw_outbounds = [
        ob for ob in raw_outbounds
        if ob.get("protocol") not in ("freedom", "blackhole", "dns", "loopback")
    ]
    proxy_outbounds = [normalize_outbound(ob) for ob in raw_outbounds]
    cfg = build_proxy_config(proxy_outbounds)
    print_proxy_summary(proxy_outbounds)
    save_config(cfg, args.output)


if __name__ == "__main__":
    main()