#!/bin/sh
# install-openwrt-xray-fixed.sh — финальная исправленная версия
# OpenWrt 25.12.x + fw4 + Xray TProxy (IPv4-only)

set -e

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

echo "=== Установка Xray TProxy (исправленная версия) ==="

[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# 1. Создаём директорию СРАЗУ
mkdir -p /etc/xray

# 2. Подписка
printf "Введите URL подписки VLESS: "
read -r SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL подписки"; exit 1; }

echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 3. Пакеты
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 4. Скачиваем скрипты
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR" && chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER" && chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER" && chmod +x "$UPDATER"
wget -q "$REPO/diagnose-xray-tproxy.sh" -O "$DIAG" && chmod +x "$DIAG"

# 5. dnsmasq
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 6. nftables TProxy (ruleset-post)
echo "Настройка nftables TProxy..."
mkdir -p /usr/share/nftables.d/ruleset-post

cat > /usr/share/nftables.d/ruleset-post/30-xray-tproxy.nft << 'EOF'
table ip xray {
    chain xray_tproxy {
        type filter hook prerouting priority mangle; policy accept;

        # Bypass правила — должны идти первыми
        iifname "br-lan" udp dport {67, 68} return
        ip daddr {127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16} return
        meta mark 0xff return

        # TProxy для LAN трафика
        iifname "br-lan" meta l4proto { tcp, udp } tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

# 7. Policy routing + hotplug (чтобы не слетало после перезагрузки)
grep -q "100 xray" /etc/iproute2/rt_tables 2>/dev/null || echo "100 xray" >> /etc/iproute2/rt_tables

cat > /etc/hotplug.d/iface/99-xray-routing << 'EOF'
#!/bin/sh
if [ "$ACTION" = ifup ] && [ "$INTERFACE" = lan ]; then
    ip rule del fwmark 1 lookup xray 2>/dev/null || true
    ip rule add fwmark 1 lookup xray priority 100
    ip route flush table xray 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table xray
fi
EOF
chmod +x /etc/hotplug.d/iface/99-xray-routing

# Применяем сейчас
ip rule del fwmark 1 lookup xray 2>/dev/null || true
ip rule add fwmark 1 lookup xray priority 100
ip route flush table xray 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table xray

# 8. sysctl
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.conf.all.route_localnet=1" /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 9. HWID + генерация конфига
if [ ! -f "$HWID_FILE" ]; then
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
else
    HWID="$(cat "$HWID_FILE")"
fi

echo "Генерация config.json..."
curl -s -L -m 20 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

# 10. Cron
mkdir -p /etc/crontabs
CRON_LINE="0 */3 * * * /root/update-xray.sh"
grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart || true

# 11. Перезапуск сервисов
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray stop 2>/dev/null || true
sleep 2
/etc/init.d/xray enable
/etc/init.d/xray restart

# 12. Диагностика
echo
echo "=== АВТО-ДИАГНОСТИКА ==="
"$DIAG"

echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"
echo
echo "Если порт 12345 всё ещё не слушается, выполни:"
echo "    /etc/init.d/xray restart && netstat -tulnp | grep 12345"