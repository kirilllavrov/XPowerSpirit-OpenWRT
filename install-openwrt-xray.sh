#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

# === ЛОГИРОВАНИЕ УСТАНОВКИ ===
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy (финальная версия) ==="
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/share/xray"

# 1. Подписка
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }
mkdir -p "$CONFIG_DIR"
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 2. Установка Xray из GitHub (с .dgst + SHA2-256)
echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

[ -z "$LATEST_VERSION" ] && { echo "Ошибка: не удалось получить версию Xray"; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

mkdir -p "$TMP_DIR" "$GEO_DIR" "$CONFIG_DIR" /etc/xray/state
STATE_DIR="/etc/xray/state"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"
SHA_FILE="$STATE_DIR/xray.zip.sha256sum"
DGST_FILE="$STATE_DIR/xray.dgst"

# аккуратный парсер SHA2-256 из .dgst
extract_sha256() {
    grep '^SHA2-256' "$1" \
        | sed 's/.*= *//' \
        | tr -cd '0-9a-fA-F' \
        | cut -c1-64
}

echo "  → Скачиваем .dgst для Xray..."
curl -s -L "${ZIP_URL}.dgst" -o "$DGST_FILE" || {
    echo "Ошибка: не удалось скачать .dgst для Xray"
    exit 1
}

REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
[ -z "$REMOTE_SHA" ] && { echo "Ошибка: не удалось извлечь SHA2-256 из .dgst"; exit 1; }

# === ПРОВЕРКА СВОБОДНОГО МЕСТА ===
FREE_SPACE=$(df / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE" -lt 20480 ]; then
    echo "Ошибка: недостаточно места (нужно минимум 20MB)"
    exit 1
fi

# если уже есть ZIP с таким же SHA — не качаем заново
if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$ZIP_DEST" ]; then
    echo "  → Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
else
    echo "  → Скачиваем Xray ZIP (${LATEST_VERSION})..."
    curl -f -L "$ZIP_URL" -o "$ZIP_DEST" || {
        echo "Ошибка: не удалось скачать Xray ZIP"
        exit 1
    }

    LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "Ошибка: SHA не совпадает!"
        echo "  ожидалось: $REMOTE_SHA"
        echo "  получено : $LOCAL_SHA"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"
fi

unzip -q "$ZIP_DEST" -d "$TMP_DIR"

# Устанавливаем основной бинарник
cp "$TMP_DIR/xray" /usr/bin/xray
chmod 755 /usr/bin/xray

rm -rf "$TMP_DIR"
echo "✓ Xray установлен (версия $LATEST_VERSION, SHA проверен)"

# 3. Скрипты
echo "[1] Загрузка скриптов..."
mkdir -p "$GEO_DIR"
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
echo "✓ Скрипты загружены"

# 4. Настройка dnsmasq и DoH
echo "[2] Настройка DNS (dnsmasq → DoH)..."

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

# 5. Удаляем старый сервис правил
echo "[3] Удаляем старый сервис xray-tproxy-rules..."
/etc/init.d/xray-tproxy-rules stop 2>/dev/null
/etc/init.d/xray-tproxy-rules disable 2>/dev/null
rm -f /etc/init.d/xray-tproxy-rules
echo "✓ Старый сервис удалён"

# 6. Создаём единый init‑скрипт Xray
echo "[4] Создаём единый init.d Xray..."

cat > /etc/init.d/xray << 'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

# === АВТООПРЕДЕЛЕНИЕ LAN ИНТЕРФЕЙСА ===
LAN_IF="br-lan"
if ! ip link show br-lan >/dev/null 2>&1; then
    LAN_IF="$(uci show network | grep "=interface" | grep -v 'wan\|loopback' | head -1 | cut -d. -f2)"
    [ -z "$LAN_IF" ] && LAN_IF="br-lan"
    logger -t xray "LAN интерфейс auto-detected: $LAN_IF"
fi

extract_server_ips() {
    grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null \
        | sed 's/.*"\([^"]*\)"$/\1/' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -u
}

setup_network() {
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    local bypass_ips
    bypass_ips=$(extract_server_ips | tr '\n' ',' | sed 's/,$//')

    nft delete table inet xray 2>/dev/null

    local nft_file="/tmp/xray.nft"
    cat > "$nft_file" << NFT
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        } return;

        meta mark 0xff return;
NFT

    [ -n "$bypass_ips" ] && \
        echo "        ip daddr { $bypass_ips } return;" >> "$nft_file"

    cat >> "$nft_file" << NFT
        udp dport { 67, 68 } return;

        iifname "$LAN_IF" meta l4proto { tcp, udp } \
            tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFT

    nft -f "$nft_file" || {
        logger -t xray "nftables apply failed"
        rm -f "$nft_file"
        return 1
    }

    rm -f "$nft_file"
    logger -t xray "Network ready (bypass: ${bypass_ips:-none})"
}

start_service() {
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    setup_network || return 1

    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_set_param limits core="unlimited"
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param file "$CONF"
    procd_close_instance
}

stop_service() {
    nft delete table inet xray 2>/dev/null
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    logger -t xray "Stopped, network cleaned"
}

service_triggers() {
    procd_add_reload_trigger "xray"
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable
echo "✓ init.d Xray установлен"

# 7. Policy routing
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables
echo "✓ routing настроили"

# 8. sysctl
echo "[5] Настройка sysctl..."
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "✓ sysctl настроили"

# 9. Geo + HWID + config.json
echo "[6] Генерация конфигурации..."
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

# 10. Cron: автообновление в 2.30 ночи
echo "[7] Настройка автообновления (cron)..."
CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "  → ✓ Добавлено в crontab: $CRON_ENTRY"
else
    echo "  → Cron-задача уже существует, пропускаем"
fi

# 11. Настройка обновления после включения
echo "[8] Настройка автообновления (hotplug)..."

cat > /etc/hotplug.d/iface/99-xray-autoupdate << 'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

for i in 1 2 3; do
    sleep 5
    if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "✓ hotplug автообновление настроено"

# 12. Запуск служб в правильном порядке
echo "[9] Запуск служб..."
mkdir -p /usr/share/nftables.d/ruleset-post
/etc/init.d/https-dns-proxy restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray start
echo "✓ Перезапустили службы"

sleep 3

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "[OK] Конфиг Xray валиден"
else
    echo "[ERR] Конфиг НЕ валиден"
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
