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
    try:
        return ob["settings"]["vnext"][0]["address"]
    except Exception:
        return None


def choose_best_server(servers):
    if not servers:
        return None
    if not isinstance(servers, list):
        servers = [servers]
    if DOMAIN_WHITELIST:
        for ob in servers:
            addr = extract_address(ob)
            if addr in DOMAIN_WHITELIST:
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
            }
        ]
    }


# -----------------------------
# ФОРМИРОВАНИЕ RULES
# -----------------------------
def build_rules(chosen_tag):
    return [
        # 1. Блокировка рекламы
        {"type": "field", "domain": ["geosite:category-ads"], "outboundTag": "block"},

        # 2. Российский трафик — напрямую
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

        # 3. Streaming и игры — через прокси
        {
            "type": "field",
            "domain": ["geosite:category-streaming", "geosite:category-games"],
            "outboundTag": chosen_tag
        },

        # 4. Всё остальное — через прокси
        {"type": "field", "network": "tcp,udp", "outboundTag": chosen_tag}
    ]


# -----------------------------
# MAIN
# -----------------------------
def main():
    if len(sys.argv) != 3 or sys.argv[1] != "--output":
        print("Usage: xray-generate-config.py --output <file>")
        sys.exit(1)

    output_path = sys.argv[2]

    all_obs = load_outbounds()
    chosen = choose_best_server(all_obs)

    cfg = base_config()

    if chosen is None:
        cfg["outbounds"] = [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"}
        ]
        cfg["routing"] = {
            "domainStrategy": "ForceIPv4",
            "rules": build_rules("direct")
        }
        print("⚠️ Нет доступных серверов. Создан DIRECT-конфиг.", file=sys.stderr)
    else:
        chosen_tag = chosen.get("tag") or "proxy"
        if "tag" not in chosen:
            chosen["tag"] = chosen_tag

        # Добавляем mark для исключения трафика Xray из tproxy
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
            "rules": build_rules(chosen_tag)
        }
        print(f"✅ Выбран сервер: {chosen_tag}", file=sys.stderr)

    with open(output_path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    print(f"📁 Конфиг сохранён: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
