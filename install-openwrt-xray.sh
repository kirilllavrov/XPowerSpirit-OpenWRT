#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)
# Финальная версия: DNS port 53 исключён, надёжный init-скрипт, нет гонок с fw4

echo "=== Установка Xray TProxy (финальная версия) ==="
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"
GEO_DIR="/usr/share/xray"

# 1. Подписка
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }
mkdir -p "$CONFIG_DIR"
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 2. Пакеты (минимальный рабочий набор) - уже установленно
#echo "[1] Установка пакетов..."
#apk update
#apk add curl xray-core ca-certificates python3 kmod-nft-tproxy

# 3. Скрипты
echo "[1] Загрузка скриптов..."
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
wget -q "$REPO/diagnose-xray-tproxy.sh" -O "$DIAG"; chmod +x "$DIAG"

# 4. dnsmasq → Xray:1053
echo "[2] Настройка DNS..."
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053'
uci commit dhcp

# 6. Создаём надёжный init-скрипт для правил nftables
echo "[3] Создание сервиса правил фаервола..."
cat > /etc/init.d/xray-tproxy-rules << 'INITEOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10

start() {
    # Очищаем старое
    nft delete table ip xray 2>/dev/null

    # Создаём таблицу и цепочку с собственным hook prerouting
    nft add table ip xray
    nft 'add chain ip xray xray_tproxy { type filter hook prerouting priority mangle; policy accept; }'

    # 1. Исключаем трафик самого Xray (mark 255 = 0xff)
    nft 'add rule ip xray xray_tproxy meta mark 0x000000ff return'
    # 2. ИСКЛЮЧАЕМ DNS и DHCP
    nft 'add rule ip xray xray_tproxy udp dport { 53, 67, 68 } return'
    nft 'add rule ip xray xray_tproxy tcp dport 53 return'
    # 3. Исключаем локальные/частные сети
    nft 'add rule ip xray xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return'
    # 4. Перехват TProxy
    nft 'add rule ip xray xray_tproxy meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:12345 meta mark set 0x00000001 accept'

    # Маршрутизация
    ip rule del fwmark 1 lookup xray 2>/dev/null || true
    ip rule add fwmark 1 lookup xray priority 100
    ip route flush table xray 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table xray
}

stop() {
    nft delete table ip xray 2>/dev/null
    ip rule del fwmark 1 lookup xray 2>/dev/null || true
    ip route flush table xray 2>/dev/null || true
}
INITEOF
chmod +x /etc/init.d/xray-tproxy-rules
/etc/init.d/xray-tproxy-rules enable

# 7. Policy routing
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables

# 8. sysctl
echo "[4] Настройка sysctl..."
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 9. Geo + config.json
echo "[5] Генерация конфигурации..."
mkdir -p "$GEO_DIR"
curl -fsSL https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat -o "$GEO_DIR/geoip.dat"
curl -fsSL https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat -o "$GEO_DIR/geosite.dat"

HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
echo "$HWID" > "$HWID_FILE"
chmod 600 "$HWID_FILE"

curl -s -L -m 20 -H "x-hwid: $HWID" "$SUB_URL" \
| python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

if [ ! -s "$CONFIG_JSON" ]; then
    echo "Ошибка: не удалось создать config.json"
    exit 1
fi

# 10. init.d Xray
echo "[6] Настройка автозапуска Xray..."
cat > /etc/init.d/xray << 'XRAYEOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/bin/xray
start_service() {
    procd_open_instance
    procd_set_param command "$PROG" run -config /etc/xray/config.json
    procd_set_param respawn
    procd_set_param user root
    procd_set_param stderr 1
    procd_set_param stdout 1
    procd_close_instance
}
XRAYEOF
chmod +x /etc/init.d/xray

# 11. Запуск служб в правильном порядке
echo "[7] Запуск служб..."
/etc/init.d/dnsmasq restart
/etc/init.d/xray-tproxy-rules start
/etc/init.d/firewall restart
/etc/init.d/xray restart

echo ""
echo "=== Установка завершена ==="
echo "Запуск диагностики через 5 секунд..."
sleep 5
/root/diagnose-xray-tproxy.sh

echo ""
echo "=== Диагностика завершена ==="
echo ""
