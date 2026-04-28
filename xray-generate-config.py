#!/usr/bin/env python3
import json
import sys

# -----------------------------
# НАСТРОЙКИ
# -----------------------------
DOMAIN_WHITELIST = []


# -----------------------------
# ЗАГРУЗКА OUTBOUNDS
# -----------------------------
def load_outbounds():
    """Загружает outbounds из stdin (JSON list или dict)"""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            return data
    except Exception:
        return []
    return []


# -----------------------------
# ВЫБОР ЛУЧШЕГО СЕРВЕРА
# -----------------------------
def extract_address(ob):
    """Достаёт host из settings.vnext"""
    try:
        return ob["settings"]["vnext"][0]["address"]
    except Exception:
        return None


def extract_sni(ob):
    """Достаёт SNI из streamSettings"""
    # Для Reality
    try:
        return ob["streamSettings"]["realitySettings"]["serverName"]
    except Exception:
        pass
    # Для обычного TLS
    try:
        return ob["streamSettings"]["tlsSettings"]["serverName"]
    except Exception:
        return None


def extract_host_header(ob):
    """Достаёт Host из ws/http/xhttp"""
    try:
        ws = ob["streamSettings"].get("wsSettings")
        if ws and "headers" in ws:
            return ws["headers"].get("Host")
    except Exception:
        pass

    try:
        http = ob["streamSettings"].get("httpSettings")
        if http and "host" in http:
            return http["host"][0]
    except Exception:
        pass

    try:
        xhttp = ob["streamSettings"].get("xhttpSettings")
        if xhttp and "host" in xhttp:
            return xhttp["host"][0]
    except Exception:
        pass

    return None


def choose_best_server(servers):
    """
    Выбирает сервер:
    - проверяет address
    - проверяет SNI
    - проверяет Host header
    
    Возвращает None если серверов нет или они не подходят
    """
    # Пустой список или None
    if not servers:
        return None
    
    # Нормализация: убеждаемся что это список
    if not isinstance(servers, list):
        servers = [servers]
    
    # Всё ещё пусто?
    if not servers:
        return None

    if DOMAIN_WHITELIST:
        for ob in servers:
            addr = extract_address(ob)
            sni = extract_sni(ob)
            host = extract_host_header(ob)

            if addr in DOMAIN_WHITELIST:
                return ob
            if sni in DOMAIN_WHITELIST:
                return ob
            if host in DOMAIN_WHITELIST:
                return ob

        # Не нашли в whitelist, но сервера есть - берём первый
        return servers[0]

    # Нет whitelist - берём первый сервер
    return servers[0] if servers else None


# -----------------------------
# БАЗОВАЯ КОНФИГУРАЦИЯ
# -----------------------------
def base_config():
    return {
        "log": {
            "loglevel": "warning",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": {
            "hosts": {
                "cloudflare-dns.com": "1.1.1.1",
                "dns.google": "8.8.8.8"
            },
            "queryStrategy": "UseIPv4",
            "enableParallelQuery": True,
            "disableCache": False,
            "cacheStrategy": "cacheEnabled",
            "serveStale": True,
            "disableFallback": False,
            "servers": [
                {
                    "address": "195.208.4.1",
                    "port": 53,
                    "domains": [
                        "geosite:category-ru",
                        "geosite:category-browser",
                        "geosite:category-mobile",
                        "geosite:category-cdn-ru",
                        "geosite:private"
                    ]
                },
                {
                    "address": "195.208.5.1",
                    "port": 53,
                    "domains": [
                        "geosite:category-ru",
                        "geosite:category-browser",
                        "geosite:category-mobile",
                        "geosite:category-cdn-ru",
                        "geosite:private"
                    ]
                },
                "https://cloudflare-dns.com/dns-query",
                "https://dns.google/dns-query",
                # Fallback plain DNS
                {
                    "address": "8.8.8.8",
                    "port": 53
                },
                {
                    "address": "1.1.1.1",
                    "port": 53
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
                    "network": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"]
                }
            },
            {
                "tag": "dns-in",
                "listen": "127.0.0.1",
                "port": 1053,
                "protocol": "dokodemo-door",
                "settings": {
                    "address": "1.1.1.1",
                    "port": 53,
                    "network": "udp",
                    "followRedirect": False
                }
            }
        ]
    }


# -----------------------------
# ФОРМИРОВАНИЕ RULES
# -----------------------------
def build_rules(chosen_tag, has_proxy):
    """Формирует список правил маршрутизации"""
    rules = [
        # Блокировка рекламы
        {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
        
        # DNS-запросы от dns-in идут напрямую
        {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "direct"},
        
        # Явное правило для DoH-серверов (предотвращает петлю)
        {
            "type": "field",
            "domain": ["full:cloudflare-dns.com", "full:dns.google"],
            "outboundTag": "direct"
        },
        
        # Весь DNS-трафик (порт 53) напрямую
        {
            "type": "field",
            "port": 53,
            "network": "udp",
            "outboundTag": "direct"
        }
    ]
    
    if has_proxy:
        # Приватные IP напрямую
        rules.append({"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"})
        
        # Российские и локальные домены напрямую
        rules.append({
            "type": "field",
            "domain": [
                "geosite:private",
                "geosite:category-browser",
                "geosite:category-cdn-ru",
                "geosite:category-mobile",
                "geosite:category-ru"
            ],
            "outboundTag": "direct"
        })
        
        # Стриминг и игры через прокси
        rules.append({
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "outboundTag": chosen_tag
        })
        
        # Всё остальное через прокси
        rules.append({"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag})
    else:
        # Если нет прокси, всё напрямую
        rules.append({"type": "field", "network": "tcp,udp", "outboundTag": "direct"})
    
    return rules


# -----------------------------
# MAIN
# -----------------------------
def main():
    if len(sys.argv) != 3:
        print("Usage: xray-generate-config.py --output <file>")
        sys.exit(1)

    output_path = sys.argv[sys.argv.index("--output") + 1]

    # Загружаем outbounds
    all_obs = load_outbounds()
    
    # Пытаемся выбрать сервер
    chosen = choose_best_server(all_obs)
    
    # ===== КЛЮЧЕВАЯ ЛОГИКА =====
    # Если сервер НЕ выбран (нет серверов ИЛИ не прошёл whitelist)
    if chosen is None:
        # DIRECT режим - без прокси
        cfg = base_config()
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": build_rules("direct", False)
        }
        
        # Логируем в stderr (не ломает JSON pipeline)
        print("⚠️  Нет доступных серверов. Создан DIRECT-конфиг.", file=sys.stderr)
    else:
        # Нормальный режим с прокси
        cfg = base_config()
        chosen_tag = chosen.get("tag", "proxy")
        
        # Добавляем mark=255
        ss = chosen.setdefault("streamSettings", {})
        ss.setdefault("sockopt", {})["mark"] = 255
        
        # Убеждаемся что есть tag
        if "tag" not in chosen:
            chosen["tag"] = "proxy"
        
        cfg["outbounds"] = [
            chosen,
            {
                "protocol": "freedom",
                "tag": "direct",
                "streamSettings": {"sockopt": {"mark": 255}}
            },
            {"protocol": "blackhole", "tag": "block"}
        ]
        
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": build_rules(chosen_tag, True)
        }
        
        print(f"✅ Выбран сервер: {chosen_tag}", file=sys.stderr)
    
    # Сохраняем конфиг
    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    
    print(f"📁 Конфиг сохранён: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()