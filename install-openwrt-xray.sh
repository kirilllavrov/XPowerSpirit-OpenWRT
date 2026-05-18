#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy

# Логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "Запускать нужно от root"
	exit 1
}

# Переменные
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

DWL_DOMAIN=""
SUB_URL=""
SETUP_GUEST=0


LAN_IF="br-lan"
WAN_IF="wan"

GUEST_NET="guest"
GUEST_IP="192.168.2.1"
DL_GUEST="5120"
UL_GUEST="5120"

# PPPoE переменные
SETUP_PPPOE=0
PPPOE_DEVICE="wan"
PPPOE_USERNAME=""
PPPOE_PASSWORD=""
PPPOE_KEEPALIVE="4 5"
PPPOE_MTU="1492"
PPPOE_IPV6="0"

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--guest-ip=*) GUEST_IP="${arg#*=}" ;;
	--guest-dl=*) DL_GUEST="${arg#*=}" ;;
	--guest-ul=*) UL_GUEST="${arg#*=}" ;;
	--sub=*) SUB_URL="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	--guest=1) SETUP_GUEST=1 ;;
	--guest=0) SETUP_GUEST=0 ;;
	--pppoe=1) SETUP_PPPOE=1 ;;
	--pppoe-dev=*) PPPOE_DEVICE="${arg#*=}" ;;
	--pppoe-user=*) PPPOE_USERNAME="${arg#*=}" ;;
	--pppoe-pass=*) PPPOE_PASSWORD="${arg#*=}" ;;
	--pppoe-keepalive=*) PPPOE_KEEPALIVE="${arg#*=}" ;;
	--pppoe-mtu=*) PPPOE_MTU="${arg#*=}" ;;
	--pppoe-ipv6=*) PPPOE_IPV6="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Создаём необходимые директории
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# Создаём директорию для nftables
mkdir -p /usr/share/nftables.d/ruleset-post

# =============================================
# Функции загрузки
# =============================================

fetch_url() {
	local url="$1"
	local dst="$2"
	local max_retries=3
	local retry=1

	while [ $retry -le $max_retries ]; do
		curl -s -L --user-agent "OpenWrt-Xray/1.0" --max-time 15 -o "$dst" "$url"
		local rc=$?

		if [ $rc -eq 0 ] && [ -s "$dst" ]; then
			if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
				rm -f "$dst"
			else
				return 0
			fi
		fi

		if [ $retry -lt $max_retries ]; then
			sleep 2
		fi
		retry=$((retry + 1))
	done

	return 1
}

fetch_url_with_header() {
	local url="$1"
	local dst="$2"
	local header="$3"
	local max_retries=2
	local retry=1

	while [ $retry -le $max_retries ]; do
		curl -s -L --user-agent "OpenWrt-Xray/1.0" -H "$header" --max-time 20 -o "$dst" "$url"
		local rc=$?

		if [ $rc -eq 0 ] && [ -s "$dst" ]; then
			if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
				rm -f "$dst"
			else
				return 0
			fi
		fi

		if [ $retry -lt $max_retries ]; then
			sleep 2
		fi
		retry=$((retry + 1))
	done

	return 1
}

# =============================================
# 0. Настройка PPPoE (опционально)
# =============================================
if [ "$SETUP_PPPOE" -eq 1 ]; then
	echo "0. Настройка PPPoE..."
	
	if [ -z "$PPPOE_USERNAME" ] || [ -z "$PPPOE_PASSWORD" ]; then
		echo "  [X] Ошибка: для PPPoE нужно указать --pppoe-user и --pppoe-pass"
		exit 1
	fi
	
	# Установка пакетов PPPoE
	echo "  → Устанавливаем пакеты для PPPoE..."
	opkg update >/dev/null 2>&1
	opkg install ppp kmod-pppoe ppp-mod-pppoe >/dev/null 2>&1
	
	# Настройка WAN интерфейса для PPPoE
	uci set network.wan.proto='pppoe'
	uci set network.wan.device="$PPPOE_DEVICE"
	uci set network.wan.username="$PPPOE_USERNAME"
	uci set network.wan.password="$PPPOE_PASSWORD"
	uci set network.wan.keepalive="$PPPOE_KEEPALIVE"
	uci set network.wan.mtu="$PPPOE_MTU"
	uci set network.wan.defaultroute='1'
	uci set network.wan.peerdns='1'
	uci set network.wan.ipv6="$PPPOE_IPV6"
	
	uci commit network
	
	echo "  → Применяем настройки PPPoE..."
	service network restart
	sleep 5
	
	if ip link show pppoe-wan >/dev/null 2>&1; then
		echo "  ✓ PPPoE подключён"
	else
		echo "  [X] PPPoE не подключился, проверьте логи: logread | grep pppd"
		exit 1
	fi
else
	echo "0. Пропускаем настройку PPPoE (используйте --pppoe=1 для включения)"
fi

# =============================================
# 1. Timezone
# =============================================
echo "1. Устанавливаем Timezone..."
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system

ntpd -q -p 77.88.8.8 2>/dev/null || ntpd -q -p 1.1.1.1 2>/dev/null

# =============================================
# 2. Подписка
# =============================================
echo "2. Сохраняем подписку..."
if [ -z "$SUB_URL" ]; then
	echo "Ошибка: пустой URL (задайте через --sub=URL)"
	exit 1
fi

echo "$SUB_URL" >"$SUB_FILE"
chmod 600 "$SUB_FILE"
echo "[+] Подписка сохранена: $SUB_URL"

# =============================================
# 3. Отключаем IPv6 (экономия памяти на 256MB RAM)
# =============================================
if [ "$PPPOE_IPV6" = "0" ]; then
	echo "3. Отключаем IPv6 для экономии памяти..."
	
	uci set network.lan.ipv6='0'
	uci set network.wan.ipv6='0'
	uci set dhcp.lan.dhcpv6='disabled'
	uci set dhcp.lan.ra='disabled'
	uci -q delete network.wan6
	uci commit network
	uci commit dhcp
	
	/etc/init.d/odhcpd stop 2>/dev/null || true
	/etc/init.d/odhcpd disable 2>/dev/null || true
	
	service network restart
	sleep 3
	echo "[+] IPv6 отключён"
fi

# =============================================
# 4. Гостевая сеть (опционально)
# =============================================
if [ "$SETUP_GUEST" -eq 1 ]; then
	echo "4. Настройка Guest Network"

	# Guest Bridge
	uci -q delete network.${GUEST_NET}_dev
	uci set network.${GUEST_NET}_dev="device"
	uci set network.${GUEST_NET}_dev.type="bridge"
	uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"
	uci set network.${GUEST_NET}_dev.bridge_empty="1"

	uci -q delete network.$GUEST_NET
	uci set network.$GUEST_NET="interface"
	uci set network.$GUEST_NET.proto="static"
	uci set network.$GUEST_NET.device="br-${GUEST_NET}"
	uci set network.$GUEST_NET.ipaddr="$GUEST_IP"
	uci set network.$GUEST_NET.netmask="255.255.255.0"
	uci commit network

	# DHCP Guest
	uci -q delete dhcp.$GUEST_NET
	uci set dhcp.$GUEST_NET="dhcp"
	uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
	uci set dhcp.$GUEST_NET.start="100"
	uci set dhcp.$GUEST_NET.limit="150"
	uci set dhcp.$GUEST_NET.leasetime="12h"
	uci commit dhcp

	# Firewall Guest Zone
	uci -q delete firewall.$GUEST_NET
	uci set firewall.$GUEST_NET="zone"
	uci set firewall.$GUEST_NET.name="$GUEST_NET"
	uci set firewall.$GUEST_NET.network="$GUEST_NET"
	uci set firewall.$GUEST_NET.input="REJECT"
	uci set firewall.$GUEST_NET.output="ACCEPT"
	uci set firewall.$GUEST_NET.forward="REJECT"
	uci set firewall.$GUEST_NET.masq="1"

	# Firewall правила
	uci -q delete firewall.${GUEST_NET}_dns
	uci set firewall.${GUEST_NET}_dns="rule"
	uci set firewall.${GUEST_NET}_dns.name="Allow-DNS-Guest"
	uci set firewall.${GUEST_NET}_dns.src="$GUEST_NET"
	uci set firewall.${GUEST_NET}_dns.dest_port="53"
	uci set firewall.${GUEST_NET}_dns.proto="tcp udp"
	uci set firewall.${GUEST_NET}_dns.target="ACCEPT"

	uci -q delete firewall.${GUEST_NET}_wan
	uci set firewall.${GUEST_NET}_wan="forwarding"
	uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
	uci set firewall.${GUEST_NET}_wan.dest="wan"
	uci commit firewall

	service network restart
	sleep 3
	service firewall restart

	echo "[+] Guest Network настроена: ${GUEST_IP}/24"
fi

# =============================================
# 5. Установка Xray из GitHub
# =============================================
echo "5. Устанавливаем Xray из GitHub..."

# Ждём доступности GitHub API (сеть могла только что перезапуститься)
for i in $(seq 1 10); do
	if curl -s --user-agent "OpenWrt-Xray/1.0" --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание доступа к GitHub... ($i)"
	sleep 2
done

# Получаем версию Xray
LATEST_VERSION=$(curl -s --user-agent "OpenWrt-Xray/1.0" --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && {
	echo "  [X] Ошибка: не удалось получить версию Xray"
	exit 1
}

LATEST_VER_NUM="${LATEST_VERSION#v}"

# Проверяем, какая версия уже установлена, если установлена
CURRENT_VERSION=""
if [ -x /usr/bin/xray ]; then
	CURRENT_VERSION=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
fi

if [ "$CURRENT_VERSION" = "$LATEST_VER_NUM" ]; then
	echo "  ✓ Xray уже актуальной версии $LATEST_VERSION, пропускаем установку"
else
	[ -n "$CURRENT_VERSION" ] && echo "  → Текущая версия: $CURRENT_VERSION, будет обновлено до $LATEST_VER_NUM"

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

	# Парсер: берем SHA2-256 из .dgst
	extract_sha256() {
		grep '^SHA2-256' "$1" |
			sed 's/.*= *//' |
			tr -cd '0-9a-fA-F' |
			cut -c1-64
	}

	echo "  → Версия: $LATEST_VERSION, архитектура: $MACHINE"
	echo "  → URL: ${ZIP_URL}.dgst"

	echo "  → Скачиваем .dgst для Xray..."
	fetch_url "${ZIP_URL}.dgst" "$DGST_FILE" || {
		echo "  [X] Ошибка: не удалось скачать .dgst для Xray"
		exit 1
	}

	# Проверяем, что .dgst не пустой и содержит SHA2-256
	if [ ! -s "$DGST_FILE" ] || ! grep -q 'SHA2-256' "$DGST_FILE" 2>/dev/null; then
		echo "  [X] Ошибка: .dgst файл пустой или не содержит SHA2-256"
		echo "  → Содержимое ответа:"
		cat "$DGST_FILE" 2>/dev/null || echo " (файл пустой)"
		exit 1
	fi

	REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Ошибка: не удалось извлечь SHA2-256 из .dgst"
		exit 1
	}

	echo "  → Ожидаемый SHA2-256: ${REMOTE_SHA:0:16}..."

	# проверяем свободное место в /tmp
	FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
	if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
		echo "  [X] Недостаточно места в /tmp (нужно минимум 20MB)" >>"$LOG_FILE"
		exit 1
	fi

	# если уже есть ZIP с таким же SHA — не качаем заново
	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$ZIP_DEST" ]; then
		echo "  ✓ Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
	else
		echo "  → Скачиваем Xray ZIP (${LATEST_VERSION})..."
		fetch_url "$ZIP_URL" "$ZIP_DEST" || {
			echo "  [X] Ошибка: не удалось скачать Xray ZIP"
			exit 1
		}

		if [ ! -s "$ZIP_DEST" ]; then
			echo "  [X] Ошибка: скачанный ZIP пустой"
			exit 1
		fi

		LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
		if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
			echo "  [X] Ошибка: SHA не совпадает!"
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
	echo "[+] Xray установлен версии $LATEST_VERSION"
fi

# =============================================
# 6. Загрузка скриптов
# =============================================
echo "6. Загружаем скрипты..."

download() {
	local url="$1"
	local dst="$2"
	if fetch_url "$url" "$dst"; then
		chmod +x "$dst"
	else
		echo "  [X] Ошибка: $dst"
		exit 1
	fi
}

download "$REPO/xray-generate-config.py" "$GENERATOR"
download "$REPO/xray-sub-parser.py" "$PARSER"
download "$REPO/update-xray.sh" "$UPDATER"
download "$REPO/update-nft.sh" "$NFT_UPDATER"

if [ -n "$DWL_DOMAIN" ]; then
	sed -i "s/DOMAIN_WHITELIST = \[/DOMAIN_WHITELIST = [\n    \"$DWL_DOMAIN\",/" "$GENERATOR"
fi

# =============================================
# 7. DNS (dnsmasq → Xray)
# =============================================
echo "7. Настраиваем DNS..."

uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].cachesize='1000'

uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci add_list dhcp.@dnsmasq[0].server='77.88.8.8'
uci commit dhcp

# =============================================
# 8. init.d для Xray
# =============================================
echo "8. Создаём init.d..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    ntpd -q -p 77.88.8.8 2>/dev/null || true
    sleep 1
	
    for i in $(seq 1 15); do
        if ip route | grep -q default; then
            break
        fi
        sleep 2
    done

    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing"
        return 1
    fi

    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config"
        return 1
    fi

    /usr/share/xray/update-nft.sh || return 1

    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_close_instance

    sleep 1
    if ! pidof xray >/dev/null; then
        nft delete table inet xray 2>/dev/null
        while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
        ip route flush table 100 2>/dev/null
        return 1
    fi

    logger -t xray "Xray started"
}

stop_service() {
    nft delete table inet xray 2>/dev/null
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable

# =============================================
# 9. Routing
# =============================================
echo "9. Настраиваем routing..."

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

# =============================================
# 10. Sysctl
# =============================================
echo "10. Настраиваем sysctl..."

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF

# =============================================
# 11. Geo + HWID + config.json
# =============================================
echo "11. Скачиваем геофайлы и генерируем конфиг..."

update_geo() {
	local URL="$1"
	local DEST="$2"
	local TMP="/tmp/$(basename "$DEST").tmp"
	
	fetch_url "$URL" "$TMP" || return 1
	mv "$TMP" "$DEST"
	echo "  ✓ $(basename "$DEST")"
}

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat" \
	"$GEO_DIR/geoip.dat"

update_geo \
	"https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat" \
	"$GEO_DIR/geosite.dat"

HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
echo "$HWID" >"$HWID_FILE"
chmod 600 "$HWID_FILE"

echo "  → Генерируем config.json..."
if fetch_url_with_header "$SUB_URL" "/tmp/sub_raw.txt" "x-hwid: $HWID"; then
	python3 "$PARSER" <"/tmp/sub_raw.txt" >"/tmp/parsed_outbounds.json"
	python3 "$GENERATOR" --output "$CONFIG_JSON" <"/tmp/parsed_outbounds.json"
	rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
else
	echo "  [X] Ошибка загрузки подписки"
	exit 1
fi

# =============================================
# 12. Cron
# =============================================
echo "12. Настройка cron..."

CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
fi

# =============================================
# 13. Hotplug
# =============================================
cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

if ! pidof xray >/dev/null; then
    /etc/init.d/xray start
    sleep 5
fi

for i in 1 2 3 4 5; do
    sleep 5
    if curl -fs --max-time 3 https://www.google.com/gen_204 >/dev/null; then
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate

# =============================================
# 14. Запуск
# =============================================
echo "14. Запускаем службы..."

service cron restart
service firewall restart
sleep 2
service xray start
sleep 3
service dnsmasq restart

# =============================================
# 15. Проверка
# =============================================
echo "15. Проверка установки..."

if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ config.json валиден"
else
	echo "  [X] config.json невалиден"
fi

if pgrep xray >/dev/null; then
	echo "  ✓ Xray запущен"
else
	echo "  [X] Xray не запущен"
fi

echo ""
echo "=== Установка завершена ==="
echo "LAN IP: 192.168.1.1"
echo "Xray: порт 12345 (TProxy)"
[ "$SETUP_GUEST" -eq 1 ] && echo "Guest Network: $GUEST_IP/24"
[ "$SETUP_PPPOE" -eq 1 ] && echo "PPPoE: $PPPOE_USERNAME@$PPPOE_DEVICE"