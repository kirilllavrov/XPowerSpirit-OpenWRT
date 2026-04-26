#!/bin/sh
# install-openwrt-xray.sh — финальная версия
# Полная установка Xray + TProxy + подписка + геофайлы + генератор
# OpenWrt 25.12.x (apk-based)

set -e

REPO_RAW="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

# Правильный путь для Xray
GEO_DIR="/usr/share/xray"
mkdir -p "$GEO_DIR"

GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo
echo "=== Установка Xray на OpenWrt 25.12.x (XPowerSpirit-OpenWRT) ==="
echo

# 1. root
if [ "$(id -u)" != "0" ]; then
    echo "Этот скрипт нужно запускать от root."
    exit 1
fi

# 2. подписка
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

# 3. пакеты
echo "[1/11] Устанавливаем пакеты..."
apk update
apk add curl xray-core nftables ca-certificates jq python3
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat kmod-nft-fib || true

# 4. geoip/geosite
echo "[2/11] Скачиваем geoip/geosite..."
curl -fsSL "$GEOIP_URL" -o "$GEOIP"
curl -fsSL "$GEOSITE_URL" -o "$GEOSITE"

# 5. генератор/парсер/обновлялка
echo "[3/11] Скачиваем генератор, парсер и обновлялку..."

wget -q "$REPO_RAW/xray-generate-config.py" -O "$GENERATOR"
chmod +x "$GENERATOR"

wget -q "$REPO_RAW/xray-sub-parser.py" -O "$PARSER"
chmod +x "$PARSER"

wget -q "$REPO_RAW/update-xray.sh" -O "$UPDATER"
chmod +x "$UPDATER"

# 6. dnsmasq → Xray
echo "[4/11] Настраиваем DNS → Xray..."
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 7. nftables TProxy
echo "[5/11] Создаём nft‑правила TProxy..."
mkdir -p /etc/nftables.d

cat > /etc/nftables.d/30-xray-tproxy.nft << 'EOF'
table inet fw4 {
    chain xray_tproxy_prerouting {
        type filter hook prerouting priority mangle; policy accept;

        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
        ip daddr { 1.1.1.1, 77.88.8.8 } return

        meta l4proto { tcp, udp } meta mark set 1
        tcp dport != 53 tproxy to :12345
        udp dport != 53 tproxy to :12345
    }

    chain xray_tproxy_output {
        type route hook output priority mangle; policy accept;
    }
}
EOF

# гарантируем include
grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null || \
    echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf

# 8. таблица маршрутизации
echo "[6/11] Добавляем таблицу маршрутизации xray..."

grep -q "100 xray" /etc/iproute2/rt_tables 2>/dev/null || echo "100 xray" >> /etc/iproute2/rt_tables

ip rule | grep -q "fwmark 0x1 lookup xray" || ip rule add fwmark 1 lookup xray
ip route show table xray | grep -q "local 0.0.0.0/0" || ip route add local 0.0.0.0/0 dev lo table xray

# 9. HWID
echo "[7/11] Генерируем HWID..."

if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

echo "HWID: $HWID"

# 10. config.json
echo "[8/11] Генерируем config.json через парсер и генератор..."

curl -s -L -m 15 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" | python3 "$PARSER" | python3 "$GENERATOR" \
    --output "$CONFIG_JSON"

# 11. cron
echo "[9/11] Настраиваем cron для автообновления..."

CRON_LINE="0 */3 * * * /root/update-xray.sh"

grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root

/etc/init.d/cron restart

# 12. перезапуск
echo "[10/11] Перезапуск dnsmasq, firewall, Xray..."
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/nftables restart 2>/dev/null || true
/etc/init.d/xray restart

# 13. диагностика
echo
echo "[11/11] Проверяем работу Xray и TProxy..."

if pgrep -x "xray" >/dev/null; then
    echo "[OK] Xray запущен"
else
    echo "[ERR] Xray НЕ запущен!"
fi

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "[OK] Конфиг Xray валиден"
else
    echo "[ERR] Конфиг Xray содержит ошибки!"
    echo "Проверь что не так:"
    echo "xray run -test -config $CONFIG_JSON"
fi

if nft list chain inet fw4 xray_tproxy_prerouting >/dev/null 2>&1; then
    echo "[OK] nftables: цепочка xray_tproxy_prerouting загружена"
else
    echo "[ERR] nftables: цепочка xray_tproxy_prerouting отсутствует!"
fi

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

echo
echo "=== Установка завершена ==="
echo "HWID:    $HWID"
echo "Подписка: $SUB_FILE"
echo "Config:   $CONFIG_JSON"
echo "Cron:     каждые 3 часа"
echo
