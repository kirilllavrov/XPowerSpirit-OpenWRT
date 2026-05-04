#!/bin/sh
# OpenWrt — Настройка только Wi-Fi (Home + Guest)

LOG="/tmp/guest-wifi.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка Wi-Fi интерфейсов ==="

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

validate_len "$HOME_SSID" 1 32 && { echo "❌ SSID Home: 1-32 символа"; exit 1; }
validate_len "$GUEST_SSID" 1 32 && { echo "❌ SSID Guest: 1-32 символа"; exit 1; }
validate_len "$HOME_PASS" 8 63 && { echo "❌ Пароль Home: 8-63 символа"; exit 1; }
validate_len "$GUEST_PASS" 8 63 && { echo "❌ Пароль Guest: 8-63 символа"; exit 1; }

# === Home Wi-Fi ===
echo "Настройка Home Wi-Fi..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
    uci -q delete wireless.home_${RADIO}
    uci set wireless.home_${RADIO}="wifi-iface"
    uci set wireless.home_${RADIO}.device="$RADIO"
    uci set wireless.home_${RADIO}.mode="ap"
    uci set wireless.home_${RADIO}.network="lan"
    uci set wireless.home_${RADIO}.ssid="$HOME_SSID"
    uci set wireless.home_${RADIO}.encryption="psk2+ccmp"
    uci set wireless.home_${RADIO}.key="$HOME_PASS"
    uci set wireless.home_${RADIO}.isolate="0"
    uci set wireless.home_${RADIO}.bridge_isolate="0"
    uci set wireless.home_${RADIO}.disabled="0"
done
uci commit wireless

# === Guest Wi-Fi ===
echo "Настройка Guest Wi-Fi..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
    uci -q delete wireless.guest_${RADIO}
    uci set wireless.guest_${RADIO}="wifi-iface"
    uci set wireless.guest_${RADIO}.device="$RADIO"
    uci set wireless.guest_${RADIO}.mode="ap"
    uci set wireless.guest_${RADIO}.network="guest"
    uci set wireless.guest_${RADIO}.ssid="$GUEST_SSID"
    uci set wireless.guest_${RADIO}.encryption="psk2+ccmp"
    uci set wireless.guest_${RADIO}.key="$GUEST_PASS"
    uci set wireless.guest_${RADIO}.isolate="1"
    uci set wireless.guest_${RADIO}.bridge_isolate="1"
    uci set wireless.guest_${RADIO}.disabled="0"
done
uci commit wireless

echo "🔄 Применяем Wi-Fi настройки..."
wifi reload
sleep 2

echo "=== Wi-Fi настроен ==="
echo "Home  : $HOME_SSID"
echo "Guest : $GUEST_SSID"