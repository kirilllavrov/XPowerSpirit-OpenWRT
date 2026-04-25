#!/usr/bin/env python3
import json
import os
import sys

OUTBOUNDS_FILE = "/tmp/new_outbounds.json"

# -----------------------------
# ФИЛЬТР ПО ДОМЕНАМ (ТОЛЬКО WHITELIST)
# -----------------------------
DOMAIN_WHITELIST = [
    "cdn.redcook.ru"
]


def load_outbounds():
    if not os.path.exists(OUTBOUNDS_FILE):
        return []

    try:
        with open(OUTBOUNDS_FILE, "r") as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
    except Exception:
        pass

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
    """Выбираем один сервер по whitelist. Если whitelist пуст — первый."""
    if not servers:
        return None

    # Если whitelist пуст — берём первый сервер
    if not DOMAIN_WHITELIST:
        return servers[0]

    # Иначе берём первый сервер из whitelist
    for ob in servers:
        vnext = ob.get("settings", {}).get("vnext", [{}])[0]
        addr = vnext.get("address", "")
        if addr in DOMAIN_WHITELIST:
            return ob

    # Если ни один не подходит — fallback: первый сервер
    return servers[0]


# -----------------------------
# БАЗОВЫЙ TPROXY-КОНФИГ
# -----------------------------
def base_config(geoip_path, geosite_path):
    return {
        "log": {
            "loglevel": "warning"
        },

        # -----------------------------
        # DNS (из прикреплённого генератора)
        # -----------------------------
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

        # -----------------------------
        # INBOUNDS (TPROXY)
        # -----------------------------
        "inbounds": [
            {
                "tag": "tproxy-in",
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


# -----------------------------
# ГЕНЕРАЦИЯ КОНФИГА
# -----------------------------
def main():
    if len(sys.argv) != 5:
        print("Usage: xray-generate-config.py --outbound <file> --geoip <file> --geosite <file> --output <file>")
        sys.exit(1)

    args = sys.argv
    outbound_file = args[args.index("--outbound") + 1]
    geoip_path = args[args.index("--geoip") + 1]
    geosite_path = args[args.index("--geosite") + 1]
    output_path = args[args.index("--output") + 1]

    # Загружаем основной outbound (не используется напрямую)
    try:
        with open(outbound_file, "r") as f:
            _ = json.load(f)
    except Exception as e:
        print(f"Ошибка чтения outbound.json: {e}")
        sys.exit(1)

    # Загружаем список всех серверов
    all_obs = load_outbounds()
    filtered_obs = filter_by_domain_whitelist(all_obs)

    cfg = base_config(geoip_path, geosite_path)

    # -----------------------------
    # 0 серверов → direct only
    # -----------------------------
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
        with open(output_path, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(f"Готово: {output_path}")
        return

    # -----------------------------
    # 1+ серверов → выбираем один по whitelist
    # -----------------------------
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
