#!/usr/bin/env python3
import json
import sys

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
    if not isinstance(servers, list):
        servers = [servers]
    return servers[0]


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
            "servers": [
                "https://cloudflare-dns.com/dns-query",
                "https://dns.google/resolve"
            ]
        },
        "inbounds": [
            # Основной TProxy inbound
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
                    "sockopt": { "tproxy": "tproxy" }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"]
                }
            },
            # Отдельный DNS inbound для dnsmasq
            {
                "tag": "dns-in",
                "listen": "127.0.0.1",
                "port": 1053,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp",
                    "followRedirect": False
                }
            }
        ]
    }


def build_rules(chosen_tag):
    return [
        {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},

        # Весь DNS от dnsmasq идёт через прокси
        {"type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out"},

        # Российские домены — напрямую (включая их DNS)
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

        # Streaming и игры — через прокси
        {
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "outboundTag": chosen_tag
        },

        # Всё остальное — через прокси
        {"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag}
    ]


def main():
    output_path = sys.argv[sys.argv.index("--output") + 1]

    all_obs = load_outbounds()
    chosen = choose_best_server(all_obs)

    cfg = base_config()

    chosen_tag = "proxy"
    if chosen and "tag" not in chosen:
        chosen["tag"] = chosen_tag

    if chosen:
        # Mark для исключения трафика Xray самого из tproxy
        ss = chosen.setdefault("streamSettings", {})
        ss.setdefault("sockopt", {})["mark"] = 255

        cfg["outbounds"] = [
            chosen,
            {
                "protocol": "freedom",
                "tag": "direct",
                "streamSettings": {"sockopt": {"mark": 255}}
            },
            {"protocol": "blackhole", "tag": "block"},
            # DNS outbound — весь DNS через основной прокси
            {
                "tag": "dns-out",
                "protocol": "dns",
                "settings": {
                    "address": "https://cloudflare-dns.com/dns-query"
                },
                "proxySettings": {
                    "tag": chosen_tag
                }
            }
        ]
    else:
        # fallback
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]

    cfg["routing"] = {
        "domainStrategy": "ForceIPv4",
        "rules": build_rules(chosen_tag)
    }

    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"✅ Выбран сервер: {chosen_tag}", file=sys.stderr)
    print(f"📁 Конфиг сохранён: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()