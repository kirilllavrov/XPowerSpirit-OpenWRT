#!/usr/bin/env python3
import json
import sys
import os

# -----------------------------
# ФИЛЬТР ПО ДОМЕНАМ (ТОЛЬКО WHITELIST)
# -----------------------------
DOMAIN_WHITELIST = [
    "router.freenternet.top"
]

def load_outbounds():
    """Читаем JSON из STDIN и приводим к списку."""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            return data
    except Exception:
        return []
    return []

def filter_by_domain_whitelist(all_obs):
    """Оставляем только сервера, чей address входит в whitelist."""
    if not DOMAIN_WHITELIST:
        return all_obs
    filtered = []
    for ob in all_obs:
        vnext = ob.get("settings", {}).get("vnext", [{}])[0]
        addr = vnext.get("address", "")
        if addr in DOMAIN_WHITELIST:
            filtered.append(ob)
    return filtered

def choose_best_server(servers):
    """Выбираем один сервер по whitelist. Если нет совпадений — первый."""
    if not servers:
        return None
    if not DOMAIN_WHITELIST:
        return servers[0]
    for ob in servers:
        vnext = ob.get("settings", {}).get("vnext", [{}])[0]
        addr = vnext.get("address", "")
        if addr in DOMAIN_WHITELIST:
            return ob
    return servers[0]

def base_config(geoip_path, geosite_path):
    return {
        "log": {"loglevel": "warning"},
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
                {
                    "address": "https://cloudflare-dns.com/dns-query",
                    "domains": [
                        "geosite:category-streaming",
                        "geosite:category-games"
                    ]
                },
                "https://cloudflare-dns.com/dns-query",
                "https://dns.google/dns-query"
            ]
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "port": 12345,
                "protocol": "dokodemo-door",
                "settings": {"network": "tcp,udp", "followRedirect": True},
                "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
                "sniffing": {"enabled": True, "destOverride": ["http", "tls"]}
            },
            {
                "tag": "dns-in",
                "port": 53,
                "protocol": "dokodemo-door",
                "settings": {
                    "address": "1.1.1.1",
                    "port": 53,
                    "network": "udp",
                    "followRedirect": False
                }
            }
        ],
        "geoip": geoip_path,
        "geosite": geosite_path
    }

def main():
    if len(sys.argv) != 7:
        print("Usage: xray-generate-config.py --geoip <file> --geosite <file> --output <file>")
        sys.exit(1)

    geoip_path = sys.argv[sys.argv.index("--geoip") + 1]
    geosite_path = sys.argv[sys.argv.index("--geosite") + 1]
    output_path = sys.argv[sys.argv.index("--output") + 1]

    all_obs = load_outbounds()
    filtered_obs = filter_by_domain_whitelist(all_obs)

    cfg = base_config(geoip_path, geosite_path)

    if len(filtered_obs) == 0:
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
        chosen = choose_best_server(filtered_obs)
        chosen_tag = chosen.get("tag", "proxy")
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
                    "geosite:private",
                    "geosite:category-browser",
                    "geosite:category-cdn-ru",
                    "geosite:category-mobile",
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
