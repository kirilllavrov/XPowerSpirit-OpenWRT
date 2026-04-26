#!/bin/sh
# install-xray-nft.sh — версия без fw4, чистый nftables
# Установка Xray + TProxy + подписка + geoфайлы + генератор
# OpenWrt 25.12.x (apk-based)

set -e

REPO_RAW="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

GEO_DIR="/usr/share/xray"
mkdir -p "$GEO_DIR"

GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo "=== Установка Xray на OpenWrt (чистый nftables) ==="

# 1. Проверка root
if [ "$(id -u)" != "0" ]; then
    echo "Этот скрипт нужно запускать от root."
    exit 1
fi

# 2. Запрос подписки
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: URL подписки пустой."; exit 1; }

mkdir -p /etc/xray
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 3. Установка пакетов
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 4. Установка geoip/geosite
curl -fsSL "$GEOIP_URL" -o "$GEOIP"
curl -fsSL "$GEOSITE_URL" -o "$GEOSITE"

# 5. Скачивание генератора, парсера и обновлялки
wget -q "$REPO_RAW/xray-generate-config.py" -O "$GENERATOR"
chmod +x "$GENERATOR"

wget -q "$REPO_RAW/xray-sub-parser.py" -O "$PARSER"
chmod +x "$PARSER"

wget -q "$REPO_RAW/update-xray.sh" -O "$UPDATER"
chmod +x "$UPDATER"

# 6. Настройка dnsmasq → Xray
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 7. nftables ruleset (собственная таблица ip xray)
cat > /etc/nftables.d/xray.nft << 'EOF'
table ip xray {
    chain prerouting {
        type filter hook prerouting priority mangle;
        policy accept;

        # Bypass приватных подсетей
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return

        # Bypass трафика самого Xray
        meta mark 0xff return

        # DHCP — не трогать
        udp dport { 67, 68 } return

        # QUIC drop
        iifname "br-lan" udp dport 443 drop

        # TCP TPROXY
        iifname "br-lan" meta l4proto tcp \
            tproxy to 127.0.0.1:12345 meta mark set 1 accept

        # UDP TPROXY
        iifname "br-lan" meta l4proto udp \
            tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

nft -f /etc/nftables.d/xray.nft

# 8. HWID
if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

# 9. Генерация config.json
curl -s -L -m 15 -H "User-Agent: Happ" -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 "$PARSER" | python3 "$GENERATOR" \
    --output "$CONFIG_JSON"

# 10. Cron
CRON_LINE="0 */3 * * * /root/update-xray.sh"
grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# 11. Перезапуск сервисов
/etc/init.d/dnsmasq restart
/etc/init.d/xray restart

# 12. Диагностика
echo "=== Проверка ==="
if pgrep -x "xray" >/dev/null; then
    echo "[OK] Xray запущен"
else
    echo "[ERR] Xray НЕ запущен!"
fi

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "[OK] Конфиг Xray валиден"
else
    echo "[ERR] Конфиг Xray содержит ошибки!"
fi

if nft list table ip xray >/dev/null 2>&1; then
    echo "[OK] nftables: таблица ip xray активна"
else
    echo "[ERR] nftables: таблица ip xray отсутствует!"
fi

echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"
