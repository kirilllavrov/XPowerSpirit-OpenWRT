#!/bin/sh
# OpenWrt — Настройка Wi-Fi (основная, гостевая и IoT сети)
# Явное задание band + htmode; PMF и роуминг 802.11k/v/r — на уровне интерфейса

LOG="/tmp/setup-wifi.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

TAG="wifi-setup"
MOBILITY_DOMAIN="4f57"

# Ключевые шаги дублируются в syslog: /tmp — tmpfs, после перезагрузки журнала нет
log() {
	echo "$1"
	logger -t "$TAG" "$1" 2>/dev/null
}

echo "=== Настройка Wi-Fi (Россия, WPA2+WPA3, PMF) ==="

[ "$(id -u)" != "0" ] && {
	echo "[X] Требуются права root"
	exit 1
}

# === Значения по умолчанию ===
HOME_SSID="Home-WiFi"
HOME_PASS="HomeSecure123!"
GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"
IOT_SSID="IoT-WiFi"
IOT_PASS="IoTSecure123!"

# Явно заданные пароли не трогаем даже с --random-passwords
HOME_PASS_SET=0
GUEST_PASS_SET=0
IOT_PASS_SET=0

# Каналы: auto — прежнее поведение; иначе канал задаётся жёстко
CHANNEL_2G=""
CHANNEL_5G=""
# htmode: пусто — подобрать по возможностям радио
HTMODE_2G=""
HTMODE_5G=""
ROAMING=1
RANDOM_PASS=0
DRY_RUN=0

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--ssid=*) HOME_SSID="${arg#*=}" ;;
	--pass=*)
		HOME_PASS="${arg#*=}"
		HOME_PASS_SET=1
		;;
	--ssid-guest=*) GUEST_SSID="${arg#*=}" ;;
	--pass-guest=*)
		GUEST_PASS="${arg#*=}"
		GUEST_PASS_SET=1
		;;
	--ssid-iot=*) IOT_SSID="${arg#*=}" ;;
	--pass-iot=*)
		IOT_PASS="${arg#*=}"
		IOT_PASS_SET=1
		;;
	--channel-2g=*) CHANNEL_2G="${arg#*=}" ;;
	--channel-5g=*) CHANNEL_5G="${arg#*=}" ;;
	--htmode-2g=*) HTMODE_2G="${arg#*=}" ;;
	--htmode-5g=*) HTMODE_5G="${arg#*=}" ;;
	--mobility-domain=*) MOBILITY_DOMAIN="${arg#*=}" ;;
	--no-roaming) ROAMING=0 ;;
	--random-passwords) RANDOM_PASS=1 ;;
	--dry-run) DRY_RUN=1 ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# === Валидация ===
# Проверяется длина в байтах: busybox ash считает ${#} байтами, а SSID
# ограничен 32 байтами, пароль WPA — 63. Само значение не печатается,
# иначе пароль попал бы в журнал установки
validate_len() {
	local val="$1" min="$2" max="$3" what="$4"
	if [ "${#val}" -lt "$min" ] || [ "${#val}" -gt "$max" ]; then
		echo "[X] $what: длина ${#val} байт, допустимо $min-$max"
		exit 1
	fi
	return 0
}

validate_channel() {
	local val="$1" what="$2"
	case "$val" in
	"") return 0 ;;
	auto) return 0 ;;
	*[!0-9]*)
		echo "[X] $what: ожидалось число или auto, получено '$val'"
		exit 1
		;;
	esac
	if [ "$val" -lt 1 ] || [ "$val" -gt 233 ]; then
		echo "[X] $what: недопустимый номер канала $val"
		exit 1
	fi
	return 0
}

validate_htmode() {
	case "$1" in
	"") return 0 ;;
	HT20 | HT40 | VHT20 | VHT40 | VHT80 | VHT160 | HE20 | HE40 | HE80 | HE160 | EHT20 | EHT40 | EHT80 | EHT160 | EHT320) return 0 ;;
	*)
		echo "[X] $2: недопустимый htmode '$1'"
		exit 1
		;;
	esac
}

random_password() {
	# 24 hex-символа из /proc/sys/kernel/random/uuid (od в OpenWrt нет,
	# uuid есть всегда — его же использует установщик для HWID)
	tr -d '-' </proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-24
}

validate_len "$HOME_SSID" 1 32 "SSID основной сети"
validate_len "$GUEST_SSID" 1 32 "SSID гостевой сети"
validate_len "$IOT_SSID" 1 32 "SSID IoT-сети"

validate_channel "$CHANNEL_2G" "--channel-2g"
validate_channel "$CHANNEL_5G" "--channel-5g"
validate_htmode "$HTMODE_2G" "--htmode-2g"
validate_htmode "$HTMODE_5G" "--htmode-5g"

# === Проверка существования гостевой сети ===
GUEST_EXISTS=0
if uci -q get network.guest >/dev/null 2>&1; then
	GUEST_EXISTS=1
	echo "[+] Обнаружена гостевая сеть (network.guest), будет настроен Guest Wi-Fi"
else
	echo "[-] Гостевая сеть не найдена (network.guest отсутствует), Guest Wi-Fi не будет настроен"
fi

# === Проверка существования IoT сети ===
IOT_EXISTS=0
if uci -q get network.iot >/dev/null 2>&1; then
	IOT_EXISTS=1
	echo "[+] Обнаружена IoT сеть (network.iot), будет настроен IoT Wi-Fi"
else
	echo "[-] IoT сеть не найдена (network.iot отсутствует), IoT Wi-Fi не будет настроен"
fi

# === Пароли ===
# --random-passwords: случайные пароли вместо опубликованных в репозитории
if [ "$RANDOM_PASS" = 1 ]; then
	[ "$HOME_PASS_SET" = 1 ] || HOME_PASS=$(random_password)
	[ "$GUEST_PASS_SET" = 1 ] || GUEST_PASS=$(random_password)
	[ "$IOT_PASS_SET" = 1 ] || IOT_PASS=$(random_password)
fi

validate_len "$HOME_PASS" 8 63 "пароль основной сети"
validate_len "$GUEST_PASS" 8 63 "пароль гостевой сети"
validate_len "$IOT_PASS" 8 63 "пароль IoT-сети"

if [ "$GUEST_EXISTS" = 1 ] && [ "$HOME_PASS" = "$GUEST_PASS" ]; then
	echo "[X] Пароли основной и гостевой сети совпадают — гостевая сеть перестаёт быть отдельной"
	exit 1
fi
if [ "$IOT_EXISTS" = 1 ] && { [ "$IOT_PASS" = "$HOME_PASS" ] || [ "$IOT_PASS" = "$GUEST_PASS" ]; }; then
	echo "[X] Пароль IoT-сети совпадает с паролем другой сети"
	exit 1
fi

# === UCI с поддержкой --dry-run ===
uset() {
	if [ "$DRY_RUN" = 1 ]; then
		case "$1" in
		*.key) printf '  uci set %s=<скрыт>\n' "$1" ;;
		*) printf '  uci set %s=%s\n' "$1" "$2" ;;
		esac
	else
		uci set "$1=$2"
	fi
}

udel() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  uci delete %s\n' "$1"
	else
		uci -q delete "$1"
	fi
}

ucommit() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  uci commit %s\n' "$1"
	else
		uci commit "$1"
	fi
}

# === Очистка ===
echo "Очистка существующих Wi-Fi интерфейсов..."
if [ "$DRY_RUN" = 1 ]; then
	echo "  uci delete wireless.@wifi-iface[0] (все секции wifi-iface)"
else
	while uci -q delete wireless.@wifi-iface[0]; do :; done
fi
ucommit wireless

# === Возможности радио ===
# phy, у которого в списке частот есть канал этого диапазона
phy_for_band() {
	local band="$1" phy
	command -v iw >/dev/null 2>&1 || return 1
	for phy in /sys/class/ieee80211/phy*; do
		[ -d "$phy" ] || continue
		phy=${phy##*/}
		if [ "$band" = "2g" ]; then
			iw phy "$phy" info 2>/dev/null | grep -q '2412\.0 MHz' && {
				echo "$phy"
				return 0
			}
		else
			iw phy "$phy" info 2>/dev/null | grep -qE '\* 5[0-9]{3}\.0 MHz' && {
				echo "$phy"
				return 0
			}
		fi
	done
	return 1
}

# htmode по возможностям железа: 2.4 — HE20 при 802.11ax, иначе HT20;
# 5 — HE80, если ax нет — VHT80, иначе HT40. Ошибку угадывания не глушим:
# htmode, который радио не умеет, hostapd не применит, и AP не поднимется
detect_htmode() {
	local band="$1" phy
	phy=$(phy_for_band "$band") || return 1
	if iw phy "$phy" info 2>/dev/null | grep -q 'HE Iftypes'; then
		[ "$band" = "2g" ] && echo "HE20" || echo "HE80"
		return 0
	fi
	if [ "$band" != "2g" ] && iw phy "$phy" info 2>/dev/null | grep -q 'VHT Capabilities'; then
		echo "VHT80"
		return 0
	fi
	[ "$band" = "2g" ] && echo "HT20" || echo "HT40"
}

# === Настройка radio (с явным band + htmode) ===
echo "Настройка radio устройств..."

RADIOS=$(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^=]*\)=wifi-device.*/\1/p')
[ -n "$RADIOS" ] || {
	echo "[X] В /etc/config/wireless нет ни одного wifi-device"
	exit 1
}

for RADIO in $RADIOS; do
	echo "→ Настраиваем $RADIO"

	uset "wireless.${RADIO}.country" 'RU'
	uset "wireless.${RADIO}.country_ie" '1'
	uset "wireless.${RADIO}.legacy_rates" '0'
	uset "wireless.${RADIO}.cell_density" '2'
	uset "wireless.${RADIO}.wmm" '1'
	uset "wireless.${RADIO}.disassoc_low_ack" '0'
	# PMF — опция wifi-iface: netifd читает её только там (config_add_int в
	# /lib/netifd/hostapd.sh), на wifi-device значение игнорировалось
	udel "wireless.${RADIO}.ieee80211w"

	# === ЯВНОЕ ЗАДАНИЕ band + htmode ===
	if uci get wireless.${RADIO}.band >/dev/null 2>&1; then
		CURRENT_BAND=$(uci get wireless.${RADIO}.band)
	else
		# Определяем по имени radio (стандартно radio0=2.4, radio1=5).
		# Это догадка: при нескольких радио с нестандартными именами
		# проверьте band в /etc/config/wireless
		case "$RADIO" in
		*0* | *2g*)
			CURRENT_BAND="2g"
			;;
		*)
			CURRENT_BAND="5g"
			;;
		esac
		echo "  [!] band не задан — предполагаем $CURRENT_BAND по имени $RADIO"
	fi

	uset "wireless.${RADIO}.band" "$CURRENT_BAND"

	# Канал: auto по умолчанию, иначе значение из --channel-2g/--channel-5g
	if [ "$CURRENT_BAND" = "2g" ]; then
		uset "wireless.${RADIO}.channel" "${CHANNEL_2G:-auto}"
		htmode="$HTMODE_2G"
	else
		uset "wireless.${RADIO}.channel" "${CHANNEL_5G:-auto}"
		htmode="$HTMODE_5G"
	fi
	[ -n "$htmode" ] || htmode=$(detect_htmode "$CURRENT_BAND")
	if [ -n "$htmode" ]; then
		uset "wireless.${RADIO}.htmode" "$htmode"
		echo "  → htmode: $htmode"
	else
		echo "  [!] Возможности радио определить не удалось (нет iw?) — htmode оставлен как есть"
	fi

done

ucommit wireless

# === Интерфейсы ===
# add_iface <имя секции> <radio> <сеть> <ssid> <пароль> <изоляция клиентов>
add_iface() {
	local name="$1" radio="$2" net="$3" ssid="$4" key="$5" isolate="$6"

	uset "wireless.$name" "wifi-iface"
	uset "wireless.$name.device" "$radio"
	uset "wireless.$name.mode" "ap"
	uset "wireless.$name.network" "$net"
	uset "wireless.$name.ssid" "$ssid"
	uset "wireless.$name.encryption" "sae-mixed"
	uset "wireless.$name.key" "$key"
	uset "wireless.$name.isolate" "$isolate"
	uset "wireless.$name.bridge_isolate" "$isolate"
	uset "wireless.$name.disabled" "0"
	# PMF: 1 — обязателен только для WPA3-клиентов (sae_require_mfp у hostapd),
	# WPA2-клиенты подключаются без него
	uset "wireless.$name.ieee80211w" "1"

	# Роуминг между радио: 802.11k (отчёты о соседях → rrm_neighbor_report) и
	# 802.11r (быстрый переход, FT-SAE для sae-mixed). 802.11v (bss_transition)
	# не включаем: wpad-basic-mbedtls из OpenWrt 25.12 отвергает этот пункт
	# конфигурации («unknown configuration item 'bss_transition'») и AP не поднимается.
	# mobility_domain одинаков на всех точках одной сети — иначе FT не работает
	if [ "$ROAMING" = 1 ]; then
		uset "wireless.$name.ieee80211k" "1"
		uset "wireless.$name.ieee80211r" "1"
		uset "wireless.$name.mobility_domain" "$MOBILITY_DOMAIN"
		uset "wireless.$name.ft_over_ds" "1"
	fi
}

# === Home Wi-Fi ===
echo "Настройка Home Wi-Fi..."
for RADIO in $RADIOS; do
	add_iface "home_${RADIO}" "$RADIO" "lan" "$HOME_SSID" "$HOME_PASS" "0"
done
ucommit wireless

# === Guest Wi-Fi (только если существует гостевая сеть) ===
if [ "$GUEST_EXISTS" -eq 1 ]; then
	echo "Настройка Guest Wi-Fi..."
	for RADIO in $RADIOS; do
		add_iface "guest_${RADIO}" "$RADIO" "guest" "$GUEST_SSID" "$GUEST_PASS" "1"
	done
	ucommit wireless
else
	echo "Пропускаем настройку Guest Wi-Fi (нет сети guest в /etc/config/network)"
fi

# === IoT Wi-Fi (только если существует IoT сеть) ===
if [ "$IOT_EXISTS" -eq 1 ]; then
	echo "Настройка IoT Wi-Fi..."
	for RADIO in $RADIOS; do
		add_iface "iot_${RADIO}" "$RADIO" "iot" "$IOT_SSID" "$IOT_PASS" "1"
	done
	ucommit wireless
else
	echo "Пропускаем настройку IoT Wi-Fi (нет сети iot в /etc/config/network)"
fi

# === Проверка результата ===
# «Настроено» без проверки — это обещание, а не факт. Канал 0 означает, что
# hostapd ещё выбирает канал (ACS) или не поднялся вовсе, поэтому ждём канал
wifi_channels() {
	local radio ifname info
	for radio in $RADIOS; do
		local ifnames=""
		if command -v jsonfilter >/dev/null 2>&1; then
			ifnames=$(ubus call network.wireless status 2>/dev/null |
				jsonfilter -e "@.$radio.interfaces[*].ifname" 2>/dev/null)
		fi
		for ifname in $ifnames; do
			info=$(iwinfo "$ifname" info 2>/dev/null)
			[ -n "$info" ] || continue
			printf '%s %s %s %s\n' "$ifname" \
				"$(printf '%s\n' "$info" | sed -n 's/.*ESSID: *"\(.*\)"/\1/p')" \
				"$(printf '%s\n' "$info" | sed -n 's/.*Channel: *\([0-9]*\).*/\1/p')" \
				"$(printf '%s\n' "$info" | sed -n 's/.*HT Mode: *\([A-Za-z0-9]*\).*/\1/p')"
		done
	done
}

verify_wifi() {
	local waited=0 limit="${WIFI_VERIFY_TIMEOUT:-90}" pending unset_ifaces
	while [ "$waited" -lt "$limit" ]; do
		pending=0
		unset_ifaces=0
		while read -r ifname essid channel htmode; do
			[ -n "$ifname" ] || continue
			[ "${channel:-0}" = "0" ] && pending=1
		done <<EOF
$(wifi_channels)
EOF
		[ "$pending" = 0 ] && break
		sleep 5
		waited=$((waited + 5))
	done

	local ok=0
	while read -r ifname essid channel htmode; do
		[ -n "$ifname" ] || continue
		if [ "${channel:-0}" = "0" ]; then
			echo "  [X] $ifname: канал не выбран (hostapd не поднялся или идёт ACS)"
			continue
		fi
		echo "  ✓ $ifname: $essid, канал $channel, ${htmode:-?}"
		ok=$((ok + 1))
	done <<EOF
$(wifi_channels)
EOF
	[ "$ok" -gt 0 ]
}

if [ "$DRY_RUN" = 1 ]; then
	echo
	echo "[dry-run] изменения не применены. Применить: без --dry-run"
	exit 0
fi

echo "  → Применяем изменения..."
wifi reload
sleep 3

if command -v iwinfo >/dev/null 2>&1 && verify_wifi; then
	log "Wi-Fi применён: интерфейсы поднялись"
else
	log "[X] Точки доступа не поднялись — смотрите logread | grep hostapd"
	exit 1
fi

echo "=== Wi-Fi успешно настроен ==="
echo "Home  : $HOME_SSID"
if [ $GUEST_EXISTS -eq 1 ]; then
	echo "Guest : $GUEST_SSID"
else
	echo "Guest : не настроен"
fi
if [ $IOT_EXISTS -eq 1 ]; then
	echo "IoT   : $IOT_SSID"
else
	echo "IoT   : не настроен"
fi
echo "Режим : WPA2 + WPA3 (sae-mixed) | PMF на интерфейсе (ieee80211w=1)"
if [ "$ROAMING" = 1 ]; then
	echo "Роуминг: 802.11k + 802.11r (FT, mobility_domain $MOBILITY_DOMAIN); 802.11v не поддерживается wpad-basic"
else
	echo "Роуминг: отключён (--no-roaming)"
fi

# Сгенерированные пароли нужно сохранить: в UCI они есть, но больше нигде
if [ "$RANDOM_PASS" = 1 ]; then
	echo
	echo "Пароли (сгенерированы, сохраните):"
	[ "$HOME_PASS_SET" = 1 ] || echo "  Home : $HOME_PASS"
	[ "$GUEST_PASS_SET" = 1 ] || [ "$GUEST_EXISTS" -eq 0 ] || echo "  Guest: $GUEST_PASS"
	[ "$IOT_PASS_SET" = 1 ] || [ "$IOT_EXISTS" -eq 0 ] || echo "  IoT  : $IOT_PASS"
fi