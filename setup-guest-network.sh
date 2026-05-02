#!/bin/sh
# OpenWrt 25.12.x — Guest Wi-Fi (MT7981, dual-radio, SQM)
# Трафик гостей → WAN напрямую, минуя Xray/TProxy

LOG="/tmp/guest-setup.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой Wi-Fi сети ==="

[ "$(id -u)" != "0" ] && {
	echo "❌ Требуются права root"
	exit 1
}

# === Значения по умолчанию ===
GUEST_NET="guest"
GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"
DL_LIMIT="20000" # Kbps
UL_LIMIT="10000" # Kbps
GUEST_IP="192.168.2.1/24"

# === Парсер аргументов ===
for arg in "$@"; do
	case $arg in
	--ssid=*) GUEST_SSID="${arg#*=}" ;;
	--pass=*) GUEST_PASS="${arg#*=}" ;;
	--dl=*) DL_LIMIT="${arg#*=}" ;;
	--ul=*) UL_LIMIT="${arg#*=}" ;;
	*)
		echo "⚠️ Неизвестный аргумент: $arg"
		;;
	esac
done

# === Валидация ===
[ "${#GUEST_SSID}" -lt 1 ] || [ "${#GUEST_SSID}" -gt 32 ] && {
	echo "❌ SSID: 1-32 символа"
	exit 1
}
[ "${#GUEST_PASS}" -lt 8 ] || [ "${#GUEST_PASS}" -gt 63 ] && {
	echo "❌ Пароль: 8-63 символа"
	exit 1
}

case "$DL_LIMIT" in '' | *[!0-9]*)
	echo "❌ DL_LIMIT должен быть числом"
	exit 1
	;;
esac
case "$UL_LIMIT" in '' | *[!0-9]*)
	echo "❌ UL_LIMIT должен быть числом"
	exit 1
	;;
esac

MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

# === Функция получения пароля ===
get_password() {
	[ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ] &&
		head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}

WIFI_PASS=$(get_password)

# === 1. Network ===
echo "Настройка сети..."
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

# === 2. Wireless (две частоты) ===
echo "Настройка Wi-Fi..."

for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci -q delete wireless.${GUEST_NET}_${RADIO}
	uci set wireless.${GUEST_NET}_${RADIO}="wifi-iface"
	uci set wireless.${GUEST_NET}_${RADIO}.device="$RADIO"
	uci set wireless.${GUEST_NET}_${RADIO}.mode="ap"
	uci set wireless.${GUEST_NET}_${RADIO}.network="$GUEST_NET"
	uci set wireless.${GUEST_NET}_${RADIO}.ssid="$GUEST_SSID"
	uci set wireless.${GUEST_NET}_${RADIO}.encryption="psk2+ccmp"
	uci set wireless.${GUEST_NET}_${RADIO}.key="$WIFI_PASS"
	uci set wireless.${GUEST_NET}_${RADIO}.isolate="1"
	uci set wireless.${GUEST_NET}_${RADIO}.bridge_isolate="1"
	uci set wireless.${GUEST_NET}_${RADIO}.disabled="0"
done
uci commit wireless

# === 3. DHCP ===
echo "Настройка DHCP..."
uci -q delete dhcp.$GUEST_NET
uci set dhcp.$GUEST_NET="dhcp"
uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
uci set dhcp.$GUEST_NET.start="100"
uci set dhcp.$GUEST_NET.limit="150"
uci set dhcp.$GUEST_NET.leasetime="1h"
uci set dhcp.$GUEST_NET.force="1"
uci commit dhcp

# === 4. Firewall ===
echo "Настройка Firewall..."

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

uci -q delete firewall.${GUEST_NET}_lan
uci set firewall.${GUEST_NET}_lan="rule"
uci set firewall.${GUEST_NET}_lan.name="Block-${GUEST_NET}-to-lan"
uci set firewall.${GUEST_NET}_lan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_lan.dest="lan"
uci set firewall.${GUEST_NET}_lan.target="REJECT"

uci -q delete firewall.${GUEST_NET}_rtr
uci set firewall.${GUEST_NET}_rtr="rule"
uci set firewall.${GUEST_NET}_rtr.name="Block-${GUEST_NET}-to-router"
uci set firewall.${GUEST_NET}_rtr.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_rtr.dest="lan"
uci set firewall.${GUEST_NET}_rtr.target="REJECT"

uci -q delete firewall.${GUEST_NET}_dns
uci set firewall.${GUEST_NET}_dns="rule"
uci set firewall.${GUEST_NET}_dns.name="Allow-${GUEST_NET}-DNS"
uci set firewall.${GUEST_NET}_dns.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dns.dest_port="53"
uci set firewall.${GUEST_NET}_dns.proto="tcp udp"
uci set firewall.${GUEST_NET}_dns.target="ACCEPT"

uci -q delete firewall.${GUEST_NET}_dhcp
uci set firewall.${GUEST_NET}_dhcp="rule"
uci set firewall.${GUEST_NET}_dhcp.name="Allow-${GUEST_NET}-DHCP"
uci set firewall.${GUEST_NET}_dhcp.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dhcp.dest_port="67"
uci set firewall.${GUEST_NET}_dhcp.proto="udp"
uci set firewall.${GUEST_NET}_dhcp.target="ACCEPT"

uci commit firewall

# === 4.1 SQM (только конфиг) ===
echo "Настройка SQM..."

# Проверка наличия tc
if ! command -v tc >/dev/null; then
	echo "⚠️ tc отсутствует — SQM работать не сможет"
fi

# Проверка наличия sqm-scripts
if [ ! -x /usr/lib/sqm/run.sh ]; then
	echo "Устанавливаем sqm-scripts через apk..."
	if command -v apk >/dev/null; then
		apk add sqm-scripts || echo "⚠️ Не удалось установить sqm-scripts"
	elif [ -x /sbin/apk ]; then
		/sbin/apk add sqm-scripts || echo "⚠️ Не удалось установить sqm-scripts"
	else
		echo "❌ apk не найден — установка SQM невозможна"
	fi
fi

uci -q delete sqm.$GUEST_NET
uci set sqm.$GUEST_NET="queue"
uci set sqm.$GUEST_NET.interface="br-${GUEST_NET}"
uci set sqm.$GUEST_NET.download="$DL_LIMIT"
uci set sqm.$GUEST_NET.upload="$UL_LIMIT"
uci set sqm.$GUEST_NET.qdisc="cake"
uci set sqm.$GUEST_NET.script="piece_of_cake.qos"
uci set sqm.$GUEST_NET.enabled="1"
uci commit sqm

echo "✅ Конфигурация завершена"

# === 5. Применение ===
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
ip link show "br-${GUEST_NET}" >/dev/null 2>&1 || echo "⚠️ Мост не поднялся"

# Теперь можно запускать SQM
if [ -x /etc/init.d/sqm ]; then
	/etc/init.d/sqm restart
fi

echo ""
echo "=== Результат ==="
ip link show "br-${GUEST_NET}" >/dev/null 2>&1 && echo "✅ Мост br-${GUEST_NET} активен" || echo "⚠️ Мост не найден"

if command -v iwinfo >/dev/null; then
	iwinfo | grep -q "$GUEST_SSID" && echo "✅ Wi-Fi $GUEST_SSID активен"
fi

echo ""
echo "📶 SSID     : $GUEST_SSID"
echo "🔑 Пароль   : (в /etc/guest-wifi-pass или аргументы)"
echo "🚀 Лимиты   : DL=${DL_LIMIT} Kbps, UL=${UL_LIMIT} Kbps"
echo "🛡️  Изоляция: Wi-Fi + firewall"
echo "📝 Лог      : $LOG"
