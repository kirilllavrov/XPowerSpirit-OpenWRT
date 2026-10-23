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

SETTINGS_FILE = "/etc/xray/settings.json"

# Whitelist по умолчанию (переопределяется из settings.json)
DOMAIN_WHITELIST = []

# Категория geosite с доменами проверки «какой у меня IP» (ifconfig.me, api.ipify.org,
# 2ip.ru и подобные). Провайдеры и сервисы используют их для детекта VPN, поэтому
# такие домены обязаны идти напрямую. Сами домены живут в geosite.dat, не в settings.json.
IP_CHECK_GEOSITE = "geosite:category-ipcheck"

# Правила роутинга по умолчанию (переопределяются из settings.json → routing)
ROUTING_CONFIG = {
    "domainStrategy": "IPOnDemand",
    "block_domains": ["geosite:category-ads"],
    "direct_ips": ["geoip:ru", "geoip:private"],
    "direct_domains": [
        "geosite:private",
        "geosite:category-browser",
        "geosite:category-cdn-ru",
        "geosite:category-mobile",
        "geosite:category-ru"
    ],
    "proxy_domains": [
        "geosite:category-streaming",
        "geosite:category-games"
    ],
    # Белые списки (БС) операторов РФ — отдельные категории тех же геофайлов.
    # Домены живут в geosite.dat, адреса — в geoip.dat; это разные категории.
    "bs_domains": ["geosite:category-whitelist"],
    "bs_ips": ["geoip:whitelist"],
    # DNS: БС/RU-домены резолвит Яндекс напрямую (DOHL, routing не проходит),
    # всё остальное — DoH через прокси (входит в routing с inboundTag=dns-inbuilt).
    "dns_direct_address": "https+local://common.dot.dns.yandex.net/dns-query",
    "dns_proxy_address": "https://cloudflare-dns.com/dns-query",
    "dns_hosts": {
        "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
        "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
        "dns.google": ["8.8.8.8", "8.8.4.4"],
        "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"]
    }
}


def load_settings():
    """Загружает настройки из /etc/xray/settings.json"""
    global DOMAIN_WHITELIST, ROUTING_CONFIG
    if os.path.isfile(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE) as f:
                settings = json.load(f)
            DOMAIN_WHITELIST = settings.get("subscription", {}).get("domain_whitelist", [])
            # Загружаем правила роутинга (мержим с дефолтами — пользователь может переопределить любое поле)
            user_routing = settings.get("routing", {})
            if user_routing:
                for key in ROUTING_CONFIG:
                    if key in user_routing:
                        ROUTING_CONFIG[key] = user_routing[key]
        except Exception as e:
            print(f"  [!] Не удалось прочитать {SETTINGS_FILE}: {e}", file=sys.stderr)


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
    cfg = base_config(mode, has_proxy=True)
    cfg["outbounds"] = proxy_outbounds + [make_direct_outbound(), make_block_outbound(), build_dns_outbound()]
    cfg.update(build_burst_observatory(proxy_outbounds))
    routing = {
        "domainStrategy": ROUTING_CONFIG["domainStrategy"],
        "rules": build_rules(proxy_outbounds, mode=mode),
        "balancers": build_balancers(proxy_outbounds, mode)
    }
    cfg["routing"] = routing
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


def build_rules(proxy_outbounds: list, mode: str = "normal", direct_mode: bool = False) -> list:
    """
    Строит правила маршрутизации.

    mode="normal": RU/private — напрямую, стриминг/игры и всё остальное — в балансировщик.
    mode="bs": домены и адреса из белого списка — напрямую, всё остальное — в балансировщик
    (т.е. в прокси). Реклама и QUIC блокируются в обоих режимах.
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

    # Домены проверки IP — всегда напрямую и раньше остальных правил:
    # иначе провайдер/сервис увидит IP прокси и определит VPN
    if ip_check_geosite_available():
        rules.append({
            "type": "field",
            "domain": [IP_CHECK_GEOSITE],
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
            "outboundTag": "direct"
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


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.
    Используется со стратегией leastLoad.
    
    Пингует connectivitycheck.gstatic.com (Google Connectivity Check) —
    более надёжный endpoint, чем google.com, не троттлится.
    GET вместо HEAD — лучше совместимость с прокси-протоколами.
    Таймаут 15s — с запасом на Reality/TLS handshake.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "1m",
                "sampling": 10,
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
    parser.add_argument('--format', default='unified', help=argparse.SUPPRESS)  # обратная совместимость, не используется
    return parser.parse_args()


def main():
    args = parse_args()
    mode = args.mode
    
    # Загружаем настройки из единого JSON-конфига
    load_settings()
    if DOMAIN_WHITELIST:
        print(f"  → Domain whitelist из settings.json: {', '.join(DOMAIN_WHITELIST)}", file=sys.stderr)
    
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
    proxy_outbounds = [normalize_outbound(ob) for ob in raw_outbounds]
    cfg = build_proxy_config(proxy_outbounds, mode=mode)
    print_proxy_summary(proxy_outbounds, mode)
    save_config(cfg, args.output)


if __name__ == "__main__":
    main()