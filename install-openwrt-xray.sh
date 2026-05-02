#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)
# логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "Запускать нужно от root"
	exit 1
}

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
NFT_UPDATER="/usr/share/xray/update-nft.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SUB_FILE="$CONFIG_DIR/subscription.url"
HWID_FILE="$CONFIG_DIR/hwid"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"

mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# 1. Устанавливаем Timezone
echo "1. Устанавливаем Timezone:"
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system
echo "✅"

# 2. Подписка
echo "2. Сохраняем подписку:"
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && {
	echo "Ошибка: пустой URL"
	exit 1
}

echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "✅"

# 3. Установка Xray из GitHub (с .dgst + SHA2-256)
echo "3. Устанавливаем Xray из GitHub:"

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	grep '"tag_name"' | cut -d '"' -f 4)

[ -z "$LATEST_VERSION" ] && {
	echo "Ошибка: не удалось получить версию Xray"
	exit 1
}

ARCH=$(uname -m)
case "$ARCH" in
x86_64 | amd64) MACHINE="64" ;;
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
	grep '^SHA2-256' "$1" |
		sed 's/.*= *//' |
		tr -cd '0-9a-fA-F' |
		cut -c1-64
}

echo "  → Скачиваем .dgst для Xray..."
curl -s -L "${ZIP_URL}.dgst" -o "$DGST_FILE" || {
	echo "Ошибка: не удалось скачать .dgst для Xray"
	exit 1
}

REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
[ -z "$REMOTE_SHA" ] && {
	echo "Ошибка: не удалось извлечь SHA2-256 из .dgst"
	exit 1
}

# проверяем свободное место
FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
	echo "[ERR] Недостаточно места в /tmp (нужно минимум 20MB)" >>"$LOG_FILE"
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

	echo "$REMOTE_SHA" >"$SHA_FILE"
fi

unzip -q "$ZIP_DEST" -d "$TMP_DIR"

# Устанавливаем основной бинарник
cp "$TMP_DIR/xray" /usr/bin/xray
chmod 755 /usr/bin/xray

rm -rf "$TMP_DIR"
echo "✅ Xray установлен версии $LATEST_VERSION"

# 4. Загружаем скрипты из репозитория
echo "4. Загружаем скрипты из репозитория:"

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
	echo "→ $dst"
}

download "$REPO/xray-generate-config.py" "$GENERATOR"
download "$REPO/xray-sub-parser.py" "$PARSER"
download "$REPO/update-xray.sh" "$UPDATER"
download "$REPO/update-nft.sh" "$NFT_UPDATER"

echo "✅"

# 5. Создаём br-guest
echo "5. Создаём br-guest:"

GUEST_NET="guest"
GUEST_IP="192.168.2.1/24"

uci -q delete network.${GUEST_NET}_dev
uci set network.${GUEST_NET}_dev="device"
uci set network.${GUEST_NET}_dev.type="bridge"
uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"

uci -q delete network.$GUEST_NET
uci set network.$GUEST_NET="interface"
uci set network.$GUEST_NET.proto="static"
uci set network.$GUEST_NET.device="br-${GUEST_NET}"
uci set network.$GUEST_NET.ipaddr="${GUEST_IP%%/*}"
uci set network.$GUEST_NET.netmask="255.255.255.0"
uci set network.$GUEST_NET.force_link="1"

uci commit network
echo "✅"

# 6. Настройка dnsmasq и DoH
echo "6. Настраиваем DNS (dnsmasq):"

uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'
uci commit dhcp

echo "✅"

# 7. Создаём init.d для Xray
echo "7. Создаём init.d для Xray:"

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

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

    # Настройка сети через отдельный скрипт
    /usr/share/xray/update-nft.sh || return 1

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

# 8. Настраиваем sysctl
echo "8. Настраиваем routing:"

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "✅"

# 9. Настраиваем sysctl
echo "9. Настраиваем sysctl:"

# Применяем немедленно
sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

# Создаём постоянный конфиг (всегда перезаписываем)
cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "✅"

# 10. Geo + HWID + config.json
echo "10. Скачиваем геофайлы, делаем HWID, генерируем config.json"

update_geo() {
	local URL="$1"  # https://cdn.jsdelivr.net/.../geoip.dat
	local DEST="$2" # /etc/xray/geo/geoip.dat

	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → Скачиваем $BASE"

	# Скачиваем SHA256
	curl -H "Cache-Control: no-cache" -sSL -o "$TMP_SHA" "${URL}.sha256sum"
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"

	if [ -z "$REMOTE_SHA" ]; then
		echo "🚫 Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	fi

	# Скачиваем сам файл во временное место
	curl -f -H "Cache-Control: no-cache" -sSL -o "$TMP" "$URL"

	# Считаем локальный SHA256
	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"

	# Проверяем совпадение
	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "🚫 SHA mismatch $BASE" >>"$LOG_FILE"
		echo "expected: $REMOTE_SHA" >>"$LOG_FILE"
		echo "actual:   $LOCAL_SHA" >>"$LOG_FILE"
		rm -f "$TMP" "$TMP_SHA"
		exit 1
	fi

	# Атомарная замена
	mv "$TMP" "$DEST"

	# Сохраняем SHA в state (для будущих обновлений)
	echo "$REMOTE_SHA" >"$SHA_FILE"

	echo "→ $BASE загружен и проверен" >>"$LOG_FILE"
	echo "$BASE - ✅"
}

# Вызовы
update_geo \
	"https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat" \
	"$GEO_DIR/geoip.dat"

update_geo \
	"https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat" \
	"$GEO_DIR/geosite.dat"

HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
echo "$HWID" >"$HWID_FILE"
chmod 600 "$HWID_FILE"

curl -s -L -m 20 -H "x-hwid: $HWID" "$SUB_URL" |
	python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

if [ ! -s "$CONFIG_JSON" ]; then
	echo "Ошибка: не удалось создать config.json"
	exit 1
fi
echo "✅"

# 11. Cron: автообновление в 2.30 ночи
echo "11. Настройка Crontab:"
CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(
		crontab -l 2>/dev/null || true
		echo "$CRON_ENTRY"
	) | crontab -
	echo "✅"
else
	echo "❌ Cron-задача уже существует, пропускаем"
fi

# 12. Настройка обновления после включения
echo "12. Настройка hotplug:"

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

for i in 1 2 3 4 5 6 7 8; do
    sleep 5
    if curl -fs --max-time 3 https://www.google.com/gen_204 >/dev/null; then
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "✅ hotplug настроен"

# 13. Запуск и рестарт служб
echo "13. Запускаем службы:"
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray start
echo "✅"

sleep 3

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "Конфиг Xray прошел проверку - ✅"
else
	echo " Конфиг Xray НЕ прошел проверку! - 🚫"
	exit 1
fi

echo "Проверяем, запущен ли Xray:"
if pgrep -a xray >/dev/null; then
	echo "Xray запущен - ✅"
else
	echo "Xray НЕ запущен - 🚫"
fi

echo ""
echo "=== Установка завершена ==="
