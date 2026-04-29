#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

# логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
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
STATE_DIR="/etc/xray/state"

mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$CONFIG_DIR" "$GEO_DIR" "$STATE_DIR"

# 1. Устанавливаем Timezone
echo "1️⃣ Устанавливаем Timezone:"
uci set system.@system[0].zonename='Europe/Moscow'
uci commit system
echo "✅"

# 2. Подписка
echo "2️⃣ Сохраняем подписку:"
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }

echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "✅"

# 3. Установка Xray из GitHub (с .dgst + SHA2-256)
echo "3️⃣ Устанавливаем Xray из GitHub:"

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

  # проверяем свободное место
FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
    echo "[ERR] Недостаточно места в /tmp (нужно минимум 20MB)" >> "$LOG"
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
echo "✅ Xray установлен версии $LATEST_VERSION"

echo "4️⃣ Загружаем скрипты из репозитория:"

download() {
    local url="$1"
    local dst="$2"

    wget -q "$url" -O "$dst"

    # Проверка: файл существует и не пустой
    if [ ! -s "$dst" ]; then
        echo "❌ Ошибка: файл $dst не скачан или пустой"
        exit 1
    fi

    # Проверка: не HTML-ошибка
    if head -n 1 "$dst" | grep -qi "<html"; then
        echo "❌ Ошибка: сервер вернул HTML вместо файла ($dst)"
        exit 1
    fi

    chmod +x "$dst"
    echo "✅ $dst"
}

download "$REPO/xray-generate-config.py" "$GENERATOR"
download "$REPO/xray-sub-parser.py" "$PARSER"
download "$REPO/update-xray.sh" "$UPDATER"

echo "✅"


# 5. Настройка dnsmasq и DoH
echo "5️⃣ Настраиваем DNS (dnsmasq):"

uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci commit dhcp

echo "✅"

# 6. Создаём единый init‑скрипт Xray
echo "6️⃣ Создаём init.d для Xray:"

cat > /etc/init.d/xray << 'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

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
    # Очистка старых правил
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Bypass IPs
    local bypass_ips
    bypass_ips=$(extract_server_ips | tr '\n' ',' | sed 's/,$//')

    # nftables
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
    # Проверка geodata
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    # Проверка валидности config.json
    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    # Настройка сети
    setup_network || return 1

    # Запуск Xray через procd
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

    # Если Xray не стартовал → отключить TProxy
    sleep 1
    if ! pidof xray >/dev/null; then
        logger -t xray "Xray failed to start — disabling TProxy"

        nft delete table inet xray 2>/dev/null
        while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null

        return 1
    fi

    logger -t xray "Xray started successfully"
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
echo "✅"

# 7. Policy routing
echo "7️⃣ Настраиваем routing:"
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables
echo "✅"

# 8. sysctl
echo "8️⃣ Настраиваем sysctl:"
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1
grep -q route_localnet /etc/sysctl.conf || echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
grep -q ip_forward /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
echo "✅"

# 9. Geo + HWID + config.json
echo "9️⃣ Скачиваем геофайлы, делаем HWID, генерируем config.json"

download_geo() {
    local url_data="$1"
    local url_sha="$2"
    local dst="$3"

    local base
    base="$(basename "$dst")"

    local tmp="/tmp/$base.tmp"
    local tmp_sha="/tmp/$base.sha256"

    echo "→ Скачиваем $base"

    # 1. Скачиваем файл и sha256
    curl -fsSL "$url_data" -o "$tmp"
    curl -fsSL "$url_sha"  -o "$tmp_sha"

    # 2. Проверяем, что файлы не пустые
    if [ ! -s "$tmp" ] || [ ! -s "$tmp_sha" ]; then
        echo "❌ Ошибка: $url_data или его sha256 пустые"
        rm -f "$tmp" "$tmp_sha"
        exit 1
    fi

    # 3. Проверяем SHA256
    if ! sha256sum -c "$tmp_sha" --status; then
        echo "❌ Ошибка: контрольная сумма $base не совпадает"
        rm -f "$tmp" "$tmp_sha"
        exit 1
    fi

    # 4. Атомарная замена
    mv "$tmp" "$dst"
    rm -f "$tmp_sha"

    echo "✅ $base обновлён"
}

download_geo \
  "https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat" \
  "https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat.sha256sum" \
  "$GEO_DIR/geoip.dat"

download_geo \
  "https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat" \
  "https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat.sha256sum" \
  "$GEO_DIR/geosite.dat"

HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
echo "$HWID" > "$HWID_FILE"
chmod 600 "$HWID_FILE"

curl -s -L -m 20 -H "x-hwid: $HWID" "$SUB_URL" \
| python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

if [ ! -s "$CONFIG_JSON" ]; then
    echo "Ошибка: не удалось создать config.json"
    exit 1
fi
echo "✅"

# 10. Cron: автообновление в 2.30 ночи
echo "🔟 Настройка Crontab:"
CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "✅"
else
    echo "❌ Cron-задача уже существует, пропускаем"
fi

# 11. Настройка обновления после включения
echo "1️⃣1️⃣ Настройка hotplug:"

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
echo "✅ hotplug настроен"

# 12. Запуск и рестарт служб
echo "1️⃣2️⃣ Запускаем службы:"
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray start
echo "✅"

sleep 3

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "✅ Конфиг Xray прошел проверку"
else
    echo "🚫 Конфиг Xray НЕ прошел проверку!"
    exit 1
fi

echo "Проверяем, запущен ли Xray:"
if pgrep -a xray >/dev/null; then
    echo "✅ Xray запущен"
else
    echo "🚫 Xray НЕ запущен"
fi

echo ""
echo "=== Установка завершена ==="
