#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy installer

set -e

echo "=== Установка Xray TProxy (финальная версия) ==="

# ---------------------------------------------------------
# Проверка root
# ---------------------------------------------------------
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# ---------------------------------------------------------
# Проверка зависимостей
# ---------------------------------------------------------
need_bin() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Ошибка: требуется $1"
        exit 1
    }
}

need_bin curl
need_bin wget
need_bin unzip
need_bin python3

# ---------------------------------------------------------
# Пути
# ---------------------------------------------------------
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"

GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"

mkdir -p "$CONFIG_DIR" "$GEO_DIR" "$STATE_DIR"

# ---------------------------------------------------------
# 1. Подписка
# ---------------------------------------------------------
printf "Введите URL подписки VLESS: "
read SUB_URL
SUB_URL="$(echo "$SUB_URL" | tr -d ' \t\r')"

[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }

echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# ---------------------------------------------------------
# 2. Установка Xray
# ---------------------------------------------------------
echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -H "Cache-Control: no-cache" -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

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

curl -H "Cache-Control: no-cache" -s -L -o "$STATE_DIR/xray.dgst" "${ZIP_URL}.dgst"

REMOTE_SHA=$(grep -E 'SHA2-256|SHA256' "$STATE_DIR/xray.dgst" \
    | head -n1 \
    | sed 's/.*= *//' \
    | tr -d '[:space:]')

if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
    echo "✓ Xray ZIP уже скачан — пропускаем"
else
    echo "→ Скачиваем Xray ZIP..."
    curl -H "Cache-Control: no-cache" -L -o "$ZIP_DEST" "$ZIP_URL"

    LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
    [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "Ошибка SHA Xray ZIP"; exit 1; }

    echo "$REMOTE_SHA" > "$SHA_FILE"
fi

unzip -q "$ZIP_DEST" -d "$TMP_DIR"
cp "$TMP_DIR/xray" /usr/bin/xray
chmod 755 /usr/bin/xray

echo "✓ Xray установлен ($LATEST_VERSION)"

# ---------------------------------------------------------
# 3. Скрипты
# ---------------------------------------------------------
echo "[1] Загрузка скриптов..."

wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"

echo "✓ Скрипты загружены"

# ---------------------------------------------------------
# 4. Настройка DoH (https-dns-proxy уже установлен)
# ---------------------------------------------------------
echo "[2] Настройка DNS (dnsmasq → DoH)..."

mkdir -p /usr/share/nftables.d/ruleset-post

# Первый инстанс (Cloudflare)
if [ -z "$(uci -q get https-dns-proxy.@https-dns-proxy[0].resolver_url)" ]; then
    uci add https-dns-proxy https-dns-proxy >/dev/null
fi
uci set https-dns-proxy.@https-dns-proxy[0].resolver_url='https://cloudflare-dns.com/dns-query'
uci set https-dns-proxy.@https-dns-proxy[0].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[0].listen_port='5053'

# Второй инстанс (Google)
if [ -z "$(uci -q get https-dns-proxy.@https-dns-proxy[1].resolver_url)" ]; then
    uci add https-dns-proxy https-dns-proxy >/dev/null
fi
uci set https-dns-proxy.@https-dns-proxy[1].resolver_url='https://dns.google/dns-query'
uci set https-dns-proxy.@https-dns-proxy[1].listen_addr='127.0.0.1'
uci set https-dns-proxy.@https-dns-proxy[1].listen_port='5054'

uci commit https-dns-proxy

# dnsmasq
DNSMASQ_SECTION="$(uci show dhcp | grep '=dnsmasq' | head -n1 | cut -d. -f2 | cut -d= -f1)"

uci set dhcp.$DNSMASQ_SECTION.noresolv='1'
uci -q delete dhcp.$DNSMASQ_SECTION.server
uci add_list dhcp.$DNSMASQ_SECTION.server='127.0.0.1#5053'
uci add_list dhcp.$DNSMASQ_SECTION.server='127.0.0.1#5054'
uci commit dhcp

echo "✓ dnsmasq настроен на DoH"

# ---------------------------------------------------------
# 5. nftables TProxy
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
EOF

chmod +x /etc/init.d/xray-tproxy-rules
/etc/init.d/xray-tproxy-rules enable

grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables

echo "✓ nftables настроены"

# ---------------------------------------------------------
# 6. sysctl
# ---------------------------------------------------------
echo "[4] Настройка sysctl..."

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

echo "✓ sysctl настроены"

# ---------------------------------------------------------
# 7. HWID + geo + config.json
# ---------------------------------------------------------
echo "[5] Генерация конфигурации..."

# HWID
if [ ! -f "$HWID_FILE" ]; then
    hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi
HWID="$(cat "$HWID_FILE")"

# geoip/geosite (первичная загрузка)
curl -fsSL "$GEOIP_URL" -o "$GEOIP"
curl -fsSL "$GEOSITE_URL" -o "$GEOSITE"

TMP_CONFIG="/tmp/xray-config.json"

# подписка
SUB_RAW="/tmp/xray-sub.raw"
curl -s -L -m 20 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" > "$SUB_RAW"

grep -q "vless://" "$SUB_RAW" || { echo "Ошибка: подписка не содержит vless://"; exit 1; }

cat "$SUB_RAW" \
    | python3 "$PARSER" \
    | python3 "$GENERATOR" --output "$TMP_CONFIG"

[ -s "$TMP_CONFIG" ] || { echo "Ошибка: пустой config.json"; exit 1; }

xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1 \
    || { echo "Ошибка: config.json невалиден"; exit 1; }

mv "$TMP_CONFIG" "$CONFIG_JSON"
echo "✓ config.json создан"

# ---------------------------------------------------------
# 8. init.d Xray
# ---------------------------------------------------------
echo "[6] Настройка автозапуска Xray..."

cat > /etc/init.d/xray << 'EOF'
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
EOF

chmod +x /etc/init.d/xray

echo "✓ init.d Xray настроен"

# ---------------------------------------------------------
# 9. Cron
# ---------------------------------------------------------
echo "[7] Настройка автообновления..."

CRON_FILE="/etc/crontabs/root"
CRON_ENTRY="30 2 * * * $UPDATER"

touch "$CRON_FILE"
grep -qF "$UPDATER" "$CRON_FILE" || {
    echo "$CRON_ENTRY" >> "$CRON_FILE"
    /etc/init.d/cron restart
    echo "  → ✓ Добавлено в crontab"
}

# ---------------------------------------------------------
# 10. Запуск служб
# ---------------------------------------------------------
echo "[8] Запуск служб..."

# один раз — в правильном порядке
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray-tproxy-rules start
/etc/init.d/xray start

sleep 2

xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1 \
    && echo "[OK] Конфиг Xray валиден" \
    || echo "[ERR] Конфиг НЕ валиден"

pgrep -a xray >/dev/null \
    && echo "✓ Xray запущен" \
    || echo "✗ Xray НЕ запущен"

echo ""
echo "=== Установка завершена ==="
