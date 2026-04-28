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
    if not servers:
        return None
    
    if not isinstance(servers, list):
        servers = [servers]
    
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

        return servers[0]

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
            "queryStrategy": "UseIPv4",
            "enableParallelQuery": True,
            "disableCache": False,
            "cacheStrategy": "cacheEnabled",
            "serveStale": True,
            "disableFallback": False,
            "servers": [
                "https://cloudflare-dns.com/dns-query",
                "https://dns.google/resolve"
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
                    "address": "127.0.0.1",
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
    rules = [
        {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
        {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "direct"},
        {
            "type": "field",
            "domain": ["full:cloudflare-dns.com", "full:dns.google"],
            "outboundTag": "direct"
        },
        {
            "type": "field",
            "port": 53,
            "network": "udp",
            "outboundTag": "direct"
        }
    ]
    
    if has_proxy:
        rules.append({"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"})
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
        rules.append({
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "outboundTag": chosen_tag
        })
        rules.append({"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag})
    else:
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

    all_obs = load_outbounds()
    chosen = choose_best_server(all_obs)
    
    if chosen is None:
        cfg = base_config()
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": build_rules("direct", False)
        }
        print("⚠️  Нет доступных серверов. Создан DIRECT-конфиг.", file=sys.stderr)
    else:
        cfg = base_config()
        chosen_tag = chosen.get("tag", "proxy")
        ss = chosen.setdefault("streamSettings", {})
        ss.setdefault("sockopt", {})["mark"] = 255
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
    
    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    
    print(f"📁 Конфиг сохранён: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
