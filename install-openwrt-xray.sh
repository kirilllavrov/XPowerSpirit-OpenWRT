#!/bin/sh
# install-openwrt-xray.sh — исправленная версия для OpenWrt 25.12.x (fw4 + nftables)
# Xray + TProxy (IPv4-only) + правильные nftables includes

set -e

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

echo "=== Установка Xray TProxy (fw4-compatible) ==="

[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# 1. Подписка
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }

mkdir -p /etc/xray
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 2. Установка пакетов
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 3. Скачивание скриптов
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
wget -q "$REPO/diagnose-xray-tproxy.sh" -O "$DIAG"; chmod +x "$DIAG"

# 4. Настройка dnsmasq → Xray DNS
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 5. TProxy nftables правила (ПРАВИЛЬНЫЙ способ для fw4)
echo "Настройка nftables TProxy..."

mkdir -p /usr/share/nftables.d/ruleset-post

cat > /usr/share/nftables.d/ruleset-post/30-xray-tproxy.nft << 'EOF'
# Xray TProxy chain — добавляется в ruleset-post
table ip xray {
    chain xray_tproxy {
        type filter hook prerouting priority mangle; policy accept;

        # === 1. Bypass правила (должны быть ПЕРВЫМИ) ===
        iifname "br-lan" udp dport {67, 68} return              # DHCP
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
        meta mark 0xff return                                   # Xray сам себя (чтобы не было петли)

        # === 2. TProxy для всего остального трафика с LAN ===
        iifname "br-lan" meta l4proto { tcp, udp } tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

# 6. Policy routing
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables

# Удаляем старые правила, если есть, и добавляем новые
ip rule del fwmark 1 lookup xray 2>/dev/null || true
ip rule add fwmark 1 lookup xray priority 100

ip route flush table xray 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table xray

# 7. sysctl настройки
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

grep -q "net.ipv4.conf.all.route_localnet=1" /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 8. HWID
if [ ! -f "$HWID_FILE" ]; then
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
else
    HWID="$(cat "$HWID_FILE")"
fi

# 9. Генерация config.json
echo "Генерация config.json..."
curl -s -L -m 15 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

# 10. Cron для обновления
CRON_LINE="0 */3 * * * /root/update-xray.sh"
grep -qF "$CRON_LINE" /etc/crontabs/root || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# 11. Перезапуск сервисов
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray enable || true
/etc/init.d/xray restart

# 12. Финальная диагностика
echo
echo "=== АВТО-ДИАГНОСТИКА ==="
"$DIAG"
echo

echo "=== Установка завершена успешно ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"
echo
echo "Проверьте вывод диагностики выше."
echo "Если счётчики nftables не растут — перезагрузите роутер и запустите диагностику ещё раз."