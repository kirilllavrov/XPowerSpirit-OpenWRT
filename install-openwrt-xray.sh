#!/bin/sh
# install-openwrt-xray-fixed.sh — финальная исправленная версия (март 2026)
# OpenWrt 25.12.x + fw4 + Xray TProxy IPv4-only

set -e

echo "=== Установка Xray TProxy (финальная исправленная версия) ==="

[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# 1. Создаём директорию сразу
mkdir -p /etc/xray

# 2. Подписка
printf "Введите URL подписки VLESS: "
read -r SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL подписки"; exit 1; }

echo "$SUB_URL" > /etc/xray/subscription.url
chmod 600 /etc/xray/subscription.url

# 3. Установка пакетов
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 4. Скачиваем необходимые скрипты
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
wget -q "$REPO/xray-generate-config.py" -O /root/xray-generate-config.py && chmod +x /root/xray-generate-config.py
wget -q "$REPO/xray-sub-parser.py"     -O /root/xray-sub-parser.py     && chmod +x /root/xray-sub-parser.py
wget -q "$REPO/update-xray.sh"         -O /root/update-xray.sh         && chmod +x /root/update-xray.sh
wget -q "$REPO/diagnose-xray-tproxy.sh"-O /root/diagnose-xray-tproxy.sh && chmod +x /root/diagnose-xray-tproxy.sh

# 5. Настройка dnsmasq
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 6. nftables TProxy (правильный способ через ruleset-post)
echo "Настройка nftables TProxy..."
mkdir -p /usr/share/nftables.d/ruleset-post

cat > /usr/share/nftables.d/ruleset-post/30-xray-tproxy.nft << 'EOF'
table ip xray {
    chain xray_tproxy {
        type filter hook prerouting priority mangle; policy accept;

        # Bypass правила (обязательно первыми!)
        iifname "br-lan" udp dport {67, 68} return
        ip daddr {127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16} return
        meta mark 0xff return

        # TProxy для всего остального трафика с LAN
        iifname "br-lan" meta l4proto { tcp, udp } tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

# 7. Policy routing + hotplug (чтобы правила не слетали после перезагрузки)
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

# Применяем правила сейчас
ip rule del fwmark 1 lookup xray 2>/dev/null || true
ip rule add fwmark 1 lookup xray priority 100
ip route flush table xray 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table xray

# 8. sysctl
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q "net.ipv4.conf.all.route_localnet=1" /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 9. HWID + генерация config.json
if [ ! -f /etc/xray/hwid ]; then
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > /etc/xray/hwid
    chmod 600 /etc/xray/hwid
else
    HWID="$(cat /etc/xray/hwid)"
fi

echo "Генерация config.json..."
curl -s -L -m 20 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 /root/xray-sub-parser.py \
    | python3 /root/xray-generate-config.py --output /etc/xray/config.json

# 10. Cron для автообновления
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
/root/diagnose-xray-tproxy.sh

echo
echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: /etc/xray/config.json"
echo
echo "Проверьте порт 12345 командой:"
echo "    netstat -tulnp | grep 12345"
echo "Если порт не слушается — выполните:"
echo "    /etc/init.d/xray restart && netstat -tulnp | grep 12345"