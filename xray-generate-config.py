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


def load_settings():
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

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    return {
        "log": {
            "loglevel": "none",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": {
            "tag": "dns-inbuilt",
            "queryStrategy": "UseIPv4",
            "disableCache": False,
            "serveStale": True,
            "serveExpiredTTL": 600,
            "disableFallback": False,
            "disableFallbackIfMatch": True,
            "enableParallelQuery": True,
            "hosts": {
                "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
                "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"]
            },
            "servers": [
                {
                    "address": "https+local://common.dot.dns.yandex.net/dns-query",
                    "domains": ["geosite:category-ru"],
                    "expectedIPs": ["geoip:ru"],
                    "skipFallback": True
                },
                {
                    "address": "https+local://cloudflare-dns.com/dns-query",
                    "skipFallback": False
                },
                {
                    "address": "https+local://dns.nextdns.io",
                    "skipFallback": False
                }
            ]
        },
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
            "type": "field",
            "inboundTag": ["dns-local"],
            "outboundTag": "dns-out"
        }
    ]

    # Домены проверки IP — всегда напрямую и раньше остальных правил:
    # иначе провайдер/сервис увидит IP прокси и определит VPN
    if ip_check_geosite_available():
        rules.append({
            "type": "field",
            "domain": [IP_CHECK_GEOSITE],
            "outboundTag": "direct"
        })

    rules += [
        # Ловим DNS через DoH, которые прошли мимо dnsmasq (от браузера)
        {
            "type": "field",
            "domain": ROUTING_CONFIG["doh_domains"],
            "outboundTag": "direct"
        },
        # Блокировка рекламы
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
        # Локальные и российские IP — напрямую
        {
            "type": "field",
            "ip": ROUTING_CONFIG["direct_ips"],
            "outboundTag": "direct"
        },
        # Локальные и российские домены — напрямую
        {
            "type": "field",
            "domain": ROUTING_CONFIG["direct_domains"],
            "outboundTag": "direct"
        },
    ]
    
    if not direct_mode and proxy_outbounds:
        # Всегда через balancer — даже для одного прокси (observatory следит, fallback на direct)
        rules.append({
            "type": "field",
            "domain": ROUTING_CONFIG["proxy_domains"],
            "balancerTag": "balancer"
        })
        
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


def build_balancer(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию балансировщика для нескольких прокси (leastLoad).    
    leastLoad выбирает наиболее стабильные серверы на основе данных burstObservatory.    
    Если все серверы не проходят — fallback на direct.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": {
            "type": "leastLoad",
        },
        "fallbackTag": "direct"
    }


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