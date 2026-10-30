#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

# Логируем установку.
# Ротация: одна предыдущая копия, иначе повторные прогоны (особенно в контейнере)
# растили бы файл в tmpfs без предела.
LOG_FILE="/tmp/xray_install.log"
if [ -s "$LOG_FILE" ]; then
    _install_log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || wc -c <"$LOG_FILE")
    [ "${_install_log_size:-0}" -gt 262144 ] && mv -f "$LOG_FILE" "$LOG_FILE.prev"
fi
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
echo "  "

die() {
    echo "  [X] $1" >&2
    exit 1
}

[ "$(id -u)" != "0" ] && die "Запускать нужно от root"

# Каталог, из которого запущен установщик. Пусто при `curl ... | sh -s -- ...`
SCRIPT_DIR=""
case "$0" in
*/*)
	if [ -f "$0" ]; then
		SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
	fi
	;;
esac

# Переменные
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
NFT_UPDATER="/usr/share/xray/update-nft.sh"
SCRIPTS_UPDATER="/usr/share/xray/update-scripts.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"
COMMON_SH="/usr/share/xray/xray-common.sh"

# Значения из CLI (если не указаны — берутся из settings.default.json)
SUB_USER_AGENT=""
SUB_URL=""
REMARKS_FILTER=""
LAN_IP="192.168.1.1"
GUEST_ENABLED=0
GUEST_NET="guest"
GUEST_IP="192.168.2.1"
DL_GUEST="5120"
UL_GUEST="5120"
IOT_ENABLED=0
IOT_NET="iot"
IOT_IP="192.168.3.1"
DL_IOT="10240"
UL_IOT="10240"
# quiet — минимум журналов (роутер), normal — предупреждения, debug — подробно (стенд)
LOG_PRESET="quiet"


# =============================================
#   ХЕЛПЕРЫ ДЛЯ ЕДИНОГО JSON-КОНФИГА
# =============================================

# Bootstrap-чтение settings.json: нужно до того, как установлена xray-common.sh
# (download_file берёт из настроек заголовки запроса). После установки библиотеки
# эта версия заменяется на settings_get из xray-common.sh.
settings_get() {
    local key="$1"
    [ -f "$SETTINGS_JSON" ] || return 1
    jq -r "
        if $key | type == \"boolean\" then
            if $key then \"1\" else \"0\" end
        elif $key | type == \"array\" then
            $key[]
        else
            $key // empty
        end
    " "$SETTINGS_JSON" 2>/dev/null
}

# =============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# =============================================

# Универсальная загрузка файла (с авто-заголовками из settings.json + до 3 кастомных)
# Использование:
#   download_file "URL" "DEST" ["HEADER1" "HEADER2" "HEADER3"]
download_file() {
    local url="$1"
    local dst="$2"
    shift 2
    local max_retries=3
    local retry=1

    # Системные заголовки из settings.json (могут быть пустыми при первом запуске)
    local _ua _ver _model _os
    _ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "XPower/1.0")
    _ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
    _model=$(settings_get ".device_model" 2>/dev/null || echo "")
    _os=$(settings_get ".device_os" 2>/dev/null || echo "")

    while [ $retry -le $max_retries ]; do
        curl -fsS -L --max-time 15 \
            -H "User-Agent: $_ua" \
            ${_ver:+-H "X-Ver-Os: $_ver"} \
            ${_model:+-H "X-Device-Model: $_model"} \
            ${_os:+-H "X-Device-Os: $_os"} \
            ${1:+-H "$1"} \
            ${2:+-H "$2"} \
            ${3:+-H "$3"} \
            -o "$dst" "$url"
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

download_script() {
    local url="$1"
    local dst="$2"
    download_file "$url" "$dst" || die "Не удалось скачать $dst"
    chmod +x "$dst"
    echo "  → $dst"
}

# Ставит исполняемый файл: из распакованного архива, если он лежит рядом
# с установщиком, иначе скачивает с GitHub. Так запуск из latest.zip
# не смешивает проверенный архив с текущим main.
install_script() {
    local name="$1"
    local dst="$2"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
        cp "$SCRIPT_DIR/$name" "$dst" || die "Не удалось скопировать $name"
        chmod +x "$dst"
        echo "  → $dst (из архива)"
        return 0
    fi
    download_script "$REPO/$name" "$dst"
}

# То же для файлов данных (settings.default.json)
install_data() {
    local name="$1"
    local dst="$2"
    local mode="${3:-600}"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
        cp "$SCRIPT_DIR/$name" "$dst" || die "Не удалось скопировать $name"
        echo "  → $dst (из архива)"
    else
        download_file "$REPO/$name" "$dst" || die "Не удалось скачать $name"
    fi
    chmod "$mode" "$dst"
}

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--guest=1) GUEST_ENABLED=1 ;;
	--guest=0) GUEST_ENABLED=0 ;;
	--guest-ip=*) GUEST_IP="${arg#*=}" ;;
	--guest-dl=*) DL_GUEST="${arg#*=}" ;;
	--guest-ul=*) UL_GUEST="${arg#*=}" ;;
	--iot=1) IOT_ENABLED=1 ;;
	--iot=0) IOT_ENABLED=0 ;;
	--iot-ip=*) IOT_IP="${arg#*=}" ;;
	--iot-dl=*) DL_IOT="${arg#*=}" ;;
	--iot-ul=*) UL_IOT="${arg#*=}" ;;
	--lan-ip=*) LAN_IP="${arg#*=}" ;;
	--sub=*) SUB_URL="${arg#*=}" ;;
	--log=*) LOG_PRESET="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Валидация
if [ -z "$SUB_URL" ]; then
	die "--sub=URL обязателен"
fi

case "$LOG_PRESET" in
quiet | normal | debug) ;;
*) die "--log=$LOG_PRESET: допустимые значения quiet, normal, debug" ;;
esac

# Проверка зависимостей до любых изменений. Иначе установщик успевает сменить
# timezone и сеть, а падает на шаге 6 (curl/jq/unzip) — устройство остаётся
# полу-настроенным.
_missing=""
for _cmd in curl jq unzip python3 nft uci; do
	command -v "$_cmd" >/dev/null 2>&1 || _missing="$_missing $_cmd"
done
[ -n "$_missing" ] && die "Не хватает команд:$_missing
Установите пакеты и запустите установщик снова:
  apk update && apk add curl ca-bundle nftables-json kmod-nft-tproxy kmod-nft-socket python3 resolveip unzip jq"

# Создаём необходимые директории
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR" /tmp/log

# Инициализируем settings.json из репозитория (если файла нет)
if [ ! -f "$SETTINGS_JSON" ]; then
    echo "  → Инициализируем settings.json из settings.default.json..."
    install_data "settings.default.json" "$SETTINGS_JSON" 600
    echo "  ✓ settings.json инициализирован"
fi

# =============================================
# 1. Устанавливаем Timezone и синхронизируем время
# =============================================
echo "1. Устанавливаем Timezone и синхронизируем время..."
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system

ntpd -q -p ru.pool.ntp.org 2>/dev/null ||
	ntpd -q -p time.google.com 2>/dev/null ||
	echo " [!] Синхронизация времени не удалась, продолжаем..."

echo "[+] Timezone установлен в Europe/Moscow, время синхронизировано"

# =============================================
# 2. Устанавливаем скрипты
# =============================================
echo "2. Устанавливаем скрипты..."

install_script "xray-generate-config.py" "$GENERATOR"
install_script "xray-sub-parser.py" "$PARSER"
install_script "update-xray.sh" "$UPDATER"
install_script "update-nft.sh" "$NFT_UPDATER"
install_script "update-scripts.sh" "$SCRIPTS_UPDATER"
install_script "xray-common.sh" "$COMMON_SH"

# Библиотека нужна остальным шагам установщика (settings_set, архитектура, SHA)
. "$COMMON_SH" || die "Не удалось подключить $COMMON_SH"

echo "[+] Все скрипты загружены и готовы к использованию"

# =============================================
# 3. Сохраняем настройки в единый settings.json
# =============================================
echo "3. Сохраняем настройки в settings.json..."

# Определяем модель устройства
echo "  → Определяем модель устройства..."
DEVICE_MODEL=$(dmesg | sed -n 's/.*Machine model: //p' | head -1)
if [ -n "$DEVICE_MODEL" ]; then
    settings_set ".device_model" "$DEVICE_MODEL"
    echo "  ✓ Модель: $DEVICE_MODEL"
else
    echo "  [!] Не удалось определить модель устройства"
fi

# Определяем версию OpenWrt
echo "  → Определяем версию OpenWrt..."
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    [ -n "$DISTRIB_ID" ] && settings_set ".device_os" "$DISTRIB_ID"
    [ -n "$DISTRIB_RELEASE" ] && settings_set ".ver_os" "$DISTRIB_RELEASE"
    echo "  ✓ ОС: $DISTRIB_ID $DISTRIB_RELEASE"
else
    echo "  [!] /etc/openwrt_release не найден"
fi

settings_set ".subscription.url" "$SUB_URL"
[ -n "$SUB_USER_AGENT" ] && settings_set ".subscription.user_agent" "$SUB_USER_AGENT"
[ -n "$REMARKS_FILTER" ] && settings_set ".subscription.remarks_filter" "$REMARKS_FILTER"
settings_set ".log.preset" "$LOG_PRESET"
echo "[+] settings.json сохранён: $SETTINGS_JSON (log.preset=$LOG_PRESET)"

# =============================================
# 4. Настраиваем LAN и отключаем IPv6
# =============================================
echo "4. Настраиваем LAN (${LAN_IP}/24) и отключаем IPv6..."

uci set network.lan.ipaddr="$LAN_IP"
uci set network.lan.netmask="255.255.255.0"
uci set network.lan.ipv6='0'
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="150"
uci set network.wan.ipv6='0'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci -q delete network.wan6
uci commit network
uci commit dhcp

/etc/init.d/odhcpd stop 2>/dev/null || true
/etc/init.d/odhcpd disable 2>/dev/null || true

echo "[+] Сеть настроена (изменения применятся после перезагрузки), IPv6 отключён"

# =============================================
# 5. Изолированные сети (гостевая, IoT)
# =============================================
# setup_client_network <имя> <ip> <dl> <ul> <подпись>
# Одинаково настраивает изолированную сеть: bridge + interface, DHCP, firewall-зону
# с правилами DNS/DHCP и forwarding в wan, SQM с лимитами. Подпись используется
# в сообщениях и в именах firewall-правил.
setup_client_network() {
	local NET="$1"
	local IP="$2"
	local DL="$3"
	local UL="$4"
	local LABEL="$5"

	# Bridge + Interface
	uci -q delete network.${NET}_dev
	uci set network.${NET}_dev="device"
	uci set network.${NET}_dev.type="bridge"
	uci set network.${NET}_dev.name="br-${NET}"
	uci set network.${NET}_dev.bridge_empty="1"
	uci set network.${NET}_dev.mtu="1500"

	uci -q delete network.$NET
	uci set network.$NET="interface"
	uci set network.$NET.proto="static"
	uci set network.$NET.device="br-${NET}"
	uci set network.$NET.ipaddr="$IP"
	uci set network.$NET.netmask="255.255.255.0"
	uci set network.$NET.force_link="1"
	uci commit network
	echo "  → ${LABEL} Bridge + Interface настроены: br-${NET} (${IP}/24)"

	# DHCP
	uci -q delete dhcp.$NET
	uci set dhcp.$NET="dhcp"
	uci set dhcp.$NET.interface="$NET"
	uci set dhcp.$NET.start="100"
	uci set dhcp.$NET.limit="150"
	uci set dhcp.$NET.leasetime="12h"
	uci set dhcp.$NET.force="1"
	uci set dhcp.$NET.ignore="0"
	uci commit dhcp
	echo "  → DHCP для ${LABEL} настроен: $NET"

	# Firewall: зона
	uci -q delete firewall.$NET
	uci set firewall.$NET="zone"
	uci set firewall.$NET.name="$NET"
	uci set firewall.$NET.network="$NET"
	uci set firewall.$NET.input="REJECT"
	uci set firewall.$NET.output="ACCEPT"
	uci set firewall.$NET.forward="REJECT"
	uci set firewall.$NET.masq="1"
	uci set firewall.$NET.mtu_fix="1"
	echo "  → Firewall зона для ${LABEL} создана: $NET"

	# Firewall: DNS
	uci -q delete firewall.${NET}_dns
	uci set firewall.${NET}_dns="rule"
	uci set firewall.${NET}_dns.name="Allow-DNS-${LABEL}"
	uci set firewall.${NET}_dns.src="$NET"
	uci set firewall.${NET}_dns.dest_port="53"
	uci set firewall.${NET}_dns.proto="tcp udp"
	uci set firewall.${NET}_dns.target="ACCEPT"
	echo "  → Firewall правило для DNS создано: $NET"

	# Firewall: DHCP
	uci -q delete firewall.${NET}_dhcp
	uci set firewall.${NET}_dhcp="rule"
	uci set firewall.${NET}_dhcp.name="Allow-DHCP-${LABEL}"
	uci set firewall.${NET}_dhcp.src="$NET"
	uci set firewall.${NET}_dhcp.dest_port="67-68"
	uci set firewall.${NET}_dhcp.proto="udp"
	uci set firewall.${NET}_dhcp.target="ACCEPT"
	echo "  → Firewall правило для DHCP создано: $NET"

	# Firewall: forwarding в wan
	uci -q delete firewall.${NET}_wan
	uci set firewall.${NET}_wan="forwarding"
	uci set firewall.${NET}_wan.src="$NET"
	uci set firewall.${NET}_wan.dest="wan"
	uci commit firewall
	echo "  → Firewall правило для доступа ${LABEL} в WAN создано: $NET → wan"

	# SQM с лимитами (0/0 — без ограничений)
	uci -q delete sqm.$NET
	uci set sqm.$NET="queue"
	uci set sqm.$NET.interface="br-${NET}"
	uci set sqm.$NET.download="$DL"
	uci set sqm.$NET.upload="$UL"
	uci set sqm.$NET.qdisc="cake"
	uci set sqm.$NET.script="piece_of_cake.qos"
	if [ "$DL" = "0" ] && [ "$UL" = "0" ]; then
		uci set sqm.$NET.enabled="0"
		echo "  → SQM отключён для ${LABEL} (dl=0, ul=0 — без ограничений)"
	else
		uci set sqm.$NET.enabled="1"
		echo "  → SQM настроен для ${LABEL}: ${DL}kbps down / ${UL}kbps up"
	fi
	uci commit sqm
}

# =============================================
# 5a. Настраиваем гостевую сеть и лимиты скорости (если включена)
# =============================================
if [ $GUEST_ENABLED -eq 1 ]; then
	echo "5. Настройка Guest Network и SQM:"
	setup_client_network "$GUEST_NET" "$GUEST_IP" "$DL_GUEST" "$UL_GUEST" "Guest"
	echo "[+] Настройка Guest Network и SQM завершена (изменения применятся после перезагрузки)"
else
	echo "5. Пропускаем настройку гостевой сети (--guest=1 не указан)"
fi

# =============================================
# 5b. Настраиваем сеть IoT (если включена)
# =============================================
if [ $IOT_ENABLED -eq 1 ]; then
	echo "5b. Настройка IoT Network и SQM:"
	setup_client_network "$IOT_NET" "$IOT_IP" "$DL_IOT" "$UL_IOT" "IoT"
	echo "[+] Настройка IoT Network и SQM завершена (изменения применятся после перезагрузки)"
else
	echo "5b. Пропускаем настройку IoT сети (--iot=1 не указан)"
fi

# =============================================
# 6. Установка Xray из GitHub
# =============================================

# Ставит /usr/bin/xray нужной версии. Кэш ZIP проверяется по SHA2-256 из .dgst,
# поэтому повторная установка не скачивает архив заново.
install_xray_binary() {
	local latest latest_num current machine zip_url zip_dest sha_file dgst_file
	local remote_sha local_sha free_tmp

	# Ждём доступности GitHub API
	for i in $(seq 1 10); do
		curl -s --max-time 3 https://api.github.com >/dev/null 2>&1 && break
		echo "  → Ожидание доступа к GitHub... ($i)"
		sleep 2
	done

	latest=$(curl -fsS --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
		jq -r '.tag_name // empty')
	[ -n "$latest" ] || die "Не удалось получить версию Xray"

	latest_num="${latest#v}"
	current=""
	[ -x /usr/bin/xray ] && current=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')

	if [ "$current" = "$latest_num" ]; then
		echo "  ✓ Xray уже актуальной версии $latest, пропускаем установку"
		return 0
	fi
	[ -n "$current" ] && echo "  → Текущая версия: $current, будет обновлено до $latest_num"

	machine=$(resolve_xray_machine)
	[ -n "$machine" ] ||
		die "Архитектура $(uname -m) не поддерживается релизами Xray — установите пакет Xray вручную"

	zip_url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${machine}.zip"
	zip_dest="$TMP_DIR/xray.zip"
	sha_file="$STATE_DIR/xray.zip.sha256sum"
	dgst_file="$STATE_DIR/xray.dgst"

	echo "  → Версия: $latest, архитектура: $machine"
	echo "  → URL: ${zip_url}.dgst"
	echo "  → Скачиваем .dgst для Xray..."
	download_file "${zip_url}.dgst" "$dgst_file" || die "Не удалось скачать .dgst для Xray"

	if [ ! -s "$dgst_file" ] || ! grep -q 'SHA2-256' "$dgst_file" 2>/dev/null; then
		echo "  → Содержимое ответа:"
		cat "$dgst_file" 2>/dev/null || echo " (файл пустой)"
		die ".dgst файл пустой или не содержит SHA2-256"
	fi

	remote_sha=$(extract_sha256 "$dgst_file")
	[ -n "$remote_sha" ] || die "Не удалось извлечь SHA2-256 из .dgst"
	echo "  → Ожидаемый SHA2-256: ${remote_sha:0:16}..."

	free_tmp=$(df /tmp | awk 'NR==2 {print $4}')
	[ "$free_tmp" -ge 20480 ] || die "Недостаточно места в /tmp (нужно минимум 20MB)"

	if [ -f "$sha_file" ] && [ "$(cat "$sha_file")" = "$remote_sha" ] && [ -f "$zip_dest" ]; then
		echo "  ✓ Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
	else
		echo "  → Скачиваем Xray ZIP (${latest})..."
		download_file "$zip_url" "$zip_dest" || die "Не удалось скачать Xray ZIP"
		[ -s "$zip_dest" ] || die "Скачанный ZIP пустой"

		local_sha=$(sha256sum "$zip_dest" | awk '{print $1}')
		[ "$local_sha" = "$remote_sha" ] ||
			die "SHA не совпадает! ожидалось: $remote_sha, получено: $local_sha"
		echo "$remote_sha" >"$sha_file"

		unzip -q "$zip_dest" -d "$TMP_DIR"

		cp "$TMP_DIR/xray" /usr/bin/xray
		chmod 755 /usr/bin/xray

		echo "[+] Xray установлен версии $latest"
	fi
}

echo "6. Устанавливаем Xray из GitHub..."
install_xray_binary

# =============================================
# 7. Настройка DNS (dnsmasq → Xray)
# =============================================
echo "7. Настраиваем DNS (dnsmasq → Xray)..."

uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].max_cache_ttl='600'

# Порт Xray DNS и резервный апстрим — из settings.json → tproxy.dns_port и
# dns.dnsmasq_fallback: те же значения уходят в config.json, поэтому порт
# нельзя держать литералом в двух местах
DNS_PORT=$(settings_get ".tproxy.dns_port" 2>/dev/null)
[ -n "$DNS_PORT" ] || DNS_PORT=5353
DNS_FALLBACK=$(settings_get ".dns.dnsmasq_fallback" 2>/dev/null)
[ -n "$DNS_FALLBACK" ] || DNS_FALLBACK=77.88.8.8

uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$DNS_PORT"
uci add_list dhcp.@dnsmasq[0].server="$DNS_FALLBACK"
uci commit dhcp

echo "[+] DNS настроен (dnsmasq → Xray:$DNS_PORT + fallback $DNS_FALLBACK)"

# =============================================
# 8. Создаём init.d для Xray
# =============================================
echo "8. Создаём init.d для Xray..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=85
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    # Xray не создаёт каталог для log.access/log.error — без него старт падает
    mkdir -p /tmp/log

    # Ждём сеть
    for i in $(seq 1 15); do
        if ip route | grep -q default; then
            break
        fi
        logger -t xray "Waiting for network... ($i)"
        sleep 2
    done

    # Синхронизация времени (важно для TLS/REALITY)
    ntpd -q -p ru.pool.ntp.org 2>/dev/null || \
    ntpd -q -p time.google.com 2>/dev/null || \
    logger -t xray "Time sync failed, continuing"
    sleep 1

    # Проверяем geo-файлы
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    # Валидация конфига
    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    # Применяем nftables правила
    /usr/share/xray/update-nft.sh || {
        logger -t xray "Failed to apply nftables rules"
        return 1
    }

    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param file "$CONF"
    procd_close_instance

    # procd запустит xray после возврата из start_service().
    # Конфиг уже проверен xray run -test. При падении — respawn 3600 5 5.
    logger -t xray "Xray registered with procd (transparent gateway mode)"
}

stop_service() {
    # Параметры policy routing читаются в рантайме: init.d не перегенерируется
    # при изменении settings.json, а правила должны сниматься теми же метками,
    # которыми были поставлены
    local _fwmark _table
    _fwmark=$(jq -r '.tproxy.fwmark // 1' /etc/xray/settings.json 2>/dev/null)
    _table=$(jq -r '.tproxy.route_table // 100' /etc/xray/settings.json 2>/dev/null)
    [ -n "$_fwmark" ] || _fwmark=1
    [ -n "$_table" ] || _table=100

    # Убираем jump-правила из fw4
    local _handle
    _handle=$(nft -a list chain inet fw4 prerouting 2>/dev/null \
        | grep 'jump xray_tproxy' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 prerouting handle "$_handle" 2>/dev/null

    _handle=$(nft -a list chain inet fw4 output 2>/dev/null \
        | grep 'jump xray_output' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 output handle "$_handle" 2>/dev/null

    # Чистим цепочки и таблицу само-маршрутизации (type route)
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null
    nft delete table inet xray_self 2>/dev/null

    while ip rule del fwmark "$_fwmark" table "$_table" 2>/dev/null; do :; done
    ip route flush table "$_table" 2>/dev/null
    logger -t xray "Stopped, network restored"
}

service_triggers() {
    procd_add_reload_trigger "xray"
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable

echo "[+] init.d для Xray создан и включён"

# =============================================
# 9. Настраиваем routing
# =============================================
echo "9. Настраиваем routing..."

# Имя таблицы для fwmark — из settings.json → tproxy.route_table
ROUTE_TABLE=$(settings_get ".tproxy.route_table" 2>/dev/null)
[ -n "$ROUTE_TABLE" ] || ROUTE_TABLE=100

if ! grep -q "^$ROUTE_TABLE[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	# Таблица с другим номером могла остаться от прежней установки
	sed -i '/[[:space:]]xray$/d' /etc/iproute2/rt_tables 2>/dev/null
	echo "$ROUTE_TABLE xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing настроен (таблица $ROUTE_TABLE)"

# =============================================
# 10. Настраиваем sysctl
# =============================================
echo "10. Настраиваем sysctl:"

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен"

# =============================================
# 11. Cron: самообновление скриптов (2.20) и Xray (2.30)
# =============================================
echo "11. Настройка Crontab..."

# Уровень сообщений crond в syslog (system.@system[0].cronloglevel). В OpenWrt 25.12
# (busybox 1.37) значения означают: 5 — с отладочными сообщениями, 7 — исполнение
# команд (значение OpenWrt по умолчанию), 9 — тишина. Пресет → уровень:
case "$LOG_PRESET" in
normal) CRON_LOGLEVEL=7 ;;
debug) CRON_LOGLEVEL=5 ;;
*) CRON_LOGLEVEL=9 ;; # quiet: на роутере не пишем ничего, экономим RAM-буфер logd
esac
uci set system.@system[0].cronloglevel="$CRON_LOGLEVEL"
uci commit system
echo "[+] cronloglevel=$CRON_LOGLEVEL (пресет журналирования: $LOG_PRESET)"

# Расписание — из settings.json → update.cron: то же значение применяет
# update-xray.sh при каждом запуске, поэтому правка настроек не требует
# переустановки
CRON_SCRIPTS=$(settings_get ".update.cron.scripts" 2>/dev/null)
[ -n "$CRON_SCRIPTS" ] || CRON_SCRIPTS="20 2 * * *"
CRON_XRAY=$(settings_get ".update.cron.xray" 2>/dev/null)
[ -n "$CRON_XRAY" ] || CRON_XRAY="30 2 * * *"

SCRIPTS_CRON_ENTRY="$CRON_SCRIPTS $SCRIPTS_UPDATER >>/tmp/log/xray-scripts.log 2>&1"
CRON_ENTRY="$CRON_XRAY $UPDATER >>/tmp/log/xray-update.log 2>&1"

if ! crontab -l 2>/dev/null | grep -qF "$SCRIPTS_UPDATER"; then
	(
		crontab -l 2>/dev/null || true
		echo "$SCRIPTS_CRON_ENTRY"
	) | crontab -
	echo "[+] Cron-задача для обновления скриптов добавлена: $SCRIPTS_CRON_ENTRY"
else
	echo "[-] Cron-задача обновления скриптов уже существует, пропускаем"
fi

if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(
		crontab -l 2>/dev/null || true
		echo "$CRON_ENTRY"
	) | crontab -
	echo "[+] Cron-задача для обновления Xray добавлена: $CRON_ENTRY"
else
	echo "[-] Cron-задача уже существует, пропускаем"
fi

# =============================================
# 12. Настройка hotplug (автообновление после включения WAN)
# =============================================
echo "12. Настройка hotplug..."

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

if ! pidof xray >/dev/null; then
    /etc/init.d/xray start
    sleep 5
fi

for i in 1 2 3 4 5 6 7; do
    sleep 5
    if curl -fs --max-time 3 https://www.google.com/gen_204 >/dev/null; then
        [ -x /usr/share/xray/update-scripts.sh ] && /usr/share/xray/update-scripts.sh
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "[+] Hotplug для автообновления после включения WAN настроен"

# =============================================
# 13. Geo + HWID + config.json
# =============================================
echo "13. Geo + HWID + config.json"

update_geo() {
	local URL="$1"
	local DEST="$2"
	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → Скачиваем $BASE"

	# Без URL download_file уходит на пустой адрес и падает с "Could not resolve: .sha256sum"
	if [ -z "$URL" ]; then
		die "В settings.json не задан URL для $BASE (geo.geoip_url / geo.geosite_url) — добавьте ключи из settings.default.json"
	fi

	download_file "${URL}.sha256sum" "$TMP_SHA" || die "Не удалось получить SHA256 для $BASE (${URL}.sha256sum)"
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"
	[ -n "$REMOTE_SHA" ] || die "Пустой SHA256 для $BASE (${URL}.sha256sum)"

	download_file "$URL" "$TMP" || die "Не удалось скачать $BASE"
	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"

	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		rm -f "$TMP" "$TMP_SHA"
		die "SHA не совпадает для $BASE: ожидалось $REMOTE_SHA, получено $LOCAL_SHA"
	fi

	mv "$TMP" "$DEST"
	echo "$REMOTE_SHA" > "$SHA_FILE"
	rm -f "$TMP_SHA"
	echo "  ✓ $BASE скачан и проверен"
}

GEOIP_URL=$(settings_get ".geo.geoip_url")
GEOSITE_URL=$(settings_get ".geo.geosite_url")

update_geo "$GEOIP_URL" "$GEO_DIR/geoip.dat"
update_geo "$GEOSITE_URL" "$GEO_DIR/geosite.dat"

# =============================================
# 13b. HWID
# =============================================
echo "13b. Определяем HWID..."
HWID="$(settings_get ".hwid" 2>/dev/null)"
if [ -n "$HWID" ]; then
	echo "  ✓ Использую прежний HWID из settings.json: $HWID"
else
	HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
	settings_set ".hwid" "$HWID"
	echo "  ✓ HWID сохранён в settings.json: $HWID"
fi

# =============================================
# 11c. Генерация config.json
# =============================================
echo "13c. Генерируем config.json из подписки..."

SUB_URL=$(settings_get ".subscription.url")
SUB_UA=$(settings_get ".subscription.user_agent")
HWID=$(settings_get ".hwid")
REMARKS=$(settings_get ".subscription.remarks_filter")

echo "  → URL: $SUB_URL"
echo "  → User-Agent: $SUB_UA"
echo "  → HWID: $HWID"
echo "  → Remarks: ${REMARKS:-(нет)}"

# Скачиваем подписку с заголовками
download_file "$SUB_URL" "/tmp/sub_raw.txt" "x-hwid: $HWID" || die "Не удалось скачать подписку"

# Проверяем, что скачалось не HTML
head -n 1 "/tmp/sub_raw.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE" && die "Подписка вернула HTML, а не данные"

# Единый пайплайн: парсер (с автоопределением формата) → генератор
python3 "$PARSER" --ua "$SUB_UA" --remarks "$REMARKS" < "/tmp/sub_raw.txt" > "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"
PARSE_RC=$?

if [ "$PARSE_RC" -eq 2 ]; then
    echo "  [X] В подписке не найдено ни одного сервера: не тот формат (--sub-ua), пустой фильтр --remarks" >&2
    echo "      или все серверы оказались заглушками. DIRECT-конфиг в этом случае не создаётся." >&2
    echo "      Частая причина заглушек — лимит устройств у провайдера: подписка привязана к HWID," >&2
    echo "      и новый HWID ($HWID) считается ещё одним устройством." >&2
    echo "      Что делать: освободить устройство в панели провайдера или вернуть прежний HWID" >&2
    echo "      в $SETTINGS_JSON и запустить /usr/share/xray/update-xray.sh." >&2
    rm -f "/tmp/sub_raw.txt"
    exit 1
elif [ "$PARSE_RC" -ne 0 ]; then
    echo "  [X] Ошибка парсера подписки (код $PARSE_RC)" >&2
    rm -f "/tmp/sub_raw.txt"
    exit 1
fi

python3 "$GENERATOR" --format unified --output "$CONFIG_JSON" < "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE" || {
    echo "  [X] Ошибка генератора конфига" >&2
    rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
    exit 1
}

rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"

if [ ! -s "$CONFIG_JSON" ]; then
    die "Не удалось создать config.json"
fi
echo ""
echo "[+] Геофайлы загружены, конфиг сгенерирован"

# =============================================
# 14. Проверяем config.json
# =============================================
echo "14. Проверяем config.json на валидность..."
if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ $CONFIG_JSON прошел проверку"
else
	die "$CONFIG_JSON НЕ прошел проверку!"
fi

# =============================================
# 15. Перезагрузка
# =============================================
echo "15. Перезагрузка для применения всех изменений..."
echo ""
echo "=== Установка завершена ==="
echo "Устройство будет перезагружено через 5 секунд..."
sleep 5
reboot