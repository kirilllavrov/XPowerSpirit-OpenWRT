#!/bin/sh
# OpenWrt 25.12.x — fw4-compatible TProxy (IPv4-only) — исправленная версия

echo "=== Установка Xray TProxy (исправлено) ==="

[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# 1. Подписка
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }

mkdir -p /etc/xray
echo "$SUB_URL" > /etc/xray/subscription.url
chmod 600 /etc/xray/subscription.url

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"
CONFIG_JSON="/etc/xray/config.json"
HWID_FILE="/etc/xray/hwid"
GEO_DIR="/usr/share/xray"

# 2. Пакеты
echo "[2] Устанавливаем пакеты..."
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 3. Скрипты
echo "[3] Загружаем скрипты..."
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR" && chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER" && chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER" && chmod +x "$UPDATER"
wget -q "$REPO/diagnose-xray-tproxy.sh" -O "$DIAG" && chmod +x "$DIAG"

# 4. dnsmasq
echo "[4] Настраиваем dnsmasq..."
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 5. nftables (ruleset-post)
echo "[5] Настройка nftables TProxy..."
mkdir -p /usr/share/nftables.d/ruleset-post

cat > /usr/share/nftables.d/ruleset-post/30-xray-tproxy.nft << 'EOF'
table ip xray {
    chain xray_tproxy {
        type filter hook prerouting priority mangle; policy accept;

        iifname "br-lan" udp dport {67, 68} return
        ip daddr {127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16} return
        meta mark 0xff return

        iifname "br-lan" meta l4proto { tcp, udp } tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

# 6. Policy routing + hotplug
echo "[6] Настройка policy routing..."
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

ip rule del fwmark 1 lookup xray 2>/dev/null || true
ip rule add fwmark 1 lookup xray priority 100
ip route flush table xray 2>/dev/null || true
ip route add local 0.0.0.0/0 dev lo table xray

# 7. sysctl
echo "[7] Настройка sysctl..."
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 8. Geo файлы + HWID + config
echo "[8] Geo файлы + генерация config.json..."
mkdir -p "$GEO_DIR"

curl -fsSL https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat -o "$GEO_DIR/geoip.dat"
curl -fsSL https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat -o "$GEO_DIR/geosite.dat"

if [ ! -f "$HWID_FILE" ]; then
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
else
    HWID="$(cat "$HWID_FILE")"
fi

echo "HWID: $HWID"

curl -s -L -m 20 -H "User-Agent: Happ" -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

# 9. Cron + сервисы
echo "[9] Cron + перезапуск сервисов..."
mkdir -p /etc/crontabs
CRON_LINE="0 */3 * * * /root/update-xray.sh"
grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart || true

/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray stop 2>/dev/null || true
sleep 2
/etc/init.d/xray enable
/etc/init.d/xray restart

# 10. Диагностика
echo
echo "=== АВТО-ДИАГНОСТИКА ==="
"$DIAG"
echo

echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"