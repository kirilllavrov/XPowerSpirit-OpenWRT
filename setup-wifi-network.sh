#!/bin/sh
# OpenWrt 25.12.x — Home Wi-Fi (через Xray) + Guest Wi-Fi (через WAN)
# MT7981 dual-radio, firewall4, SQM only for guest

LOG="/tmp/guest-setup.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка Wi-Fi сетей ==="

[ "$(id -u)" != "0" ] && {
	echo "❌ Требуются права root"
	exit 1
}

# === Значения по умолчанию ===
HOME_SSID="Home-WiFi"
HOME_PASS="HomeSecure123!"

GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"
DL_GUEST="20000"
UL_GUEST="10000"

GUEST_NET="guest"
GUEST_IP="192.168.2.1/24"

# === Парсер аргументов ===
for arg in "$@"; do
	case $arg in
	--ssid=*) HOME_SSID="${arg#*=}" ;;
	--pass=*) HOME_PASS="${arg#*=}" ;;
	--ssid-guest=*) GUEST_SSID="${arg#*=}" ;;
	--pass-guest=*) GUEST_PASS="${arg#*=}" ;;
	--dl-guest=*) DL_GUEST="${arg#*=}" ;;
	--ul-guest=*) UL_GUEST="${arg#*=}" ;;
	*)
		echo "⚠️ Неизвестный аргумент: $arg"
		;;
	esac
done

# === Валидация ===
validate_len() {
	local val="$1"
	local min="$2"
	local max="$3"
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

case "$DL_GUEST" in '' | *[!0-9]*)
	echo "❌ DL_GUEST должен быть числом"
	exit 1
	;;
esac
case "$UL_GUEST" in '' | *[!0-9]*)
	echo "❌ UL_GUEST должен быть числом"
	exit 1
	;;
esac

MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

# === 1. Wi-Fi: Home (через Xray, на br-lan) ===
echo "Настройка Home Wi-Fi (через Xray)..."

for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci -q delete wireless.home_${RADIO}
	uci set wireless.home_${RADIO}="wifi-iface"
	uci set wireless.home_${RADIO}.device="$RADIO"
	uci set wireless.home_${RADIO}.mode="ap"
	uci set wireless.home_${RADIO}.network="lan" # ← ВАЖНО: через Xray
	uci set wireless.home_${RADIO}.ssid="$HOME_SSID"
	uci set wireless.home_${RADIO}.encryption="psk2+ccmp"
	uci set wireless.home_${RADIO}.key="$HOME_PASS"
	uci set wireless.home_${RADIO}.isolate="1"
	uci set wireless.home_${RADIO}.bridge_isolate="1"
	uci set wireless.home_${RADIO}.disabled="0"
done
uci commit wireless

# === 2. Wi-Fi: Guest (на br-guest) ===
echo "Настройка Guest Wi-Fi..."

for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci -q delete wireless.${GUEST_NET}_${RADIO}
	uci set wireless.${GUEST_NET}_${RADIO}="wifi-iface"
	uci set wireless.${GUEST_NET}_${RADIO}.device="$RADIO"
	uci set wireless.${GUEST_NET}_${RADIO}.mode="ap"
	uci set wireless.${GUEST_NET}_${RADIO}.network="$GUEST_NET"
	uci set wireless.${GUEST_NET}_${RADIO}.ssid="$GUEST_SSID"
	uci set wireless.${GUEST_NET}_${RADIO}.encryption="psk2+ccmp"
	uci set wireless.${GUEST_NET}_${RADIO}.key="$GUEST_PASS"
	uci set wireless.${GUEST_NET}_${RADIO}.isolate="1"
	uci set wireless.${GUEST_NET}_${RADIO}.bridge_isolate="1"
	uci set wireless.${GUEST_NET}_${RADIO}.disabled="0"
done
uci commit wireless

# === 3. DHCP Guest ===
echo "Настройка DHCP Guest..."
uci -q delete dhcp.$GUEST_NET
uci set dhcp.$GUEST_NET="dhcp"
uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
uci set dhcp.$GUEST_NET.start="100"
uci set dhcp.$GUEST_NET.limit="150"
uci set dhcp.$GUEST_NET.leasetime="1h"
uci set dhcp.$GUEST_NET.force="1"
uci commit dhcp

# === 4. Firewall Guest ===
echo "Настройка Firewall Guest..."

uci -q delete firewall.$GUEST_NET
uci set firewall.$GUEST_NET="zone"
uci set firewall.$GUEST_NET.name="$GUEST_NET"
uci set firewall.$GUEST_NET.network="$GUEST_NET"
uci set firewall.$GUEST_NET.input="REJECT"
uci set firewall.$GUEST_NET.output="ACCEPT"
uci set firewall.$GUEST_NET.forward="REJECT"
uci set firewall.$GUEST_NET.masq="1"
uci set firewall.$GUEST_NET.mtu_fix="1"

uci -q delete firewall.${GUEST_NET}_wan
uci set firewall.${GUEST_NET}_wan="forwarding"
uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_wan.dest="wan"

uci -q delete firewall.${GUEST_NET}_rtr
uci set firewall.${GUEST_NET}_rtr="rule"
uci set firewall.${GUEST_NET}_rtr.name="Block-${GUEST_NET}-to-router"
uci set firewall.${GUEST_NET}_rtr.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_rtr.dest_ip="$MAIN_LAN_IP/32"
uci set firewall.${GUEST_NET}_rtr.target="REJECT"

uci commit firewall

# === 5. SQM только для Guest ===
echo "Настройка SQM для Guest..."

if ! command -v tc >/dev/null; then
	echo "⚠️ tc отсутствует — SQM работать не сможет"
fi

if [ ! -x /usr/lib/sqm/run.sh ]; then
	echo "Устанавливаем sqm-scripts через apk..."
	if command -v apk >/dev/null; then
		apk add sqm-scripts || echo "⚠️ Не удалось установить sqm-scripts"
	fi
fi

uci -q delete sqm.$GUEST_NET
uci set sqm.$GUEST_NET="queue"
uci set sqm.$GUEST_NET.interface="br-${GUEST_NET}"
uci set sqm.$GUEST_NET.download="$DL_GUEST"
uci set sqm.$GUEST_NET.upload="$UL_GUEST"
uci set sqm.$GUEST_NET.qdisc="cake"
uci set sqm.$GUEST_NET.script="piece_of_cake.qos"
uci set sqm.$GUEST_NET.enabled="1"
uci commit sqm

echo "🔄 Применяем изменения..."
service network restart
sleep 2
wifi reload
sleep 2
service dnsmasq restart
service firewall restart

# Ждём появления br-guest
for i in $(seq 1 10); do
	ip link show "br-${GUEST_NET}" >/dev/null 2>&1 && break
	sleep 1
done

if [ -x /etc/init.d/sqm ]; then
	/etc/init.d/sqm restart
fi

echo "=== Готово ==="
echo "Home Wi-Fi (через Xray): $HOME_SSID"
echo "Guest Wi-Fi (через WAN): $GUEST_SSID"
echo "Лимиты Guest: DL=${DL_GUEST} UL=${UL_GUEST}"
