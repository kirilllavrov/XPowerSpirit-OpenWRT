#!/bin/sh
# install-openwrt-xray.sh
# Полная установка Xray + nftables TProxy + подписка + геофайлы + генератор
# OpenWrt 25.12.x (apk-based)

set -e

REPO_RAW="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo
echo "=== Установка Xray на OpenWrt 25.12.x (XPowerSpirit-OpenWRT) ==="
echo

# -----------------------------
# 1. Проверка root
# -----------------------------
if [ "$(id -u)" != "0" ]; then
    echo "Этот скрипт нужно запускать от root."
    exit 1
fi

# -----------------------------
# 2. Запрос подписки
# -----------------------------
printf "Введите URL подписки VLESS: "
read SUB_URL

if [ -z "$SUB_URL" ]; then
    echo "Ошибка: URL подписки пустой."
    exit 1
fi

mkdir -p /etc/xray
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

echo "[OK] Подписка сохранена в $SUB_FILE"

# -----------------------------
# 3. Установка пакетов
# -----------------------------
echo "[1/11] Устанавливаем пакеты..."
apk update
apk add curl xray-core nftables ca-certificates jq python3
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat kmod-nft-fib || true

# -----------------------------
# 4. Установка геофайлов
# -----------------------------
echo "[2/11] Скачиваем geoip/geosite..."
curl -fsSL "$GEOIP_URL" -o /etc/xray/geoip.dat
curl -fsSL "$GEOSITE_URL" -o /etc/xray/geosite.dat

# -----------------------------
# 5. Скачивание генератора, парсера и обновлялки
# -----------------------------
echo "[3/11] Скачиваем генератор, парсер и обновлялку..."

wget -q "$REPO_RAW/xray-generate-config.py" -O "$GENERATOR"
chmod +x "$GENERATOR"

wget -q "$REPO_RAW/xray-sub-parser.py" -O "$PARSER"
chmod +x "$PARSER"

wget -q "$REPO_RAW/update-xray.sh" -O "$UPDATER"
chmod +x "$UPDATER"

# -----------------------------
# 6. Настройка dnsmasq → Xray
# -----------------------------
echo "[4/11] Настраиваем DNS → Xray..."
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# -----------------------------
# 7. nftables TProxy
# -----------------------------
echo "[5/11] Создаём nft‑правила TProxy..."
mkdir -p /etc/nftables.d

cat > /etc/nftables.d/30-xray-tproxy.nft << 'EOF'
chain xray_tproxy_prerouting {
    type filter hook prerouting priority mangle; policy accept;

    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
    ip daddr { 1.1.1.1, 77.88.8.8 } return

    meta mark set 1

    tcp dport != 53 tproxy to :12345 meta mark set 1
    udp dport != 53 tproxy to :12345 meta mark set 1
}

chain xray_tproxy_output {
    type route hook output priority mangle; policy accept;
}
EOF

# -----------------------------
# 8. Таблица маршрутизации
# -----------------------------
echo "[6/11] Добавляем таблицу маршрутизации xray..."

grep -q "100 xray" /etc/iproute2/rt_tables 2>/dev/null || echo "100 xray" >> /etc/iproute2/rt_tables

if [ ! -f /etc/rc.local ]; then
    printf "#!/bin/sh\nexit 0\n" > /etc/rc.local
    chmod +x /etc/rc.local
fi

sed -i '/fwmark 1 lookup xray/d' /etc/rc.local
sed -i '/0.0.0.0\/0 dev lo table xray/d' /etc/rc.local

sed -i '/^exit 0/i ip rule add fwmark 1 lookup xray\nip route add local 0.0.0.0/0 dev lo table xray\n' /etc/rc.local

# -----------------------------
# 9. HWID (persistent)
# -----------------------------
echo "[7/11] Генерируем HWID..."

if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

echo "HWID: $HWID"

# -----------------------------
# 10. Генерация config.json
# -----------------------------
echo "[8/11] Генерируем config.json через парсер и генератор..."

curl -s -L -m 15 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" | python3 "$PARSER" | python3 "$GENERATOR" \
    --geoip /etc/xray/geoip.dat \
    --geosite /etc/xray/geosite.dat \
    --output "$CONFIG_JSON"

# -----------------------------
# 11. Cron
# -----------------------------
echo "[9/11] Настраиваем cron для автообновления..."

CRON_LINE="0 */3 * * * /root/update-xray.sh"

grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root

/etc/init.d/cron restart

# -----------------------------
# 12. Перезапуск сервисов
# -----------------------------
echo "[10/11] Перезапуск dnsmasq, firewall, Xray..."
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray restart

echo
echo "[11/11] Проверяем работу Xray и TProxy..."

# -----------------------------
# Проверка 1: процесс Xray
# -----------------------------
if pgrep -x "xray" >/dev/null; then
    echo "[OK] Xray запущен"
else
    echo "[ERR] Xray НЕ запущен!"
fi

# -----------------------------
# Проверка 2: валидность конфига
# -----------------------------
if xray run -test -config /etc/xray/config.json >/dev/null 2>&1; then
    echo "[OK] Конфиг Xray валиден"
else
    echo "[ERR] Конфиг Xray содержит ошибки!"
fi

# -----------------------------
# Проверка 3: nftables цепочки
# -----------------------------
if nft list chain inet fw4 xray_tproxy_prerouting >/dev/null 2>&1; then
    echo "[OK] nftables: цепочка xray_tproxy_prerouting загружена"
else
    echo "[ERR] nftables: цепочка xray_tproxy_prerouting отсутствует!"
fi

# -----------------------------
# Проверка 4: policy routing
# -----------------------------
if ip rule | grep -q "fwmark 0x1 lookup xray"; then
    echo "[OK] Policy routing: правило fwmark → xray активно"
else
    echo "[ERR] Policy routing: нет правила fwmark 1 lookup xray!"
fi

if ip route show table xray | grep -q "local 0.0.0.0/0 dev lo"; then
    echo "[OK] Таблица маршрутизации xray корректна"
else
    echo "[ERR] Таблица маршрутизации xray отсутствует!"
fi

# -----------------------------
# Проверка 5: DNS перехват
# -----------------------------
DNS_XRAY=$(netstat -tulpn 2>/dev/null | grep ":53 " | grep xray)
DNS_DNSMASQ=$(netstat -tulpn 2>/dev/null | grep ":53 " | grep dnsmasq)

if [ -n "$DNS_XRAY" ] && [ -n "$DNS_DNSMASQ" ]; then
    echo "[OK] DNS: dnsmasq → Xray работает"
else
    echo "[ERR] DNS: нет слушателя 53/udp у Xray или dnsmasq!"
fi

# -----------------------------
# Проверка 6: тестовый запрос через Xray
# -----------------------------
TEST_IP=$(curl -4 -s --max-time 5 https://ifconfig.me || echo "timeout")

if [ "$TEST_IP" != "timeout" ]; then
    echo "[OK] Трафик через Xray работает. Внешний IP: $TEST_IP"
else
    echo "[ERR] Не удалось выполнить запрос через Xray"
fi

echo
echo "=== Диагностика завершена ==="
echo


echo
echo "=== Установка завершена ==="
echo "HWID:    $HWID"
echo "Подписка: $SUB_FILE"
echo "Config:   $CONFIG_JSON"
echo "Cron:     каждые 3 часа"
echo
