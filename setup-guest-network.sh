#!/bin/sh
# OpenWrt 25.12.x
# setup-guest-network.sh — создаёт гостевую Wi-Fi сеть с прямым доступом в интернет (минуя Xray)

# Отключаем set -e для более контролируемой обработки ошибок
# set -e удалён для лучшего контроля

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (Direct/Bypass Xray) ==="
[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

# Получаем IP роутера вместо хардкода
MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

# Параметры с проверкой входных данных
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_NET="guest"
GUEST_IP="192.168.2.1"
DNS_SERVERS="${3:-1.1.1.1 8.8.8.8}"

# Валидация SSID и пароля
if [ ${#GUEST_SSID} -lt 1 ] || [ ${#GUEST_SSID} -gt 32 ]; then
    echo "❌ SSID должен быть от 1 до 32 символов"
    exit 1
fi

if [ ${#GUEST_PASS} -lt 8 ] || [ ${#GUEST_PASS} -gt 63 ]; then
    echo "❌ Пароль должен быть от 8 до 63 символов"
    exit 1
fi

# Функция безопасного получения пароля из файла
get_password() {
    if [ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ]; then
        head -n1 /etc/guest-wifi-pass
    else
        echo "$GUEST_PASS"
    fi
}

# Предупреждение о безопасности
if [ $# -gt 0 ]; then
    echo "⚠️  Пароль передан как аргумент (виден в ps aux). Рекомендуется:"
    echo "   echo 'ваш_пароль' > /etc/guest-wifi-pass && chmod 600 /etc/guest-wifi-pass"
fi

# 1. Сетевой интерфейс (идемпотентно)
if ! uci get network."$GUEST_NET" >/dev/null 2>&1; then
    uci set network."$GUEST_NET"=interface
    uci set network."$GUEST_NET".proto='static'
    uci set network."$GUEST_NET".ipaddr="$GUEST_IP"
    uci set network."$GUEST_NET".netmask='255.255.255.0'
    uci set network."$GUEST_NET".dns="$DNS_SERVERS"
    uci set network."$GUEST_NET".disabled='0'
    uci commit network
    echo "✅ Сеть '$GUEST_NET' создана ($GUEST_IP/24)"
else
    echo "ℹ️  Сеть '$GUEST_NET' уже существует"
    # Обновляем DNS на всякий случай
    uci set network."$GUEST_NET".dns="$DNS_SERVERS"
    uci set network."$GUEST_NET".disabled='0'
    uci commit network
fi

# 2. Wi-Fi интерфейс
RADIO=$(uci show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
if [ -z "$RADIO" ]; then
    echo "❌ Wi-Fi радио не найдено"
    exit 1
fi

WIFI_PASSWORD=$(get_password)

if ! uci get wireless."${GUEST_NET}_wifi" >/dev/null 2>&1; then
    uci set wireless."${GUEST_NET}_wifi"=wifi-iface
    uci set wireless."${GUEST_NET}_wifi".device="$RADIO"
    uci set wireless."${GUEST_NET}_wifi".network="$GUEST_NET"
    uci set wireless."${GUEST_NET}_wifi".mode='ap'
    uci set wireless."${GUEST_NET}_wifi".ssid="$GUEST_SSID"
    uci set wireless."${GUEST_NET}_wifi".encryption='psk2+ccmp'
    uci set wireless."${GUEST_NET}_wifi".key="$WIFI_PASSWORD"
    uci set wireless."${GUEST_NET}_wifi".isolate='1'
    uci set wireless."${GUEST_NET}_wifi".disabled='0'
    uci commit wireless
    echo "✅ Wi-Fi точка доступа создана (SSID: $GUEST_SSID)"
else
    echo "ℹ️  Wi-Fi интерфейс уже настроен"
    uci set wireless."${GUEST_NET}_wifi".ssid="$GUEST_SSID"
    uci set wireless."${GUEST_NET}_wifi".key="$WIFI_PASSWORD"
    uci set wireless."${GUEST_NET}_wifi".encryption='psk2+ccmp'
    uci set wireless."${GUEST_NET}_wifi".isolate='1'
    uci set wireless."${GUEST_NET}_wifi".disabled='0'
    uci commit wireless
fi

# 3. DHCP для гостевой сети
if uci get dhcp.@dnsmasq[0].interface >/dev/null 2>&1; then
    if ! uci get dhcp.@dnsmasq[0].interface | grep -q "$GUEST_NET"; then
        uci add_list dhcp.@dnsmasq[0].interface="$GUEST_NET"
        uci commit dhcp
        echo "✅ DHCP разрешён для '$GUEST_NET'"
    fi
else
    echo "⚠️  dnsmasq секция не найдена, DHCP не настроен"
fi

# 4. Firewall (изоляция + выход в WAN)
if ! uci show firewall | grep -q "name='$GUEST_NET'"; then
    uci add firewall zone
    uci set firewall.@zone[-1].name="$GUEST_NET"
    uci set firewall.@zone[-1].network="$GUEST_NET"
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
    echo "✅ Создана firewall зона '$GUEST_NET'"
fi

# Разрешение в WAN
if ! uci show firewall | grep -q "src='$GUEST_NET'.*dest='wan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="$GUEST_NET"
    uci set firewall.@forwarding[-1].dest='wan'
    echo "✅ Добавлен forwarding $GUEST_NET → WAN"
fi

# Блокировка доступа к LAN
if ! uci show firewall | grep -q "name='Block-$GUEST_NET-to-lan'"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-$GUEST_NET-to-lan"
    uci set firewall.@rule[-1].src="$GUEST_NET"
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].target='REJECT'
    echo "✅ Добавлено правило блокировки доступа к LAN"
fi

# Блокировка доступа к админке роутера
if ! uci show firewall | grep -q "name='Block-$GUEST_NET-to-router'"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-$GUEST_NET-to-router"
    uci set firewall.@rule[-1].src="$GUEST_NET"
    uci set firewall.@rule[-1].dest_ip="$MAIN_LAN_IP"
    uci set firewall.@rule[-1].dest_port='22,53,80,443'
    uci set firewall.@rule[-1].proto='tcp udp'
    uci set firewall.@rule[-1].target='REJECT'
    echo "✅ Добавлено правило блокировки доступа к роутеру ($MAIN_LAN_IP)"
fi

uci commit firewall
echo "✅ Firewall настроен"

# 5. Применяем изменения
echo "🔄 Применяю конфигурацию..."
ifup "$GUEST_NET" 2>/dev/null || true
sleep 2

# Явно поднимаем интерфейс
ifup "$GUEST_NET" 2>/dev/null || {
    echo "⚠️  Не удалось поднять интерфейс через ifup"
    ifconfig "$GUEST_NET" "$GUEST_IP" netmask 255.255.255.0 up 2>/dev/null || true
}

# Ждём появления интерфейса
for i in $(seq 1 10); do
    if ip link show "$GUEST_NET" >/dev/null 2>&1; then
        echo "✅ Интерфейс поднят через ${i}0 сек"
        break
    fi
    sleep 1
done

wifi reload || true
sleep 2
service dnsmasq restart || true
service firewall restart || true

# Обновляем nftables
if [ -x /usr/share/xray/update-nft.sh ]; then
    /usr/share/xray/update-nft.sh 2>/dev/null
    echo "✅ nftables обновлены для bypass Xray"
fi

# Финальная проверка
echo ""
echo "=== Результат ==="
if ip link show "$GUEST_NET" >/dev/null 2>&1; then
    echo "✅ Интерфейс '$GUEST_NET' активен"
    ip -4 addr show "$GUEST_NET" | grep "inet " | sed 's/^/   /'
else
    echo "⚠️  Интерфейс '$GUEST_NET' не поднялся"
    echo "   Попробуй: 'ip link show' и 'wifi status'"
fi

if command -v iwinfo >/dev/null 2>&1; then
    if iwinfo | grep -q "$GUEST_SSID"; then
        echo "✅ Wi-Fi '$GUEST_SSID' активен"
    else
        echo "⚠️  Wi-Fi '$GUEST_SSID' не виден"
    fi
fi

echo ""
echo "📶 SSID: $GUEST_SSID"
echo "🔑 Пароль: (скрыт)"
echo "🌐 Шлюз: $GUEST_IP"
echo "🛡️  Доступ к роутеру ($MAIN_LAN_IP) заблокирован"
echo "🚀 Трафик идёт напрямую, минуя Xray/TProxy"
echo "📝 Лог: $LOG"