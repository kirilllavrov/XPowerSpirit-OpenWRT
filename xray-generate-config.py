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
    """
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

        return None

    return servers[0]


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
    chosen_tag = chosen.get("tag", "proxy") if chosen else "direct"

    cfg = base_config()

    if not chosen:
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
        # Добавляем mark=255, не ломая структуру
        ss = chosen.setdefault("streamSettings", {})
        ss.setdefault("sockopt", {})["mark"] = 255

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
            "rules": [
                {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
                {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "direct"},
                {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
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
                {
                    "type": "field",
                    "domain": ["geosite:category-streaming", "geosite:category-games"],
                    "outboundTag": chosen_tag
                },
                {"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag}
            ]
        }

    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"Готово: {output_path}")


if __name__ == "__main__":
    main()
