#!/usr/bin/env python3
import json
import sys

# Убрали жёсткий whitelist — теперь берём первый сервер из подписки
# Если хочешь оставить только определённые — добавь их сюда
DOMAIN_WHITELIST = []  # пустой = брать все

def load_outbounds():
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
    if not servers:
        return None
    # Если whitelist пустой — берём первый
    if not DOMAIN_WHITELIST:
        return servers[0]
    for ob in servers:
        vnext = ob.get("settings", {}).get("vnext", [{}])[0]
        addr = vnext.get("address", "")
        if addr in DOMAIN_WHITELIST:
            return ob
    return servers[0]

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
                {"address": "195.208.4.1", "port": 53, "domains": ["geosite:category-ru", "geosite:category-browser", "geosite:category-mobile", "geosite:category-cdn-ru", "geosite:private"]},
                {"address": "195.208.5.1", "port": 53, "domains": ["geosite:category-ru", "geosite:category-browser", "geosite:category-mobile", "geosite:category-cdn-ru", "geosite:private"]},
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
                "settings": {"network": "tcp,udp", "followRedirect": True},
                "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
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
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": [
                {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
                {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
            ]
        }
    else:
        cfg["outbounds"] = [
            chosen,
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": [
                {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},
                {"type": "field", "domain": ["geosite:category-streaming", "geosite:category-games"], "outboundTag": chosen_tag},
                {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
                {"type": "field", "domain": [
                    "geosite:private", "geosite:category-browser",
                    "geosite:category-cdn-ru", "geosite:category-mobile",
                    "geosite:category-ru"
                ], "outboundTag": "direct"},
                {"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag}
            ]
        }

    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"Готово: {output_path}")

if __name__ == "__main__":
    main()