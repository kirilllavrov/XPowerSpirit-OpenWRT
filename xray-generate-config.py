#!/usr/bin/env python3
"""
Xray Config Generator for OpenWrt TProxy

Вход:  {"hole": bool, "outbounds": [...]} из xray-sub-parser.py
Выход: config.json для Xray, собранный из /etc/xray/settings.json.

Слои, чтобы не смешивать данные, проверки и сборку:
  1. Данные — перечни документированных значений и имён полей.
  2. Вывод и ошибки — единый формат сообщений.
  3. Значения по умолчанию — только из эталона settings.default.json; здесь же
     схема секций и валидатор — единственное место проверок типов, диапазонов
     и перечислений. Новый параметр добавляется одной строкой в схему.
  4. Сборка — по одной функции на секцию config.json.
  5. Точка входа.

Специальная обработка "hole": если подписка сообщила, что серверов нет, собирается
DIRECT-конфиг (весь трафик напрямую) — это сигнал об окончании срока подписки.

Транспорт и REALITY уже нормализованы парсером (network → method,
tcpSettings → rawSettings, publicKey → password). Здесь добавляется только то,
что зависит от настроек роутера: sockopt с меткой Xray, keepalive прокси и
отключённый Mux.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

# Модуль лежит рядом со скриптом: при запуске через runpy или из другого каталога
# sys.path[0] может указывать не сюда
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Общие данные и примитивы валидации: те же значения читает update_nft.py,
# иначе порт TProxy или метки разъедутся между config.json и nftables
from xray_settings import (
    DEFAULT_SETTINGS_FILE,
    Field,
    SettingsError,
    SETTINGS_DEFAULT_URL,
    bypass_cidrs_defaults,
    defaults_file,
    defaults_section,
    field,
    proxy_router_traffic_default,
    set_settings_file,
    tproxy_defaults,
)

# ============================================
#   1. ДАННЫЕ И ДОКУМЕНТИРОВАННЫЕ ЗНАЧЕНИЯ
# ============================================

# XRAY_SETTINGS_FILE — только для тестов и ручных прогонов вне устройства
SETTINGS_FILE = os.environ.get("XRAY_SETTINGS_FILE", DEFAULT_SETTINGS_FILE)

# Категория geosite с доменами «какой у меня IP» (ifconfig.me, api.ipify.org, 2ip.ru).
# Провайдеры и сервисы используют их для детекта VPN, поэтому такие домены обязаны
# идти напрямую. Сами домены живут в geosite.dat, не в settings.json.
IP_CHECK_GEOSITE = "geosite:category-ipcheck"

# Теги служебных объектов конфига
TPROXY_IN_TAG = "tproxy-in"
DNS_LOCAL_TAG = "dns-local"
DIRECT_TAG = "direct"
BLOCK_TAG = "block"
DNS_OUT_TAG = "dns-out"
BALANCER_TAG = "balancer"
STREAMING_TAG = "balancer-stream"
DNS_TAG = "dns-inbuilt"

# Пресеты журналирования. Роутер пишет минимум (журналы в tmpfs, то есть в RAM),
# стенд в контейнере — подробно. Значения полей log.* из документации:
# access/error — путь, "none" отключает журнал; loglevel — none|error|warning|info|debug
# и влияет только на журнал ошибок.
LOG_PRESETS = {
    "quiet": {"loglevel": "none", "access": "none", "error": "none"},
    # error не указан → Xray пишет ошибки в stdout, procd отдаёт их в syslog, а logd
    # ставит метку времени по /etc/TZ (MSK). Собственный файл журнала Go пишет в UTC:
    # POSIX-строку MSK-3 из /etc/TZ он не разбирает, а zoneinfo в OpenWrt нет.
    "normal": {"loglevel": "warning", "access": "none"},
    "debug": {
        "loglevel": "info",
        "access": "/tmp/log/xray-access.log",
        "error": "/tmp/log/xray-error.log",
    },
}

# Настройки DNS-модуля (раздел DNS документации). Имена — как в Xray: settings
# хранит данные, поэтому значение переносится в конфиг без переименования.
# Дефолты не дублируются в коде: они берутся из эталона settings.default.json.
DNS_QUERY_STRATEGIES = ("UseIP", "UseIPv4", "UseIPv6", "UseSystem")
DNS_BOOL_KEYS = ("disableCache", "serveStale", "disableFallback",
                 "disableFallbackIfMatch", "enableParallelQuery")
# Порядок как в документации: он же порядок ключей в config.json, поэтому
# стабилен между прогонами (иначе sha256 «меняется» без изменений настроек)
DNS_TUNING_KEYS = ("queryStrategy", "disableCache", "serveStale", "serveExpiredTTL",
                   "disableFallback", "disableFallbackIfMatch", "enableParallelQuery")
# Схемы адреса DNS-сервера, описанные в документации
DNS_ADDRESS_SCHEMES = (
    "https+local://", "https://", "h2c://", "tcp+local://", "tcp://", "quic+local://", "udp://",
)

BALANCER_STRATEGIES = ("random", "roundRobin", "leastPing", "leastLoad")

# Префиксы доменных паттернов из документации (RuleObject.domain). Без префикса
# в routing — подстрока, но в dns.hosts документация задаёт full: по умолчанию.
DOMAIN_PATTERN_PREFIXES = ("domain:", "full:", "keyword:", "regexp:", "dotless:",
                           "geosite:", "ext:")

# PolicyObject: bufferSize в КБ; ноль отбрасывает UDP-пакеты при переполнении
# буфера — документация прямо предупреждает о неожиданных потерях
POLICY_KEYS = ("handshake", "connIdle", "uplinkOnly", "downlinkOnly", "bufferSize")
POLICY_MINIMUMS = {"handshake": 1, "connIdle": 1, "uplinkOnly": 0,
                   "downlinkOnly": 0, "bufferSize": 1}

# Ключи, без которых в эталоне нечего взять: значения по умолчанию живут только там
BALANCER_DEFAULT_KEYS = ("strategy", "strategySettings", "streaming", "pingConfig")

# Правила роутинга задаются только в settings.json → routing. Без обязательных
# ключей правила получились бы пустыми (RU-трафик ушёл бы в прокси, реклама не
# блокировалась), поэтому генератор отказывается собирать конфиг.
ROUTING_REQUIRED = (
    "domainStrategy",
    "doh_domains",
    "block_domains",
    "direct_ips",
    "direct_domains",
    "direct_protocols",
    "block_quic",
    "proxy_domains",
)
ROUTING_PROTOCOLS = ("http", "tls", "quic", "bittorrent")
# sockopt.domainStrategy — значения из документации (раздел sockopt), по умолчанию AsIs.
# Здесь это стратегия direct-выхода: как резолвить цель для соединений напрямую.
SOCKOPT_DOMAIN_STRATEGIES = (
    "AsIs", "UseIP", "UseIPv6v4", "UseIPv6", "UseIPv4v6", "UseIPv4",
    "ForceIP", "ForceIPv6v4", "ForceIPv6", "ForceIPv4v6", "ForceIPv4",
)
# Порядок ключей в правиле задаёт читаемость готового конфига
RULE_DNS = {"inboundTag": [DNS_LOCAL_TAG], "outboundTag": DNS_OUT_TAG}


# ============================================
#   2. ВЫВОД И ОШИБКИ
# ============================================

def log_error(msg: str) -> None:
    print(msg, file=sys.stderr)


def warn(msg: str) -> None:
    print(msg, file=sys.stderr)


def info(msg: str) -> None:
    print(msg, file=sys.stderr)


def fail_setting(path: str, problem: str) -> None:
    """Единый формат ошибки настройки: где и что именно не так"""
    raise SettingsError(f"В {SETTINGS_FILE} → {path}: {problem}")


# ============================================
#   3. ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ ИЗ ЭТАЛОНА
# ============================================

def defaults_required(section: str, keys: tuple) -> dict:
    """
    Секция эталона с обязательными ключами. Второго набора чисел в коде нет:
    если ключа нет в settings.default.json, брать значение неоткуда — это ошибка
    с инструкцией, а не повод подставить литерал.
    """
    raw = defaults_section(section)
    missing = [key for key in keys if key not in raw]
    if missing:
        raise SettingsError(
            f"В эталоне {defaults_file()} → {section} нет ключей: {', '.join(missing)}\n"
            f"Обновите эталон: sh /usr/share/xray/update-scripts.sh"
        )
    return raw


def log_preset_default() -> str:
    """Пресет журналирования по умолчанию"""
    preset = defaults_required("log", ("preset",))["preset"]
    if preset not in LOG_PRESETS:
        raise SettingsError(
            f"В эталоне {defaults_file()} → log.preset: недопустимый пресет {preset!r}\n"
            f"Допустимые значения: {', '.join(LOG_PRESETS)}"
        )
    return preset


def health_defaults() -> dict:
    """Адрес проверки: один на burstObservatory.pingConfig.destination и LED-индикатор"""
    return {"probe_url": field("str").check(
        "health.probe_url", defaults_required("health", ("probe_url",))["probe_url"])}


def policy_defaults() -> dict:
    """policy по умолчанию, проверенный по типам и минимальным значениям"""
    raw = defaults_required("policy", POLICY_KEYS)
    return {key: field("int", minimum=POLICY_MINIMUMS[key]).check(f"policy.{key}", raw[key])
            for key in POLICY_KEYS}


def balancer_defaults() -> dict:
    """Балансировщик, отдельный стриминговый пул и pingConfig по умолчанию"""
    raw = defaults_required("balancer", BALANCER_DEFAULT_KEYS)
    strategy_settings = raw["strategySettings"]
    streaming = raw["streaming"]
    ping_config = raw["pingConfig"]
    for key, value in (("strategySettings", strategy_settings), ("streaming", streaming),
                       ("pingConfig", ping_config)):
        if not isinstance(value, dict):
            raise SettingsError(
                f"В эталоне {defaults_file()} → balancer.{key}: ожидался объект")
    return {
        "strategy": field("str", enum=BALANCER_STRATEGIES).check(
            "balancer.strategy", raw["strategy"]),
        "strategySettings": dict(strategy_settings),
        "streaming": {
            "enabled": field("bool").check("balancer.streaming.enabled",
                                           streaming.get("enabled")),
            "strategy": field("str", enum=BALANCER_STRATEGIES).check(
                "balancer.streaming.strategy", streaming.get("strategy")),
        },
        "pingConfig": dict(ping_config),
    }


# Типы обязательных ключей routing: domainStrategy — строка, остальные — списки строк
ROUTING_FIELDS = {
    "domainStrategy": field("str"),
    "doh_domains": field("str_list"),
    "block_domains": field("str_list"),
    "direct_ips": field("str_list"),
    "direct_domains": field("str_list"),
    "proxy_domains": field("str_list"),
}

# Простые секции: имя секции → (строгий ли режим, поля).
# strict=True — неизвестный ключ это ошибка (опечатка оставила бы конфиг с
# недокументированным значением); strict=False — предупреждение (там данных
# может быть больше, чем знает генератор).
def sections() -> dict:
    """
    Схема секций settings.json. Значения по умолчанию берутся из эталона
    settings.default.json — второго набора чисел в коде нет. Эталон читается
    лениво: нужен только при отсутствии ключа в settings.json.
    """
    global _sections
    if _sections is None:
        _sections = _build_sections(tproxy_defaults(), policy_defaults())
    return _sections


def _build_sections(tproxy: dict, policy: dict) -> dict:
    return {
    "log": (False, {
        "preset": field("str", log_preset_default(), enum=tuple(LOG_PRESETS)),
    }),
    "health": (False, {
        "probe_url": field("str", health_defaults()["probe_url"]),
    }),
    "tproxy": (False, {
        "port": field("int", tproxy["port"], minimum=1, maximum=65535),
        "dns_port": field("int", tproxy["dns_port"], minimum=1, maximum=65535),
        "mark": field("int", tproxy["mark"], minimum=1),
        "fwmark": field("int", tproxy["fwmark"], minimum=1),
        "route_table": field("int", tproxy["route_table"], minimum=1),
        # Влияет только на правила nftables (update_nft.py), config.json не меняет
        "proxy_router_traffic": field("bool", proxy_router_traffic_default()),
    }),
    "policy": (True, {
        "handshake": field("int", policy["handshake"], minimum=1),
        "connIdle": field("int", policy["connIdle"], minimum=1),
        "uplinkOnly": field("int", policy["uplinkOnly"], minimum=0),
        "downlinkOnly": field("int", policy["downlinkOnly"], minimum=0),
        "bufferSize": field("int", policy["bufferSize"], minimum=1),
    }),
    }


_sections = None


def validate_section(name: str) -> dict:
    """Применяет схему к секции settings.json"""
    strict, fields = sections()[name]
    raw = SETTINGS.get(name) or {}
    if not isinstance(raw, dict):
        fail_setting(name, "ожидался объект")

    unknown = [k for k in raw if k not in fields]
    if unknown:
        if strict:
            raise SettingsError(
                f"В {SETTINGS_FILE} → {name}: неизвестные ключи {', '.join(unknown)}\n"
                f"Допустимые ключи: {', '.join(fields)}"
            )
        warn(f"  [!] В {SETTINGS_FILE} → {name}: неизвестные ключи проигнорированы: "
             f"{', '.join(unknown)}")

    return {key: spec.check(f"{name}.{key}", raw.get(key, spec.default))
            for key, spec in fields.items()}


def optional_routing(raw: dict, key: str):
    """
    Необязательный ключ routing: значение из settings.json, иначе из эталона.
    Без обоих собирать конфиг не из чего — ошибка с указанием обоих путей.
    """
    value = raw.get(key, defaults_section("routing").get(key))
    if value is None:
        fail_setting(f"routing.{key}",
                     f"нет ни в settings.json, ни в эталоне {defaults_file()}")
    return value


def validate_routing() -> dict:
    """Правила роутинга: обязательные ключи, перечисления, подсети"""
    raw = SETTINGS.get("routing") or {}
    if not isinstance(raw, dict):
        fail_setting("routing", "ожидался объект")

    missing = [k for k in ROUTING_REQUIRED if k not in raw]
    if missing:
        raise SettingsError(
            f"В {SETTINGS_FILE} → routing нет обязательных ключей: {', '.join(missing)}\n"
            f"Правила роутинга задаются только в settings.json; без этих ключей\n"
            f"правила получились бы пустыми, поэтому конфиг не собирается.\n"
            f"Долейте недостающие ключи, сохранив свои значения:\n"
            f"  curl -fsSL {SETTINGS_DEFAULT_URL} -o /tmp/settings.default.json\n"
            f"  jq --slurpfile def /tmp/settings.default.json \\\n"
            f"     '.routing = ($def[0].routing + (.routing // {{}}))' \\\n"
            f"     {SETTINGS_FILE} > /tmp/s.json && mv /tmp/s.json {SETTINGS_FILE}"
        )

    cfg = {key: raw[key] for key in ROUTING_REQUIRED}

    for key, spec in ROUTING_FIELDS.items():
        cfg[key] = spec.check(f"routing.{key}", cfg[key])

    cfg["direct_protocols"] = field("str_list", enum=ROUTING_PROTOCOLS).check(
        "routing.direct_protocols", cfg["direct_protocols"])
    cfg["block_quic"] = field("bool").check("routing.block_quic", cfg["block_quic"])

    cfg["direct_domain_strategy"] = field(
        "str", enum=SOCKOPT_DOMAIN_STRATEGIES).check(
        "routing.direct_domain_strategy",
        optional_routing(raw, "direct_domain_strategy"))

    # tcpKeepAliveInterval: секунды; отрицательное значение отключает keepalive.
    # Отдельные ключи для прокси-серверов из подписки и для direct-выхода
    for key in ("direct_tcp_keepalive_interval", "proxy_tcp_keepalive_interval"):
        cfg[key] = field("int").check(f"routing.{key}", optional_routing(raw, key))

    bypass = bypass_cidrs_defaults()
    cfg["bypass_cidrs"] = field("cidr_list", bypass).check(
        "routing.bypass_cidrs", raw.get("bypass_cidrs", bypass))
    return cfg


def validate_dns() -> dict:
    """DNS: hosts, servers, тюнинг модуля и резервный апстрим dnsmasq"""
    raw = SETTINGS.get("dns")
    if raw is None:
        fail_setting("dns", "обязательная секция отсутствует")
    if not isinstance(raw, dict):
        fail_setting("dns", "ожидался объект")

    base = defaults_section("dns")
    missing = [k for k in (*DNS_TUNING_KEYS, "dnsmasq_fallback") if base.get(k) is None]
    if missing:
        raise SettingsError(
            f"В эталоне {defaults_file()} → dns нет значений по умолчанию: "
            f"{', '.join(missing)}\n"
            f"Обновите эталон: sh /usr/share/xray/update-scripts.sh"
        )

    cfg = {}
    cfg["queryStrategy"] = field("str", base["queryStrategy"],
                                 enum=DNS_QUERY_STRATEGIES).check(
        "dns.queryStrategy", raw.get("queryStrategy", base["queryStrategy"]))
    for key in DNS_BOOL_KEYS:
        cfg[key] = field("bool", base[key]).check(f"dns.{key}", raw.get(key, base[key]))
    cfg["serveExpiredTTL"] = field("int", base["serveExpiredTTL"], minimum=0).check(
        "dns.serveExpiredTTL", raw.get("serveExpiredTTL", base["serveExpiredTTL"]))
    cfg["dnsmasq_fallback"] = field("str", base["dnsmasq_fallback"]).check(
        "dns.dnsmasq_fallback", raw.get("dnsmasq_fallback", base["dnsmasq_fallback"]))
    cfg["block_rcode"] = field("int", base["block_rcode"], minimum=0, maximum=5).check(
        "dns.block_rcode", raw.get("block_rcode", base["block_rcode"]))

    unknown = [k for k in raw
               if k not in ("hosts", "servers", "dnsmasq_fallback", "block_domains",
                            "block_rcode", *DNS_TUNING_KEYS)]
    if unknown:
        warn(f"  [!] В {SETTINGS_FILE} → dns: неизвестные ключи проигнорированы: "
             f"{', '.join(unknown)}")

    hosts = raw.get("hosts")
    servers = raw.get("servers")

    if hosts is not None and not isinstance(hosts, dict):
        fail_setting("dns.hosts", "ожидался объект «имя → IP»")
    if servers is not None and not isinstance(servers, list):
        fail_setting("dns.servers", "ожидался массив")

    if hosts is None:
        hosts = {}
    if servers is None:
        servers = []

    clean_hosts = {}
    for name, value in hosts.items():
        values = value if isinstance(value, list) else [value]
        if not values or not all(isinstance(v, str) and v for v in values):
            fail_setting(f"dns.hosts[{name!r}]", "нужен IP или массив IP")
        clean_hosts[name] = list(values)

    blocked = raw.get("block_domains", base.get("block_domains", []))
    if not isinstance(blocked, list):
        fail_setting("dns.block_domains", "ожидался массив доменных паттернов")
    clean_blocked = []
    for i, pattern in enumerate(blocked):
        if not isinstance(pattern, str) or not pattern:
            fail_setting(f"dns.block_domains[{i}]", "нужна непустая строка")
        prefix = pattern.split(":", 1)[0] + ":" if ":" in pattern else ""
        if prefix and prefix not in DOMAIN_PATTERN_PREFIXES:
            raise SettingsError(
                f"В {SETTINGS_FILE} → dns.block_domains[{i}]: недокументированный "
                f"префикс {prefix!r} в {pattern!r}\n"
                f"Документированные: {', '.join(DOMAIN_PATTERN_PREFIXES)}"
            )
        # Тот же ключ уже занят адресом резолвера — блокировка сломает его резолв
        if pattern in clean_hosts:
            fail_setting(f"dns.block_domains[{i}]",
                         f"{pattern!r} уже задан в dns.hosts как IP резолвера")
        clean_blocked.append(pattern)
    cfg["block_domains"] = clean_blocked

    if not servers:
        fail_setting("dns.servers", "пустой список: без резолверов конфиг нерабочий")

    clean_servers = []
    for i, server in enumerate(servers):
        if not isinstance(server, dict) or not isinstance(server.get("address"), str):
            fail_setting(f"dns.servers[{i}]", "нужен объект с полем address")
        address = server["address"]
        if "://" in address and not address.startswith(DNS_ADDRESS_SCHEMES):
            raise SettingsError(
                f"В {SETTINGS_FILE} → dns.servers[{i}].address: недокументированная "
                f"схема {address!r}\n"
                f"Документированные схемы: {', '.join(DNS_ADDRESS_SCHEMES)}"
            )
        clean_servers.append(dict(server))

    # DoH-резолвер не должен резолвиться сам собой: если его адрес не прибит в
    # hosts, получается петля (документация: «注意可能的回环问题, hosts 可能有帮助»)
    unpinned = [s["address"].split("://", 1)[1].split("/")[0]
                for s in clean_servers
                if s["address"].startswith(("https+local://", "tcp+local://", "quic+local://"))
                and "." in s["address"].split("://", 1)[1].split("/")[0]
                and s["address"].split("://", 1)[1].split("/")[0] not in clean_hosts]
    if unpinned:
        warn(f"  [!] Адреса резолверов не прибиты в dns.hosts: {', '.join(unpinned)} — "
             f"возможна петля при резолвинге")

    cfg["hosts"] = clean_hosts
    cfg["servers"] = clean_servers
    return cfg


def validate_balancer() -> dict:
    """Балансировщик: стратегия, её параметры (только для leastLoad) и pingConfig"""
    raw = SETTINGS.get("balancer") or {}
    if not isinstance(raw, dict):
        fail_setting("balancer", "ожидался объект")

    allowed = ("strategy", "strategySettings", "streaming", "pingConfig")
    unknown = [k for k in raw if k not in allowed]
    if unknown:
        raise SettingsError(
            f"В {SETTINGS_FILE} → balancer: неизвестные ключи {', '.join(unknown)}\n"
            f"Допустимые ключи: {', '.join(allowed)}"
        )

    defaults = balancer_defaults()
    cfg = {
        "strategy": field("str", defaults["strategy"],
                          enum=BALANCER_STRATEGIES).check(
            "balancer.strategy", raw.get("strategy", defaults["strategy"])),
        "strategySettings": dict(raw.get("strategySettings") or {}),
        "streaming": dict(defaults["streaming"]),
        "pingConfig": dict(defaults["pingConfig"]),
    }

    # StrategySettingsObject документирован только для leastLoad
    if cfg["strategySettings"] and cfg["strategy"] != "leastLoad":
        fail_setting("balancer.strategySettings",
                     f"применимы только к strategy=leastLoad, а выбрано {cfg['strategy']!r}")

    settings_ = cfg["strategySettings"]
    allowed_settings = ("expected", "maxRTT", "tolerance", "baselines", "costs")
    unknown = [k for k in settings_ if k not in allowed_settings]
    if unknown:
        raise SettingsError(
            f"В {SETTINGS_FILE} → balancer.strategySettings: неизвестные ключи "
            f"{', '.join(unknown)}\n"
            f"Документированные ключи: {', '.join(allowed_settings)}"
        )
    if "expected" in settings_:
        field("int", minimum=1).check("balancer.strategySettings.expected",
                                      settings_["expected"])
    # В документации maxRTT и baselines — строки времени ("1s"), не числа
    if "maxRTT" in settings_:
        field("str").check("balancer.strategySettings.maxRTT", settings_["maxRTT"])
    if "tolerance" in settings_:
        value = settings_["tolerance"]
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            fail_setting("balancer.strategySettings.tolerance", "ожидалось число")
    if "baselines" in settings_:
        field("str_list").check("balancer.strategySettings.baselines",
                                settings_["baselines"])
    if "costs" in settings_:
        costs = settings_["costs"]
        if not isinstance(costs, list) or not all(isinstance(c, dict) for c in costs):
            fail_setting("balancer.strategySettings.costs", "ожидался массив объектов")
        for i, cost in enumerate(costs):
            extra = [k for k in cost if k not in ("regexp", "match", "value")]
            if extra:
                raise SettingsError(
                    f"В {SETTINGS_FILE} → balancer.strategySettings.costs[{i}]: "
                    f"неизвестные ключи {', '.join(extra)}\n"
                    f"Документированные ключи: regexp, match, value"
                )

    streaming = raw.get("streaming")
    if streaming is not None:
        if not isinstance(streaming, dict):
            fail_setting("balancer.streaming", "ожидался объект")
        extra = [k for k in streaming if k not in defaults["streaming"]]
        if extra:
            raise SettingsError(
                f"В {SETTINGS_FILE} → balancer.streaming: неизвестные ключи "
                f"{', '.join(extra)}\n"
                f"Допустимые ключи: {', '.join(defaults['streaming'])}"
            )
        field("bool", defaults["streaming"]["enabled"]).check(
            "balancer.streaming.enabled",
            streaming.get("enabled", defaults["streaming"]["enabled"]))
        cfg["streaming"].update(streaming)
    cfg["streaming"]["strategy"] = field("str", defaults["streaming"]["strategy"],
                                         enum=BALANCER_STRATEGIES).check(
        "balancer.streaming.strategy", cfg["streaming"]["strategy"])


    ping = raw.get("pingConfig") or {}
    if not isinstance(ping, dict):
        fail_setting("balancer.pingConfig", "ожидался объект")
    if "destination" in ping:
        fail_setting("balancer.pingConfig.destination",
                     "не поддерживается: адрес проверки задаётся один раз в health.probe_url")
    allowed_ping = ("connectivity", "interval", "sampling", "timeout", "httpMethod")
    unknown = [k for k in ping if k not in allowed_ping]
    if unknown:
        raise SettingsError(
            f"В {SETTINGS_FILE} → balancer.pingConfig: неизвестные ключи "
            f"{', '.join(unknown)}\n"
            f"Документированные ключи: {', '.join(allowed_ping)}"
        )
    # interval/timeout/connectivity/httpMethod — строки времени или метода
    for key in ("connectivity", "interval", "timeout", "httpMethod"):
        if key in ping:
            field("str").check(f"balancer.pingConfig.{key}", ping[key])
    if "sampling" in ping:
        field("int", minimum=1).check("balancer.pingConfig.sampling", ping["sampling"])
    cfg["pingConfig"].update(ping)
    return cfg


def load_settings() -> dict:
    """Читает и проверяет settings.json, возвращает нормализованные секции"""
    global SETTINGS

    set_settings_file(SETTINGS_FILE)
    if not os.path.isfile(SETTINGS_FILE):
        raise SettingsError(f"Нет {SETTINGS_FILE} — правила роутинга задаются только там")
    try:
        with open(SETTINGS_FILE) as f:
            SETTINGS = json.load(f)
    except Exception as e:
        raise SettingsError(f"Не удалось прочитать {SETTINGS_FILE}: {e}")
    if not isinstance(SETTINGS, dict):
        raise SettingsError(f"{SETTINGS_FILE}: ожидался объект JSON верхнего уровня")

    cfg = {}
    for name in sections():
        cfg[name] = validate_section(name)
    cfg["routing"] = validate_routing()
    cfg["dns"] = validate_dns()
    cfg["balancer"] = validate_balancer()

    # mark — метка пакетов Xray, fwmark — метка трафика роутера. Совпадение
    # ломает loop prevention: трафик Xray попадёт в policy routing и вернётся
    # в TProxy, а трафик роутера минует прокси.
    if cfg["tproxy"]["mark"] == cfg["tproxy"]["fwmark"]:
        fail_setting("tproxy", f"mark и fwmark совпадают ({cfg['tproxy']['mark']}): "
                               f"трафик Xray и роутера нельзя маркировать одинаково")

    info(f"  → Пресет журналирования: {cfg['log']['preset']}")
    return cfg


SETTINGS = {}


# ============================================
#   4. СБОРКА СЕКЦИЙ КОНФИГА
# ============================================

def build_log(cfg: dict) -> dict:
    return dict(LOG_PRESETS[cfg["log"]["preset"]])


def build_dns(cfg: dict) -> dict:
    hosts = {k: list(v) for k, v in cfg["dns"]["hosts"].items()}
    # Блокировка на уровне DNS: hosts проверяется до серверов, а значение «#N»
    # отвергает запрос с rcode N (документация: «#3» — с井号后加数字). Домен
    # не получает адрес, поэтому соединение даже не начинается.
    for pattern in cfg["dns"]["block_domains"]:
        hosts[pattern] = f"#{cfg['dns']['block_rcode']}"
    dns = {
        "tag": DNS_TAG,
        "hosts": hosts,
        "servers": [dict(s) for s in cfg["dns"]["servers"]],
    }
    dns.update({key: cfg["dns"][key] for key in DNS_TUNING_KEYS})
    return dns


def build_inbounds(cfg: dict) -> list:
    return [
        {
            "tag": TPROXY_IN_TAG,
            "listen": "0.0.0.0",
            "port": cfg["tproxy"]["port"],
            # Протокол документирован как tunnel; dokodemo-door — прежнее название
            "protocol": "tunnel",
            "settings": {"allowedNetwork": "tcp,udp", "followRedirect": True},
            "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
            # routeOnly: домен из sniffing используется только для выбора правила,
            # соединение идёт на исходный IP — это обязательно для TProxy
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True},
        },
        {
            "tag": DNS_LOCAL_TAG,
            "listen": "127.0.0.1",
            "port": cfg["tproxy"]["dns_port"],
            "protocol": "tunnel",
            "settings": {"allowedNetwork": "tcp,udp"},
        },
    ]


def build_direct_outbound(cfg: dict) -> dict:
    return {
        "protocol": "freedom",
        "tag": DIRECT_TAG,
        "settings": {},
        "streamSettings": {
            "sockopt": {
                "mark": cfg["tproxy"]["mark"],
                "domainStrategy": cfg["routing"]["direct_domain_strategy"],
                "tcpKeepAliveInterval": cfg["routing"]["direct_tcp_keepalive_interval"],
            }
        },
    }


def build_block_outbound() -> dict:
    # response.type http — вернуть 403 вместо глухого закрытия, чтобы браузер
    # сразу показал ошибку, а не висел в таймауте
    return {"protocol": "blackhole", "tag": BLOCK_TAG, "settings": {"response": {"type": "http"}}}


def build_dns_outbound() -> dict:
    return {
        "protocol": "dns",
        "tag": DNS_OUT_TAG,
        "settings": {"rules": [{"action": "hijack", "qType": "1,28"}]},
    }


def build_policy(cfg: dict) -> dict:
    return {
        "levels": {"0": dict(cfg["policy"])},
        "system": {
            "statsInboundUplink": True,
            "statsInboundDownlink": True,
            "statsOutboundUplink": True,
            "statsOutboundDownlink": True,
        },
    }


def build_api() -> dict:
    return {
        "stats": {},
        "api": {
            "tag": "api",
            "listen": "127.0.0.1:10085",
            "services": ["StatsService"],
        },
    }


def build_balancer(cfg: dict, tags: list, tag: str = BALANCER_TAG,
                   strategy: str = None) -> dict:
    """
    Балансировщик по тегам прокси. expected по умолчанию равен числу серверов:
    в пуле оказываются все узлы профиля, а не только N лучших.
    """
    strategy_type = strategy or cfg["balancer"]["strategy"]
    strategy_cfg = {"type": strategy_type}
    if strategy_type == "leastLoad":
        settings_ = dict(cfg["balancer"]["strategySettings"])
        settings_.setdefault("expected", len(tags) or 1)
        strategy_cfg["settings"] = settings_
    return {
        "tag": tag,
        "selector": list(tags),
        "strategy": strategy_cfg,
        "fallbackTag": DIRECT_TAG,
    }


def streaming_pool(cfg: dict, proxies: list, stream_proxies: list = None) -> list:
    """
    Прокси для пула игр и стриминга. Если парсер отдал узлы отдельного профиля
    (settings.json → subscription.remarks_streaming) — берём их, иначе пул
    собирается из основного профиля. Пустой список — пул не нужен.
    """
    if not cfg["balancer"]["streaming"]["enabled"]:
        return []
    if stream_proxies:
        return stream_proxies
    return proxies if len(proxies) > 1 else []


def build_observatory(cfg: dict, tags: list) -> dict:
    ping_config = {"destination": cfg["health"]["probe_url"]}
    ping_config.update(cfg["balancer"]["pingConfig"])
    return {"burstObservatory": {"subjectSelector": list(tags), "pingConfig": ping_config}}


def geosite_has_category(category: str) -> bool:
    """
    Есть ли категория в geosite.dat. Имена категорий лежат в файле строками, поэтому
    достаточно поиска по бинарнику. Неизвестная категория делает конфиг невалидным
    (xray run -test упадёт), поэтому проверяем до генерации.
    """
    asset_dir = os.environ.get("XRAY_LOCATION_ASSET", "/usr/share/xray")
    try:
        with open(os.path.join(asset_dir, "geosite.dat"), "rb") as f:
            data = f.read()
    except OSError:
        return False
    # в geosite.dat коды категорий хранятся в верхнем регистре (CATEGORY-ADS)
    return category.upper().encode() in data or category.lower().encode() in data


def ip_check_available() -> bool:
    """Правило проверки IP включаем, только если категория реально есть в geosite.dat"""
    category = IP_CHECK_GEOSITE.split(":", 1)[1]
    if geosite_has_category(category):
        return True
    warn(f"  [!] {IP_CHECK_GEOSITE} отсутствует в geosite.dat — правило проверки IP "
         f"пропущено.\n      Пересоберите геофайлы, иначе сервисы проверки IP пойдут "
         f"через прокси.")
    return False


def build_rules(cfg: dict, proxies: list, direct_mode: bool = False,
                stream_pool: bool = None) -> list:
    """
    Правила маршрутизации. Порядок важен: всё, что должно идти напрямую или
    блокироваться, стоит раньше правил проксирования.
    """
    routing = cfg["routing"]
    rules = [dict(RULE_DNS, inboundTag=[DNS_LOCAL_TAG])]

    # Домены проверки IP — раньше всех остальных правил: иначе сервис увидит IP
    # прокси и определит VPN
    if ip_check_available():
        rules.append({"domain": [IP_CHECK_GEOSITE], "outboundTag": DIRECT_TAG})

    # DoH-запросы, прошедшие мимо dnsmasq (из браузера), не должны уходить в прокси
    rules.append({"domain": routing["doh_domains"], "outboundTag": DIRECT_TAG})
    # Пустой список рекламы — это норма: блокировка тогда целиком на DNS
    # (dns.block_domains). Правило без единого условия не создаём.
    if routing["block_domains"]:
        rules.append({"domain": routing["block_domains"], "outboundTag": BLOCK_TAG})
    # NTP напрямую: через прокси время не синхронизируется
    rules.append({"port": "123", "network": "udp", "outboundTag": DIRECT_TAG})

    # QUIC (UDP/443): VLESS+XTLS не поддерживает UDP, поэтому блокируем.
    # Тот же переключатель управляет drop-правилом в nftables
    if routing["block_quic"]:
        rules.append({"port": "443", "network": "udp", "outboundTag": BLOCK_TAG})

    rules.append({"ip": routing["direct_ips"], "outboundTag": DIRECT_TAG})
    rules.append({"domain": routing["direct_domains"], "outboundTag": DIRECT_TAG})

    # Протоколы по результатам sniffing требуют включённого sniffing во входящем
    if routing["direct_protocols"]:
        rules.append({"protocol": routing["direct_protocols"], "outboundTag": DIRECT_TAG})

    if direct_mode or not proxies:
        rules.append({"network": "tcp,udp", "outboundTag": DIRECT_TAG})
        return rules

    if stream_pool is None:
        stream_pool = bool(streaming_pool(cfg, proxies))
    stream_tag = STREAMING_TAG if stream_pool else BALANCER_TAG
    rules.append({"domain": routing["proxy_domains"], "balancerTag": stream_tag})
    rules.append({"network": "tcp,udp", "balancerTag": BALANCER_TAG})
    return rules


def build_config(cfg: dict, proxies: list, stream_proxies: list = None) -> dict:
    """Полный конфиг с прокси, балансировщиками и observatory"""
    stream_proxies = stream_proxies or []
    pool = streaming_pool(cfg, proxies, stream_proxies)
    tags = [ob["tag"] for ob in proxies]
    stream_tags = [ob["tag"] for ob in pool if ob not in proxies]

    balancers = [build_balancer(cfg, tags)]
    if pool:
        balancers.append(build_balancer(cfg, stream_tags or tags, tag=STREAMING_TAG,
                                        strategy=cfg["balancer"]["streaming"]["strategy"]))

    config = {
        "log": build_log(cfg),
        "dns": build_dns(cfg),
        "inbounds": build_inbounds(cfg),
        "outbounds": proxies + stream_proxies + [build_direct_outbound(cfg),
                                                 build_block_outbound(),
                                                 build_dns_outbound()],
        "policy": build_policy(cfg),
        "routing": {
            "domainStrategy": cfg["routing"]["domainStrategy"],
            "rules": build_rules(cfg, proxies, stream_pool=bool(pool)),
            "balancers": balancers,
        },
    }
    # leastPing без замеров молчит: наблюдатель обязан видеть серверы обоих профилей
    config.update(build_observatory(cfg, tags + stream_tags))
    config.update(build_api())
    return config


def build_direct_config(cfg: dict) -> dict:
    """DIRECT-конфиг: прокси нет, весь трафик напрямую"""
    config = {
        "log": build_log(cfg),
        "dns": build_dns(cfg),
        "inbounds": build_inbounds(cfg),
        "outbounds": [build_direct_outbound(cfg), build_block_outbound(),
                      build_dns_outbound()],
        "routing": {
            "domainStrategy": cfg["routing"]["domainStrategy"],
            "rules": build_rules(cfg, [], direct_mode=True),
        },
    }
    config.update(build_api())
    return config


def normalize_outbound(ob: dict, mark: int, keepalive: int) -> dict:
    """
    Добавляет политику устройства: sockopt с меткой Xray и keepalive прокси
    (settings.json → routing.proxy_tcp_keepalive_interval), mux выключен.
    Транспорт и REALITY к этому моменту уже нормализованы парсером подписки.
    """
    stream = ob.setdefault("streamSettings", {})
    sockopt = stream.setdefault("sockopt", {})
    sockopt["mark"] = mark
    sockopt["tcpKeepAliveInterval"] = keepalive
    ob.setdefault("mux", {})["enabled"] = False
    return ob


def save_config(config: dict, output: str) -> None:
    with open(output, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    info(f"  ✓ Конфиг сохранён: {output}")


def print_summary(cfg: dict, proxies: list, stream_proxies: list = None) -> None:
    info(f"  ✓ Сгенерировано {len(proxies)} прокси")
    if len(proxies) > 1:
        strategy = cfg["balancer"]["strategy"]
        expected = cfg["balancer"]["strategySettings"].get("expected", len(proxies))
        info(f"  ✓ Балансировщик: {len(proxies)} серверов ({strategy}, "
             f"пул {min(expected, len(proxies))})")
    elif proxies:
        info(f"  ✓ Выбран сервер: {proxies[0].get('tag', 'proxy')}")
        info(f"  ✓ Балансировщик: 1 сервер + fallback DIRECT")

    # Пул стриминга сообщаем отдельно: он создаётся и при одном сервере
    # в основном профиле, если в подписке есть отдельная группа
    pool = streaming_pool(cfg, proxies, stream_proxies)
    if pool:
        source = "отдельный профиль" if stream_proxies else "основной профиль"
        info(f"  ✓ Стриминг: {len(pool)} серверов "
             f"({cfg['balancer']['streaming']['strategy']}, {source})")


# ============================================
#   5. ТОЧКА ВХОДА
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description="Xray config generator for OpenWrt TProxy")
    parser.add_argument("--output", required=True, help="Output config file")
    return parser.parse_args()


def read_unified() -> dict:
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        raise SettingsError(f"Failed to parse unified input: {e}")
    if not isinstance(data, dict):
        raise SettingsError("Failed to parse unified input: ожидался объект JSON")
    return data


def main() -> None:
    args = parse_args()
    try:
        cfg = load_settings()
        data = read_unified()
    except SettingsError as e:
        log_error(str(e))
        sys.exit(1)

    info("  → Обработка унифицированной подписки")

    if data.get("hole", False):
        warn("  [!] Обнаружен сервер 'hole' (срок подписки истёк).")
        warn("  [!] Включаем DIRECT-режим (весь трафик напрямую).")
        save_config(build_direct_config(cfg), args.output)
        return

    # Служебные outbound'ы в балансировщике недопустимы: loopback возвращает трафик
    # в маршрутизацию, freedom/blackhole/dns — не серверы
    raw = [ob for ob in (data.get("outbounds") or [])
           if isinstance(ob, dict)
           and ob.get("protocol") not in ("freedom", "blackhole", "dns", "loopback")]
    if not raw:
        log_error("No outbounds in unified input — switching to DIRECT")
        save_config(build_direct_config(cfg), args.output)
        return

    mark = cfg["tproxy"]["mark"]
    keepalive = cfg["routing"]["proxy_tcp_keepalive_interval"]
    proxies = [normalize_outbound(ob, mark, keepalive) for ob in raw]

    # Второй профиль подписки — пул игр и стриминга. Теги в нём уже содержат
    # имя профиля, поэтому с основным пулом они не конфликтуют
    streaming_data = data.get("streaming") or {}
    stream_proxies = []
    if isinstance(streaming_data, dict):
        stream_raw = [ob for ob in (streaming_data.get("outbounds") or [])
                      if isinstance(ob, dict)
                      and ob.get("protocol") not in ("freedom", "blackhole", "dns", "loopback")]
        stream_proxies = [normalize_outbound(ob, mark, keepalive) for ob in stream_raw]
        if stream_proxies:
            info(f"  → Пул стриминга: {streaming_data.get('remarks', '')} "
                 f"({len(stream_proxies)} прокси)")

    save_config(build_config(cfg, proxies, stream_proxies), args.output)
    print_summary(cfg, proxies, stream_proxies)


if __name__ == "__main__":
    main()
