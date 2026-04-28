#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

echo "=== Установка Xray TProxy (финальная версия) ==="
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
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

# 2. Установка Xray из GitHub
echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

TMP_DIR="/tmp/xray_install"
mkdir -p "$TMP_DIR"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"

curl -L -o "$TMP_DIR/xray.zip" "$ZIP_URL"
unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR"

# Устанавливаем основной бинарник
cp "$TMP_DIR/xray" /usr/bin/xray
chmod 755 /usr/bin/xray

rm -rf "$TMP_DIR"
echo "✓ Xray установлен (версия $LATEST_VERSION)"

# 3. Скрипты
echo "[1] Загрузка скриптов..."
mkdir -p "$GEO_DIR"
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
echo "✓ Скрипты загружены"

# 4. Настройка dnsmasq
echo "[2] Настройка DNS (dnsmasq → DoH)..."

apk update
apk add https-dns-proxy

uci set https-dns-proxy.@https-dns-proxy[0].resolver_url='https://cloudflare-dns.com/dns-query'
uci set https-dns-proxy.@https-dns-proxy[0].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[0].listen_port='5053'

uci add https-dns-proxy https-dns-proxy
uci set https-dns-proxy.@https-dns-proxy[-1].resolver_url='https://dns.google/dns-query'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[-1].listen_port='5054'
uci commit https-dns-proxy

uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci commit dhcp

echo "✓ dnsmasq настроен на DoH"

# 6. Создаём init-скрипт для правил nftables
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
echo "✓ nftables настроили"

# 7. Policy routing
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables
echo "✓ routing настроили"

# 8. sysctl
echo "[4] Настройка sysctl..."
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "✓ sysctl настроили"

# 9. Geo + HWID + config.json
echo "[5] Генерация конфигурации..."
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
echo "✓ Geo + HWID + config.json настроили"

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
echo "✓ init.d Xray настроили"

# 11. Cron: автообновление в 2.30 ночи
echo "[7] Настройка автообновления (cron)..."
CRON_ENTRY="30 2 * * * $UPDATER"
# Проверяем, нет ли уже такой задачи (чтобы не дублировать)
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "  → ✓ Добавлено в crontab: $CRON_ENTRY"
else
    echo "  → Cron-задача уже существует, пропускаем"
fi

# 12. Запуск служб в правильном порядке
echo "[8] Запуск служб..."
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray-tproxy-rules start
/etc/init.d/xray start
echo "✓ Перезапустили службы"

sleep 3

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "[OK] Конфиг Xray валиден"
else
    echo "[ERR] Конфиг НЕ валиден, откат!" >> "$LOG"
    exit 1
fi

echo "Проверяем Xray process:"
if pgrep -a xray >/dev/null; then
    echo "✓ Xray запущен"
else
    echo "✗ Xray НЕ запущен"
fi

echo ""
echo "=== Установка завершена ==="
