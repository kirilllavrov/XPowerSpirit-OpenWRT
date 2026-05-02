#!/bin/sh
# setup-guest-network.sh — создаёт гостевую Wi-Fi сеть с прямым доступом в интернет (минуя Xray)
set -e
LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (Direct/Bypass Xray) ==="
[ "$(id -u)" != "0" ] && { echo "Требуются права root"; exit 1; }

# Параметры (можно переопределить аргументами: ./setup-guest-network.sh "MyGuest" "Pass12345")
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_NET="guest"
GUEST_IP="192.168.2.1"

# 1. Сетевой интерфейс
if ! uci get network."$GUEST_NET" >/dev/null 2>&1; then
    uci set network."$GUEST_NET"=interface
    uci set network."$GUEST_NET".proto='static'
    uci set network."$GUEST_NET".ipaddr="$GUEST_IP"
    uci set network."$GUEST_NET".netmask='255.255.255.0'
    uci set network."$GUEST_NET".dns='1.1.1.1 8.8.8.8'
    uci commit network
    echo "✅ Сеть '$GUEST_NET' создана ($GUEST_IP/24)"
else
    echo "ℹ️ Сеть '$GUEST_NET' уже существует"
fi

# 2. Wi-Fi интерфейс
RADIO=$(uci show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
[ -z "$RADIO" ] && { echo "❌ Wi-Fi радио не найдено"; exit 1; }

if ! uci get wireless."${GUEST_NET}_wifi" >/dev/null 2>&1; then
    uci set wireless."${GUEST_NET}_wifi"=wifi-iface
    uci set wireless."${GUEST_NET}_wifi".device="$RADIO"
    uci set wireless."${GUEST_NET}_wifi".network="$GUEST_NET"
    uci set wireless."${GUEST_NET}_wifi".mode='ap'
    uci set wireless."${GUEST_NET}_wifi".ssid="$GUEST_SSID"
    uci set wireless."${GUEST_NET}_wifi".encryption='psk2'
    uci set wireless."${GUEST_NET}_wifi".key="$GUEST_PASS"
    uci set wireless."${GUEST_NET}_wifi".isolate='1'
    uci set wireless."${GUEST_NET}_wifi".disabled='0'
    uci commit wireless
    echo "✅ Wi-Fi точка доступа создана (SSID: $GUEST_SSID)"
else
    echo "ℹ️ Wi-Fi интерфейс уже настроен"
fi

# 3. DHCP
if ! uci get dhcp.@dnsmasq[0].interface 2>/dev/null | grep -q "$GUEST_NET"; then
    uci add_list dhcp.@dnsmasq[0].interface="$GUEST_NET"
    uci commit dhcp
    echo "✅ DHCP разрешён для '$GUEST_NET'"
fi

# 4. Firewall
if ! uci show firewall | grep -q "name='$GUEST_NET'"; then
    uci add firewall zone
    uci set firewall.@zone[-1].name="$GUEST_NET"
    uci set firewall.@zone[-1].network="$GUEST_NET"
    uci set firewall.@zone[-1].input='REJECT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='REJECT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
fi

if ! uci show firewall | grep -q "src='$GUEST_NET' dest='wan'"; then
    uci add firewall forwarding
    uci set firewall.@forwarding[-1].src="$GUEST_NET"
    uci set firewall.@forwarding[-1].dest='wan'
fi

if ! uci show firewall | grep -q "name='Block-$GUEST_NET-to-lan'"; then
    uci add firewall rule
    uci set firewall.@rule[-1].name="Block-$GUEST_NET-to-lan"
    uci set firewall.@rule[-1].src="$GUEST_NET"
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].target='REJECT'
fi
uci commit firewall
echo "✅ Firewall настроен (изоляция от LAN, выход в WAN)"

# 5. Применяем изменения
echo "🔄 Применяю конфигурацию..."
service network reload
wifi reload
service dnsmasq restart
service firewall restart
[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh 2>/dev/null || true

echo "=== Готово! ==="
echo "📶 SSID: $GUEST_SSID"
echo "🔑 Пароль: $GUEST_PASS"
echo "🌐 Шлюз: $GUEST_IP"
echo "🚀 Трафик идёт НАПРЯМУЮ, минуя Xray/TProxy"
echo "📝 Лог: $LOG"