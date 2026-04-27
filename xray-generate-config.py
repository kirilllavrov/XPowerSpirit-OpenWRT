#!/usr/bin/env python3
import json
import sys
import os

# Whitelist: если задан, выбираем только серверы из этого списка
# Пустой = брать первый доступный сервер
DOMAIN_WHITELIST = ["router.freenternet.top"] 

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

def choose_best_server(servers):
    """
    Выбирает сервер:
    - Если DOMAIN_WHITELIST задан: возвращает первый сервер, чей address есть в списке
    - Если список пуст: возвращает первый сервер из подписки
    - Если не найдено: возвращает None (fallback на direct)
    """
    if not servers:
        return None
    
    if DOMAIN_WHITELIST:
        for ob in servers:
            vnext = ob.get("settings", {}).get("vnext", [{}])[0]
            addr = vnext.get("address", "")
            if addr in DOMAIN_WHITELIST:
                return ob
        # Ни один сервер из вайтлиста не найден
        return None
    
    # Без вайтлиста — берём первый
    return servers[0]

def base_config():
    """Базовая конфигурация (лог, DNS, inbounds)"""
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
                "https://dns.google/dns-query"
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

def main():
    if len(sys.argv) != 3:
        print("Usage: xray-generate-config.py --output <file>")
        sys.exit(1)
    
    output_path = sys.argv[sys.argv.index("--output") + 1]
    
    all_obs = load_outbounds()
    chosen = choose_best_server(all_obs)
    chosen_tag = chosen.get("tag", "proxy") if chosen else "direct"
    
    cfg = base_config()
    
    if not chosen:
        # Нет подходящего сервера — режим fallback (только direct/block)
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": [
                {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
                {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "direct"},
                {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
            ]
        }
    else:
        # Добавляем sockopt mark 255, чтобы исходящий трафик Xray не попадал в TProxy
        if "streamSettings" not in chosen:
            chosen["streamSettings"] = {}
        chosen["streamSettings"]["sockopt"] = {"mark": 255}
        
        cfg["outbounds"] = [
            chosen,
            {
                "protocol": "freedom",
                "tag": "direct",
                "streamSettings": {"sockopt": {"mark": 255}}
            },
            {"protocol": "blackhole", "tag": "block"}
        ]
        
        # Правила маршрутизации: ПОРЯДОК КРИТИЧЕН!
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": [
                # 1. Блокировка рекламы (сначала)
                {
                    "type": "field",
                    "domain": ["geosite:category-ads"],
                    "outboundTag": "block"
                },
                # 2. DNS-трафик — ВСЕГДА напрямую (фикс петли резолвинга!)
                {
                    "type": "field",
                    "inboundTag": ["dns-in"],
                    "outboundTag": "direct"
                },
                # 3. Частные IP — напрямую (до catch-all, чтобы не проксировать 192.168.1.1)
                {
                    "type": "field",
                    "ip": ["geoip:private"],
                    "outboundTag": "direct"
                },
                # 4. Русские домены и сервисы — напрямую
                {
                    "type": "field",
                    "domain": [
                        "geosite:private",
                        "geosite:category-browser",
                        "geosite:category-cdn-ru",
                        "geosite:category-mobile",
                        "geosite:category-ru"
                    ],
                    "outboundTag": "direct"
                },
                # 5. Стриминг/игры — через прокси (опционально, можно убрать)
                {
                    "type": "field",
                    "domain": ["geosite:category-streaming", "geosite:category-games"],
                    "outboundTag": chosen_tag
                },
                # 6. Catch-all: всё остальное — через прокси
                {
                    "type": "field",
                    "network": "tcp,udp",
                    "outboundTag": chosen_tag
                }
            ]
        }
    
    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"Готово: {output_path}")

if __name__ == "__main__":
    main()