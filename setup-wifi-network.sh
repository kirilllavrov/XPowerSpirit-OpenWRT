#!/bin/sh
# OpenWrt — Настройка Wi-Fi (Home + Guest) для России

LOG="/tmp/setup-wifi.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка Wi-Fi (Россия, WPA2+WPA3, PMF) ==="

[ "$(id -u)" != "0" ] && {
	echo "[X] Требуются права root"
	exit 1
}

# === Генерация случайного пароля (A-Za-z0-9, 8 символов) ===
gen_password() {
	# Читаем 12 байт из /dev/urandom, кодируем в base64, берём символы A-Za-z0-9
	# base64 даёт A-Z, a-z, 0-9, +, /, = — отфильтровываем лишнее
	head -c 12 /dev/urandom 2>/dev/null | base64 | tr -d '+/=' | cut -c1-8
}

# === Значения по умолчанию ===
HOME_SSID="Home-WiFi"
HOME_PASS=""
GUEST_SSID="Guest-WiFi"
GUEST_PASS=""

# Флаги, чтобы понять, какие пароли были заданы явно
HOME_PASS_SET=0
GUEST_PASS_SET=0

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--ssid=*) HOME_SSID="${arg#*=}" ;;
	--pass=*) HOME_PASS="${arg#*=}"; HOME_PASS_SET=1 ;;
	--ssid-guest=*) GUEST_SSID="${arg#*=}" ;;
	--pass-guest=*) GUEST_PASS="${arg#*=}"; GUEST_PASS_SET=1 ;;
	esac
done

# Генерация паролей, если не заданы
if [ $HOME_PASS_SET -eq 0 ]; then
	HOME_PASS=$(gen_password)
	echo "[+] Сгенерирован пароль для Home: $HOME_PASS"
fi

if [ $GUEST_PASS_SET -eq 0 ]; then
	GUEST_PASS=$(gen_password)
	echo "[+] Сгенерирован пароль для Guest: $GUEST_PASS"
fi

# === Валидация ===
validate_len() {
	local val="$1" min="$2" max="$3"
	[ "${#val}" -lt "$min" ] || [ "${#val}" -gt "$max" ] && {
		echo "[X] Ошибка длины: $val (должно быть $min-$max символов)"
		exit 1
	}
}

validate_len "$HOME_SSID" 1 32
validate_len "$GUEST_SSID" 1 32
validate_len "$HOME_PASS" 8 63
validate_len "$GUEST_PASS" 8 63

# === Проверка наличия guest сети в /etc/config/network ===
if ! uci -q get network.guest >/dev/null 2>&1; then
	echo "[!] Сеть 'guest' не найдена, создаём..."
	uci set network.guest=interface
	uci set network.guest.proto='static'
	uci set network.guest.ipaddr='192.168.10.1'
	uci set network.guest.netmask='255.255.255.0'
	uci set network.guest.device='br-guest'
	
	# Настройка DHCP для guest
	uci set dhcp.guest=dhcp
	uci set dhcp.guest.interface='guest'
	uci set dhcp.guest.start='100'
	uci set dhcp.guest.limit='150'
	uci set dhcp.guest.leasetime='12h'
	
	uci commit network
	uci commit dhcp
	echo "[+] Гостевая сеть создана"
fi

# === Очистка ===
echo "Очистка существующих Wi-Fi интерфейсов..."
while uci -q delete wireless.@wifi-iface[0]; do :; done
uci commit wireless

# === Получение списка radio устройств ===
RADIOS=$(uci show wireless | grep '=wifi-device' | sed -n 's/^wireless\.\([^=]*\)=.*/\1/p')

for RADIO in $RADIOS; do
	echo "→ Настраиваем $RADIO"

	# Основные настройки radio
	uci set wireless.${RADIO}.country='RU'
	uci set wireless.${RADIO}.country_ie='1'
	uci set wireless.${RADIO}.channel='auto'
	uci set wireless.${RADIO}.legacy_rates='0'
	uci set wireless.${RADIO}.cell_density='2'
	uci set wireless.${RADIO}.ieee80211w='1'
	uci set wireless.${RADIO}.wmm='1'
	uci set wireless.${RADIO}.disassoc_low_ack='0'

	# === Определение band и htmode ===
	CURRENT_BAND=$(uci -q get wireless.${RADIO}.band)
	
	if [ -z "$CURRENT_BAND" ]; then
		# Определяем по имени radio (стандартно radio0=2.4, radio1=5)
		case "$RADIO" in
			*0*|*2g*) CURRENT_BAND="2g" ;;
			*) CURRENT_BAND="5g" ;;
		esac
	fi

	uci set wireless.${RADIO}.band="$CURRENT_BAND"

	if [ "$CURRENT_BAND" = "2g" ]; then
		uci set wireless.${RADIO}.htmode='HT20'
	else
		uci set wireless.${RADIO}.htmode='HE80'
	fi

	# === Home Wi-Fi ===
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

	# === Guest Wi-Fi ===
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
done

uci commit wireless

echo "  → Применяем изменения..."
wifi reload
sleep 3

echo "=== Wi-Fi успешно настроен ==="
echo "Home  : $HOME_SSID | Пароль: $HOME_PASS"
echo "Guest : $GUEST_SSID | Пароль: $GUEST_PASS"
echo "Режим : WPA2 + WPA3 (sae-mixed) | PMF Optional"