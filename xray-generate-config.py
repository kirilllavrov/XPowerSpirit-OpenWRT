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

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# XRAY_SETTINGS_FILE — только для тестов и ручных прогонов вне устройства
SETTINGS_FILE = os.environ.get("XRAY_SETTINGS_FILE", "/etc/xray/settings.json")

# Эталон правил роутинга: из него доливаются недостающие ключи на устройстве
SETTINGS_DEFAULT_URL = ("https://raw.githubusercontent.com/kirilllavrov/"
                        "XPowerSpirit-OpenWRT/main/settings.default.json")

# Правила роутинга задаются только в settings.json → routing (единственный источник:
# settings.default.json). Здесь — лишь перечень обязательных ключей: без них правила
# получились бы пустыми (RU-трафик ушёл бы в прокси, реклама не блокировалась), поэтому
# генератор отказывается работать, а не собирает тихо неверный конфиг.
ROUTING_CONFIG = {}

ROUTING_COMMON_KEYS = (
    "domainStrategy",
    "block_domains",
    "dns_direct_address",
    "dns_proxy_address",
    "dns_hosts",
)
ROUTING_MODE_KEYS = {
    "normal": ("direct_ips", "direct_domains", "proxy_domains"),
    "bs": ("bs_domains", "bs_ips"),
}


def load_settings(mode: str) -> None:
    """Загружает routing из settings.json и проверяет обязательные ключи"""
    global ROUTING_CONFIG

    if not os.path.isfile(SETTINGS_FILE):
        log_error(f"Нет {SETTINGS_FILE} — правила роутинга задаются только там")
        sys.exit(1)

    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
    except Exception as e:
        log_error(f"Не удалось прочитать {SETTINGS_FILE}: {e}")
        sys.exit(1)

    ROUTING_CONFIG = settings.get("routing") or {}

    required = ROUTING_COMMON_KEYS + ROUTING_MODE_KEYS[mode]
    missing = [key for key in required if key not in ROUTING_CONFIG]
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


# ============================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}
    
    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}
    
    ob["streamSettings"]["sockopt"]["mark"] = 2
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30
    
    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False
    
    return ob


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def build_dns(mode: str = "normal", has_proxy: bool = False) -> dict:
    """
    Встроенный DNS.

    Первый сервер обслуживает домены, которые резолвятся напрямую (DOHL — в routing
    не попадает): в normal это российские домены, в bs — белый список оператора.
    Остальное резолвится DoH через прокси: такой запрос входит в routing с
    inboundTag=dns-inbuilt и правилом уходит в balancer-dns. Причина: Яндекс может
    не отдавать адреса заблокированных зарубежных сервисов, а из туннеля ответ
    приходит корректный.

    Последний сервер — аварийный прямой Яндекс на случай, когда прокси недоступен.
    """
    if mode == "bs":
        # expectedIPs здесь нельзя: в списке БС могут быть зарубежные домены
        direct = {
            "address": ROUTING_CONFIG["dns_direct_address"],
            "domains": ROUTING_CONFIG["bs_domains"],
            "skipFallback": True,
            "timeoutMs": 2000
        }
    else:
        direct = {
            "address": ROUTING_CONFIG["dns_direct_address"],
            "domains": ["geosite:category-ru"],
            "expectedIPs": ["geoip:ru"],
            "skipFallback": True,
            "timeoutMs": 2000
        }

    servers = [direct]
    if has_proxy:
        servers.append({
            "address": ROUTING_CONFIG["dns_proxy_address"],
            "skipFallback": True,
            "timeoutMs": 2500
        })
    servers.append({
        "address": ROUTING_CONFIG["dns_direct_address"],
        "timeoutMs": 2000
    })

    return {
        "tag": "dns-inbuilt",
        "queryStrategy": "UseIPv4",
        "disableCache": False,
        "serveStale": True,
        "serveExpiredTTL": 600,
        "disableFallback": False,
        # В bs fallback нужен: если Яндекс не отдаст адрес домена из белого списка,
        # запрос должен уйти следующему серверу (через прокси).
        "disableFallbackIfMatch": mode != "bs",
        "enableParallelQuery": True,
        "hosts": dict(ROUTING_CONFIG["dns_hosts"]),
        "servers": servers
    }


def base_config(mode: str = "normal", has_proxy: bool = False) -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    return {
        "log": {
            "loglevel": "none",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": build_dns(mode, has_proxy),
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": 12345,
                "protocol": "dokodemo-door",
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
                "port": 5353,
                "protocol": "dokodemo-door",
                "settings": {
                    "allowedNetwork": "tcp,udp"
                }
            }
        ]
    }


def build_direct_config(mode: str = "normal") -> dict:
    """
    Создаёт DIRECT-конфиг (без прокси) для режима 'hole'.

    DNS здесь всегда normal-вариант: в DIRECT-режиме весь трафик идёт напрямую,
    и категории белого списка не нужны (их может не быть в геофайлах).
    """
    cfg = base_config("normal", has_proxy=False)
    cfg["outbounds"] = [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg["routing"] = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules([], mode=mode, direct_mode=True)
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
                "mark": 2,
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


def build_proxy_config(proxy_outbounds: list, mode: str = "normal") -> dict:
    """
    Собирает полный конфиг с прокси, burstObservatory, balancer и routing.
    mode="normal" — обычная маршрутизация, mode="bs" — белые списки оператора.
    """
    if not proxy_outbounds:
        return build_no_proxy_config(mode)

    cfg = base_config(mode, has_proxy=True)
    cfg["outbounds"] = proxy_outbounds + [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg.update(build_burst_observatory(proxy_outbounds, mode))
    routing = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules(proxy_outbounds, mode=mode),
        "balancers": build_balancers(proxy_outbounds, mode)
    }
    cfg["routing"] = routing
    return cfg


def build_no_proxy_config(mode: str = "bs") -> dict:
    """
    Профиль без прокси: в bs это случай «нет ни одного доступного bypass-узла».
    БС-домены и адреса идут напрямую, всё остальное блокируется (быстрый отказ).
    """
    print("  [!] В профиле нет прокси-узлов — не-БС трафик будет блокироваться",
          file=sys.stderr)
    cfg = base_config(mode, has_proxy=False)
    cfg["outbounds"] = [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg["routing"] = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules([], mode=mode, catch_all="block")
    }
    return cfg


def print_proxy_summary(proxy_outbounds: list, mode: str = "normal") -> None:
    """Выводит сводку о количестве прокси и балансировщике"""
    print(f"  → Режим: {mode}", file=sys.stderr)
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


def geoip_has_category(category: str) -> bool:
    """Есть ли категория в geoip.dat (проверка до генерации bs-профиля)."""
    asset_dir = os.environ.get("XRAY_LOCATION_ASSET", "/usr/share/xray")
    try:
        with open(os.path.join(asset_dir, "geoip.dat"), "rb") as f:
            data = f.read()
    except OSError:
        return False
    # в geoip.dat коды категорий хранятся в верхнем регистре (RU, PRIVATE)
    return category.upper().encode() in data or category.lower().encode() in data


def bs_categories_missing() -> list:
    """
    Категории белого списка, которых нет в геофайлах.
    Неизвестная категория делает конфиг невалидным, поэтому bs-профиль
    в этом случае не собирается (выход с кодом 3).
    """
    missing = []
    for item in ROUTING_CONFIG["bs_domains"]:
        if item.startswith("geosite:") and not geosite_has_category(item.split(":", 1)[1]):
            missing.append(item)
    for item in ROUTING_CONFIG["bs_ips"]:
        if item.startswith("geoip:") and not geoip_has_category(item.split(":", 1)[1]):
            missing.append(item)
    return missing


def is_bypass_node(ob: dict) -> bool:
    """
    Узел годится для режима БС: тег содержит bs_tag_pattern.
    В реальной подписке такие узлы называются bypass-1…bypass-20
    (после парсера — proxy-bypass-N).
    """
    pattern = str(ROUTING_CONFIG.get("bs_tag_pattern") or "bypass").lower()
    return bool(pattern) and pattern in str(ob.get("tag", "")).lower()


def load_selected_tags(path: str) -> list:
    """
    Теги узлов, отобранных пробой (bs-nodes.json, поле selected[].tag).
    Пустой результат — ограничение не применяется: в профиль идут все bypass-узлы.
    """
    if not path:
        return []
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print(f"  [!] Не удалось прочитать {path}: {e}", file=sys.stderr)
        return []
    tags = []
    for item in data.get("selected") or []:
        if isinstance(item, dict) and item.get("tag"):
            tags.append(str(item["tag"]))
        elif isinstance(item, str) and item:
            tags.append(item)
    return tags


def build_rules(proxy_outbounds: list, mode: str = "normal", direct_mode: bool = False,
                catch_all: str = "") -> list:
    """
    Строит правила маршрутизации.

    mode="normal": RU/private — напрямую, стриминг/игры и всё остальное — в балансировщик.
    mode="bs": домены и адреса из белого списка — напрямую, всё остальное — в балансировщик
    (т.е. в прокси). Реклама и QUIC блокируются в обоих режимах.
    catch_all — переопределение последнего правила, когда прокси нет
    (в bs — "block", чтобы недоступное не висело в таймаутах).
    """
    rules = [
        # Клиентский DNS (от dnsmasq) → dns-out (hijack → dns-inbuilt)
        {
            "type": "field",
            "inboundTag": ["dns-local"],
            "outboundTag": "dns-out"
        }
    ]

    # Non-local DNS (наш DoH через прокси) входит в routing с inboundTag = dns.tag.
    # Правило обязано стоять раньше любых domain-правил, иначе домен DoH-сервера
    # (cloudflare-dns.com) может попасть под direct и запрос уйдёт в блокировку.
    if not direct_mode and proxy_outbounds:
        rules.append({
            "type": "field",
            "inboundTag": ["dns-inbuilt"],
            "balancerTag": "balancer-dns"
        })

    # Домены проверки «какой у меня IP» (категория geosite:category-ipcheck в geosite.dat):
    # всегда напрямую и раньше остальных правил, иначе провайдер/сервис увидит IP прокси
    # и определит VPN. Отдельное правило, а не direct_domains: в режиме bs тот список не используется.
    rules.append({
        "type": "field",
        "domain": ["geosite:category-ipcheck"],
        "outboundTag": "direct"
    })

    rules += [
        # Блокировка рекламы — всегда, в любом режиме
        {
            "type": "field",
            "domain": ROUTING_CONFIG["block_domains"],
            "outboundTag": "block"
        },
        # NTP (порт 123) — напрямую
        {
            "type": "field",
            "port": "123",
            "network": "udp",
            "outboundTag": "direct"
        },
        # QUIC (UDP/443) — блокируем на уровне Xray (VLESS+XTLS не поддерживает UDP)
        {
            "type": "field",
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
        },
    ]

    if mode == "bs":
        # Белые списки оператора: домены и адреса — напрямую, прокси не тратится.
        # Домены приходят из sniffing (SNI/Host), поэтому работают и без DNS-резолва.
        rules.append({
            "type": "field",
            "domain": ROUTING_CONFIG["bs_domains"],
            "outboundTag": "direct"
        })
        rules.append({
            "type": "field",
            "ip": ROUTING_CONFIG["bs_ips"],
            "outboundTag": "direct"
        })
    else:
        # Локальные и российские IP — напрямую
        rules.append({
            "type": "field",
            "ip": ROUTING_CONFIG["direct_ips"],
            "outboundTag": "direct"
        })
        # Локальные и российские домены — напрямую
        rules.append({
            "type": "field",
            "domain": ROUTING_CONFIG["direct_domains"],
            "outboundTag": "direct"
        })

    if not direct_mode and proxy_outbounds:
        # Всегда через balancer — даже для одного прокси (observatory следит, fallback на direct)
        if mode != "bs":
            rules.append({
                "type": "field",
                "domain": ROUTING_CONFIG["proxy_domains"],
                "balancerTag": "balancer"
            })

        # Всё остальное — в прокси.
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "balancerTag": "balancer"
        })
    else:
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": catch_all or "direct"
        })

    return rules


def build_balancers(proxy_outbounds: list, mode: str = "normal") -> list:
    """
    Балансировщики. Их всегда два:
      balancer     — трафик; в bs fallbackTag=block (быстрый отказ, когда живых узлов нет),
                     в normal — direct (как раньше);
      balancer-dns — DNS-запросы; fallbackTag=direct, чтобы на старте,
                     пока у observatory нет данных, резолв не упирался в blackhole.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    return [
        {
            "tag": "balancer",
            "selector": selector,
            "strategy": {"type": "leastLoad"},
            "fallbackTag": "block" if mode == "bs" else "direct"
        },
        {
            "tag": "balancer-dns",
            "selector": selector,
            "strategy": {"type": "leastLoad"},
            "fallbackTag": "direct"
        }
    ]


def build_burst_observatory(proxy_outbounds: list, mode: str = "normal") -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.
    Используется со стратегией leastLoad.

    Пингует connectivitycheck.gstatic.com (Google Connectivity Check) —
    более надёжный endpoint, чем google.com, не троттлится.
    GET вместо HEAD — лучше совместимость с прокси-протоколами.
    Таймаут 15s — с запасом на Reality/TLS handshake.

    В bs-профиле узлов мало (только bypass-*), поэтому интервал сокращён до
    документированного минимума: пока observatory не собрал данные, leastLoad
    никого не выбирает и трафик уходит в fallbackTag.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    fast = mode == "bs"
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "10s" if fast else "1m",
                "sampling": 3 if fast else 10,
                "timeout": "15s",
                "httpMethod": "GET"
            }
        }
    }


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for OpenWrt TProxy')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--mode', default='normal', choices=['normal', 'bs'],
                        help='normal — обычная маршрутизация, bs — белые списки оператора')
    parser.add_argument('--nodes', default='',
                        help='JSON со списком отобранных пробой узлов (selected[].tag)')
    parser.add_argument('--format', default='unified', help=argparse.SUPPRESS)  # обратная совместимость, не используется
    return parser.parse_args()


def main():
    args = parse_args()
    mode = args.mode
    
    # Загружаем настройки из единого JSON-конфига
    load_settings(mode)
    
    print(f"  → Обработка унифицированной подписки (режим: {mode})", file=sys.stderr)
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        log_error(f"Failed to parse unified input: {e}")
        sys.exit(1)
    
    if data.get("hole", False):
        print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
        print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
        save_config(build_direct_config(mode), args.output)
        return
    
    raw_outbounds = data.get("outbounds", [])
    if not raw_outbounds:
        log_error("No outbounds in unified input — switching to DIRECT")
        save_config(build_direct_config(mode), args.output)
        return

    # Категории белого списка должны существовать в геофайлах: неизвестная категория
    # делает конфиг невалидным, поэтому такой профиль не устанавливаем (код 3).
    if mode == "bs":
        missing = bs_categories_missing()
        if missing:
            log_error(f"В геофайлах нет категорий: {', '.join(missing)}")
            log_error("Пересоберите geosite.dat/geoip.dat — bs-профиль не собран")
            sys.exit(3)

    # loopback возвращает трафик в маршрутизацию — в балансировщике он недопустим
    raw_outbounds = [
        ob for ob in raw_outbounds
        if ob.get("protocol") not in ("freedom", "blackhole", "dns", "loopback")
    ]

    # В bs-режиме в профиль попадают только узлы, которые умеют работать при БС
    # (в реальной подписке — теги bypass-1…bypass-20).
    if mode == "bs":
        total = len(raw_outbounds)
        raw_outbounds = [ob for ob in raw_outbounds if is_bypass_node(ob)]
        print(f"  → bypass-узлов: {len(raw_outbounds)} из {total}", file=sys.stderr)

        selected = load_selected_tags(args.nodes)
        if selected:
            keep = set(selected)
            matched = [ob for ob in raw_outbounds if ob.get("tag") in keep]
            if matched:
                raw_outbounds = matched
                print(f"  → Отобрано пробой: {len(matched)} узлов", file=sys.stderr)
            else:
                print("  [!] Теги из bs-nodes.json не найдены в подписке — берём все bypass-узлы",
                      file=sys.stderr)

    proxy_outbounds = [normalize_outbound(ob) for ob in raw_outbounds]
    cfg = build_proxy_config(proxy_outbounds, mode=mode)
    print_proxy_summary(proxy_outbounds, mode)
    save_config(cfg, args.output)


if __name__ == "__main__":
    main()