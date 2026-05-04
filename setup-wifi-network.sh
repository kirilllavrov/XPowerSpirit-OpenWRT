#!/bin/sh
# OpenWrt — Настройка Wi-Fi (Home + Guest) для России
# WPA2 + WPA3 (sae-mixed) + Auto channel

LOG="/tmp/guest-wifi.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка Wi-Fi (Россия, WPA2+WPA3, Auto channel) ==="

[ "$(id -u)" != "0" ] && {
	echo "❌ Требуются права root"
	exit 1
}

# === Значения по умолчанию ===
HOME_SSID="Home-WiFi"
HOME_PASS="HomeSecure123!"
GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"

# === Парсер аргументов ===
for arg in "$@"; do
	case $arg in
	--ssid=*) HOME_SSID="${arg#*=}" ;;
	--pass=*) HOME_PASS="${arg#*=}" ;;
	--ssid-guest=*) GUEST_SSID="${arg#*=}" ;;
	--pass-guest=*) GUEST_PASS="${arg#*=}" ;;
	*) echo "⚠️ Неизвестный аргумент: $arg" ;;
	esac
done

# === Валидация ===
validate_len() {
	local val="$1" min="$2" max="$3"
	[ "${#val}" -lt "$min" ] || [ "${#val}" -gt "$max" ]
}

validate_len "$HOME_SSID" 1 32 && {
	echo "❌ SSID Home: 1-32 символа"
	exit 1
}
validate_len "$GUEST_SSID" 1 32 && {
	echo "❌ SSID Guest: 1-32 символа"
	exit 1
}
validate_len "$HOME_PASS" 8 63 && {
	echo "❌ Пароль Home: 8-63 символа"
	exit 1
}
validate_len "$GUEST_PASS" 8 63 && {
	echo "❌ Пароль Guest: 8-63 символа"
	exit 1
}

# === ОЧИСТКА СТАРЫХ Wi-Fi СЕТЕЙ ===
echo "Очистка существующих Wi-Fi интерфейсов..."
# Удаляем все wifi-iface (Home, Guest и другие пользовательские)
uci show wireless | grep "=wifi-iface" | cut -d. -f1,2 | while read -r section; do
	uci -q delete "$section"
done

# === Настройка радио (wifi-device) ===
echo "Настройка радио (country RU + auto channel)..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci set wireless.${RADIO}.country='RU'
	uci set wireless.${RADIO}.channel='auto'
	uci set wireless.${RADIO}.legacy_rates='0'
	uci set wireless.${RADIO}.cell_density='2'
done
uci commit wireless

# === Home Wi-Fi ===
echo "Настройка Home Wi-Fi (WPA2 + WPA3)..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci -q delete wireless.home_${RADIO}
	uci set wireless.home_${RADIO}="wifi-iface"
	uci set wireless.home_${RADIO}.device="$RADIO"
	uci set wireless.home_${RADIO}.mode="ap"
	uci set wireless.home_${RADIO}.network="lan"
	uci set wireless.home_${RADIO}.ssid="$HOME_SSID"
	uci set wireless.home_${RADIO}.encryption="sae-mixed"
	uci set wireless.home_${RADIO}.key="$HOME_PASS"
	uci set wireless.home_${RADIO}.isolate="0"
	uci set wireless.home_${RADIO}.bridge_isolate="0"
	uci set wireless.home_${RADIO}.disabled="0"

	uci set wireless.home_${RADIO}.wmm='1'
	uci set wireless.home_${RADIO}.disassoc_low_ack='0'
done
uci commit wireless

# === Guest Wi-Fi ===
echo "Настройка Guest Wi-Fi (WPA2 + WPA3)..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci -q delete wireless.guest_${RADIO}
	uci set wireless.guest_${RADIO}="wifi-iface"
	uci set wireless.guest_${RADIO}.device="$RADIO"
	uci set wireless.guest_${RADIO}.mode="ap"
	uci set wireless.guest_${RADIO}.network="guest"
	uci set wireless.guest_${RADIO}.ssid="$GUEST_SSID"
	uci set wireless.guest_${RADIO}.encryption="sae-mixed"
	uci set wireless.guest_${RADIO}.key="$GUEST_PASS"
	uci set wireless.guest_${RADIO}.isolate="1"
	uci set wireless.guest_${RADIO}.bridge_isolate="1"
	uci set wireless.guest_${RADIO}.disabled="0"

	uci set wireless.guest_${RADIO}.wmm='1'
	uci set wireless.guest_${RADIO}.disassoc_low_ack='0'
done
uci commit wireless

echo "🔄 Применяем изменения..."
wifi reload
sleep 3

echo "=== Wi-Fi успешно настроен ==="
echo "Home  : $HOME_SSID"
echo "Guest : $GUEST_SSID"
echo "Режим : WPA2 + WPA3 (sae-mixed)"
echo "Каналы: Auto | Country: RU"
