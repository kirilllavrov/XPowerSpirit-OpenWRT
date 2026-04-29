#!/bin/sh
# OpenWrt — Xray TProxy installer (исправленная финальная версия)

set -e

echo "=== Установка Xray TProxy ==="

# ---------------------------------------------------------
# Проверка root
# ---------------------------------------------------------
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# ---------------------------------------------------------
# Пути
# ---------------------------------------------------------
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"

STATE_DIR="/etc/xray/state"
GEO_DIR="/usr/share/xray"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$GEO_DIR"

# ---------------------------------------------------------
# Ввод подписки
# ---------------------------------------------------------
printf "Введите URL подписки VLESS: "
read SUB_URL

# Удаляем \r, BOM, пробелы в конце
SUB_URL="$(printf "%s" "$SUB_URL" | tr -d '\r' | sed 's/[[:space:]]*$//')"

if [ -z "$SUB_URL" ]; then
    echo "❌ Ошибка: URL подписки пустой"
    exit 1
fi

case "$SUB_URL" in
    http://*|https://*) ;;
    *) echo "❌ Некорректный URL подписки"; exit 1 ;;
esac

echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# ---------------------------------------------------------
# SHA‑парсер
# ---------------------------------------------------------
extract_sha256() {
    grep '^SHA2-256' "$1" \
        | sed 's/.*= *//' \
        | tr -cd '0-9a-fA-F' \
        | cut -c1-64
}

# ---------------------------------------------------------
# Установка Xray
# ---------------------------------------------------------
echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | sed -n 's/.*"tag_name": "\(.*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && { echo "❌ Не удалось получить версию Xray"; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

TMP_DIR="/tmp/xray_install"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"
SHA_FILE="$STATE_DIR/xray.zip.sha256sum"

# .dgst скачиваем БЕЗ -f
curl -s -L --url "${ZIP_URL}.dgst" --output "$STATE_DIR/xray.dgst"

REMOTE_SHA=$(extract_sha256 "$STATE_DIR/xray.dgst")

if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
    echo "✓ Xray ZIP уже скачан — пропускаем"
else
    echo "→ Скачиваем Xray ZIP (${LATEST_VERSION})..."
    curl -f -L --url "$ZIP_URL" --output "$ZIP_DEST"

    LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "❌ Ошибка SHA: ожидалось $REMOTE_SHA, получено $LOCAL_SHA"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"

    unzip -q "$ZIP_DEST" -d "$TMP_DIR"
    cp "$TMP_DIR/xray" /usr/bin/xray
    chmod 755 /usr/bin/xray
fi

echo "✓ Xray успешно установлен (${LATEST_VERSION})"

# ---------------------------------------------------------
# Скрипты
# ---------------------------------------------------------
echo "[1] Загрузка скриптов..."

curl -s -L --url "$REPO/xray-generate-config.py" --output "$GENERATOR"
curl -s -L --url "$REPO/xray-sub-parser.py" --output "$PARSER"
curl -s -L --url "$REPO/update-xray.sh" --output "$UPDATER"

chmod +x "$GENERATOR" "$PARSER" "$UPDATER"

echo "✓ Скрипты загружены"

# ---------------------------------------------------------
# DNS → DoH
# ---------------------------------------------------------
echo "[2] Настройка DNS..."

DNSMASQ_SECTION="$(uci show dhcp | grep '=dnsmasq' | head -n1 | cut -d. -f2 | cut -d= -f1)"

uci set dhcp.$DNSMASQ_SECTION.noresolv='1'
uci -q delete dhcp.$DNSMASQ_SECTION.server
uci add_list dhcp.$DNSMASQ_SECTION.server='127.0.0.1#5053'
uci add_list dhcp.$DNSMASQ_SECTION.server='127.0.0.1#5054'
uci commit dhcp

echo "✓ dnsmasq настроен"

# ---------------------------------------------------------
# nftables
# ---------------------------------------------------------
echo "[3] Настройка nftables..."

cat > /etc/init.d/xray-tproxy-rules << 'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10

start() {
    nft delete table ip xray 2>/dev/null
    nft add table ip xray
    nft 'add chain ip xray xray_tproxy { type filter hook prerouting priority mangle; policy accept; }'
    nft 'add rule ip xray xray_tproxy meta mark 0xff return'
    nft 'add rule ip xray xray_tproxy udp dport {53,67,68} return'
    nft 'add rule ip xray xray_tproxy tcp dport 53 return'
    nft 'add rule ip xray xray_tproxy ip daddr {127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16} return'
    nft 'add rule ip xray xray_tproxy meta l4proto {tcp,udp} tproxy ip to 127.0.0.1:12345 meta mark set 1 accept'

    ip rule add fwmark 1 lookup xray priority 100 2>/dev/null || true
    ip route add local 0.0.0.0/0 dev lo table xray 2>/dev/null || true
}

stop() {
    nft delete table ip xray 2>/dev/null
    ip rule del fwmark 1 lookup xray 2>/dev/null || true
    ip route flush table xray 2>/dev/null || true
}
EOF

chmod +x /etc/init.d/xray-tproxy-rules
/etc/init.d/xray-tproxy-rules enable

echo "✓ nftables настроены"

# ---------------------------------------------------------
# sysctl
# ---------------------------------------------------------
echo "[4] Настройка sysctl..."

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

echo "✓ sysctl настроены"

# ---------------------------------------------------------
# HWID
# ---------------------------------------------------------
if [ ! -s "$HWID_FILE" ]; then
    hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

HWID="$(cat "$HWID_FILE")"

# ---------------------------------------------------------
# geoip/geosite
# ---------------------------------------------------------
echo "[5] Загрузка geodata..."

curl -s -L --url "https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat" --output "$GEO_DIR/geoip.dat"
curl -s -L --url "https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat" --output "$GEO_DIR/geosite.dat"

# ---------------------------------------------------------
# Генерация config.json
# ---------------------------------------------------------
echo "[6] Генерация config.json..."

SUB_RAW="/tmp/xray-sub.raw"
rm -f "$SUB_RAW"

curl \
    -s -L \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    --url "$SUB_URL" \
    --output "$SUB_RAW"

grep -q "vless://" "$SUB_RAW" || { echo "❌ Подписка не содержит vless://"; exit 1; }

TMP_CONFIG="/tmp/xray-config.json"

cat "$SUB_RAW" \
    | python3 "$PARSER" \
    | python3 "$GENERATOR" --output "$TMP_CONFIG"

xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1 \
    || { echo "❌ Новый config.json невалиден"; exit 1; }

mv "$TMP_CONFIG" "$CONFIG_JSON"

echo "✓ config.json создан"

# ---------------------------------------------------------
# init.d Xray
# ---------------------------------------------------------
echo "[7] Настройка автозапуска..."

cat > /etc/init.d/xray << 'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/bin/xray
start_service() {
    procd_open_instance
    procd_set_param command "$PROG" run -config /etc/xray/config.json
    procd_set_param respawn
    procd_close_instance
}
EOF

chmod +x /etc/init.d/xray

# ---------------------------------------------------------
# Hotplug автообновление
# ---------------------------------------------------------
echo "[8] Настройка автообновления..."

cat > /etc/hotplug.d/iface/99-xray-autoupdate << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0
if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
    /usr/share/xray/update-xray.sh &
fi
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate

# ---------------------------------------------------------
# Запуск
# ---------------------------------------------------------
echo "[9] Запуск служб..."

etc/init.d/xray-tproxy-rules start
/etc/init.d/xray start

echo "=== Установка завершена ==="
