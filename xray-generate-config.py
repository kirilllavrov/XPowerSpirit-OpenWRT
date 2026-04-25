#!/usr/bin/env python3
# xray-generate-config.py
# Генератор полного Xray config.json для OpenWrt 25.12.x (TProxy)
# XPowerSpirit-OpenWRT

import json
import argparse
import sys


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def build_config(outbound, geoip_path, geosite_path):
    """
    Формирует полный config.json для Xray.
    """

    config = {
        "log": {
            "loglevel": "warning"
        },

        # -----------------------------
        # DNS через Xray
        # -----------------------------
        "dns": {
            "servers": [
                {
                    "address": "https://1.1.1.1/dns-query",
                    "domains": ["geosite:geolocation-!cn"]
                },
                {
                    "address": "https://77.88.8.8/dns-query",
                    "domains": ["geosite:cn"]
                },
                "localhost"
            ]
        },

        # -----------------------------
        # Inbounds (TProxy)
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

        # -----------------------------
        # Outbounds
        # -----------------------------
        "outbounds": [
            outbound,  # основной VLESS из подписки
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {}
            },
            {
                "tag": "block",
                "protocol": "blackhole",
                "settings": {}
            }
        ],

        # -----------------------------
        # Маршрутизация
        # -----------------------------
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:private"]
                },
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ["geosite:cn"]
                },
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:cn"]
                },
                {
                    "type": "field",
                    "outboundTag": "block",
                    "protocol": ["bittorrent"]
                }
            ]
        },

        # -----------------------------
        # Путь к geoip/geosite
        # -----------------------------
        "policy": {},
        "stats": {},
        "api": {
            "services": ["StatsService"],
            "tag": "api"
        },
        "reverse": {},
        "fakedns": [],
        "transport": {},
        "geoip": geoip_path,
        "geosite": geosite_path
    }

    return config


def main():
    parser = argparse.ArgumentParser(description="Xray config generator for OpenWrt")
    parser.add_argument("--outbound", required=True, help="Path to outbound.json")
    parser.add_argument("--geoip", required=True, help="Path to geoip.dat")
    parser.add_argument("--geosite", required=True, help="Path to geosite.dat")
    parser.add_argument("--output", required=True, help="Output config.json")

    args = parser.parse_args()

    try:
        outbound = load_json(args.outbound)
    except Exception as e:
        print(f"Ошибка чтения outbound.json: {e}")
        sys.exit(1)

    config = build_config(outbound, args.geoip, args.geosite)

    try:
        save_json(args.output, config)
    except Exception as e:
        print(f"Ошибка записи config.json: {e}")
        sys.exit(1)

    print(f"Готово: {args.output}")


if __name__ == "__main__":
    main()
