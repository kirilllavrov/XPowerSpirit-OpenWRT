#!/bin/sh
# OpenWrt 25.12.x — создаёт гостевую Wi-Fi сеть (Direct/Bypass Xray)
# Использует "uci add" для надёжной регистрации интерфейса в hostapd

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (Direct/Bypass Xray) для OpenWrt 25.12 ==="
[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_NET="guest"
GUEST_CIDR="192.168.2.1/24"
DNS_SERVERS="1.1.1.1 8.8.8.8"

# Валидация
[ ${#GUEST_SSID} -lt 1 ] || [ ${#GUEST_SSID} -gt 32 ] && { echo "❌ SSID: 1-32 символа"; exit 1; }
[ ${#GUEST_PASS} -lt 8 ] || [ ${#GUEST_PASS} -gt 63 ] && { echo "❌ Пароль: 8-63 символа"; exit 1; }

get_password() {
    [ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}
[ $# -gt 0 ] && echo "⚠️ Пароль в аргументах виден в ps. Безопаснее: /etc/guest-wifi-pass"

# 1. Сетевой интерфейс (CIDR, без device)
if ! uci get network."$GUEST_NET" >/dev/null 2>&1; then
    uci set network."$GUEST_NET"=interface
    uci set network."$GUEST_NET".proto='static'
    uci set network."$GUEST_NET".ipaddr="$GUEST_CIDR"
    uci set network."$GUEST_NET".dns="$DNS_SERVERS"
    uci set network."$GUEST_NET".disabled='0'
    uci commit network
    echo "✅ Сеть '$GUEST_NET' создана ($GUEST_CIDR)"
else
    uci set network."$GUEST_NET".disabled='0'
    uci commit network
    echo "ℹ️ Сеть '$GUEST_NET' уже существует"
fi

# 2. Wi-Fi интерфейс — ИСПОЛЬЗУЕМ "uci add" для надёжности
RADIO=$(uci show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
[ -z "$RADIO" ] && { echo "❌ Wi-Fi радио не найдено"; exit 1; }

WIFI_PASS=$(get_password)

# Проверяем, есть ли уже гостевой wifi-iface
EXISTING=$(uci show wireless | grep -o "wireless\.[^=]*=wifi-iface" | while read -r line; do
    sec=$(echo "$line" | cut -d= -f1 | cut -d. -f2)
    net=$(uci get wireless."$sec".network 2>/dev/null)
    [ "$net" = "$GUEST_NET" ] && echo "$sec" && break
done)

if [ -z "$EXISTING" ]; then
    # Создаём НОВЫЙ wifi-iface через "uci add"
    uci add wireless wifi-iface
    WIFI_SEC="wireless.@wifi-iface[-1]"  # авто-имя секции
    
    uci set "${WIFI_SEC}.device"="$RADIO"
    uci set "${WIFI_SEC}.network"="$GUEST_NET"
    uci set "${WIFI_SEC}.mode"='ap'
    uci set "${WIFI_SEC}.ssid"="$GUEST_SSID"
    uci set "${WIFI_SEC}.encryption"='psk2+ccmp'
    uci set "${WIFI_SEC}.key"="$WIFI_PASS"
    uci set "${WIFI_SEC}.isolate"='1'
    uci set "${WIFI_SEC}.disabled"='0'
    uci commit wireless
    echo "✅ Wi-Fi точка создана (секция: ${WIFI_SEC#wireless.}, SSID: $GUEST_SSID)"
else
    # Обновляем существующий
    uci set "wireless.$EXISTING".ssid="$GUEST_SSID"
    uci set "wireless.$EXISTING".key="$WIFI_PASS"
    uci set "wireless.$EXISTING".disabled='0'
    uci commit wireless
    echo "ℹ️ Wi-Fi интерфейс обновлён (секция: $EXISTING)"
fi

# 3. DHCP
uci add_list dhcp.@dnsmasq[0].interface="$GUEST_NET" 2>/dev/null
uci commit dhcp
echo "✅ DHCP разрешён для '$GUEST_NET'"

# 4. Firewall
FW_ZONE=$(uci show firewall | grep -o "@zone\[[0-9]*\]" | grep "name='$GUEST_NET'" | head -1 | cut -d= -f1)
[ -z "$FW_ZONE" ] && { uci add firewall zone; FW_ZONE=firewall.@zone[-1]; }
uci set "${FW_ZONE}.name"="$GUEST_NET"
uci set "${FW_ZONE}.network"="$GUEST_NET"
uci set "${FW_ZONE}.input"='REJECT'
uci set "${FW_ZONE}.output"='ACCEPT'
uci set "${FW_ZONE}.forward"='REJECT'
uci set "${FW_ZONE}.masq"='1'

FW_FWD=$(uci show firewall | grep -o "@forwarding\[[0-9]*\]" | grep "src='$GUEST_NET'" | head -1 | cut -d= -f1)
[ -z "$FW_FWD" ] && { uci add firewall forwarding; FW_FWD=firewall.@forwarding[-1]; }
uci set "${FW_FWD}.src"="$GUEST_NET"
uci set "${FW_FWD}.dest"='wan'

FW_RULE_LAN=$(uci show firewall | grep -o "@rule\[[0-9]*\]" | grep "name='Block-$GUEST_NET-to-lan'" | head -1 | cut -d= -f1)
[ -z "$FW_RULE_LAN" ] && { uci add firewall rule; FW_RULE_LAN=firewall.@rule[-1]; }
uci set "${FW_RULE_LAN}.name"="Block-$GUEST_NET-to-lan"
uci set "${FW_RULE_LAN}.src"="$GUEST_NET"
uci set "${FW_RULE_LAN}.dest"='lan'
uci set "${FW_RULE_LAN}.target"='REJECT'

FW_RULE_RTR=$(uci show firewall | grep -o "@rule\[[0-9]*\]" | grep "name='Block-$GUEST_NET-to-router'" | head -1 | cut -d= -f1)
[ -z "$FW_RULE_RTR" ] && { uci add firewall rule; FW_RULE_RTR=firewall.@rule[-1]; }
uci set "${FW_RULE_RTR}.name"="Block-$GUEST_NET-to-router"
uci set "${FW_RULE_RTR}.src"="$GUEST_NET"
uci set "${FW_RULE_RTR}.dest_ip"="$MAIN_LAN_IP"
uci set "${FW_RULE_RTR}.dest_port"='22 53 80 443'  # ← ПРОБЕЛЫ!
uci set "${FW_RULE_RTR}.proto"='tcp udp'
uci set "${FW_RULE_RTR}.target"='REJECT'

uci commit firewall
echo "✅ Firewall настроен"

# 5. Применяем изменения — ПРАВИЛЬНЫЙ ПОРЯДОК
echo "🔄 Применяю конфигурацию..."
uci commit network
uci commit wireless
uci commit dhcp
uci commit firewall

# 🔥 Сначала wifi reload, потом ifup
wifi reload
sleep 4

# Явно поднимаем гостевой интерфейс (если он не поднялся автоматически)
if ! ip link show "$GUEST_NET" >/dev/null 2>&1; then
    echo "⚠️ Интерфейс не поднялся автоматически, пробуем 'wifi up'..."
    # Находим имя секции для wifi up
    WIFI_SEC_NAME=$(uci show wireless | grep -o "wireless\.[^=]*=wifi-iface" | while read -r line; do
        sec=$(echo "$line" | cut -d= -f1 | cut -d. -f2)
        net=$(uci get wireless."$sec".network 2>/dev/null)
        [ "$net" = "$GUEST_NET" ] && echo "$sec" && break
    done)
    [ -n "$WIFI_SEC_NAME" ] && wifi up "$WIFI_SEC_NAME" 2>/dev/null || true
    sleep 2
fi

# Ждём появления интерфейса
for i in $(seq 1 10); do
    ip link show "$GUEST_NET" >/dev/null 2>&1 && break
    sleep 1
done

# Обновляем nftables
[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh 2>/dev/null && echo "✅ nftables обновлены"

# Финальная проверка
echo ""
echo "=== Результат ==="
if ip link show "$GUEST_NET" >/dev/null 2>&1; then
    echo "✅ Интерфейс '$GUEST_NET' активен"
    ip -4 addr show "$GUEST_NET" | grep "inet " | sed 's/^/   /'
else
    echo "⚠️ Интерфейс не поднялся. Проверь:"
    echo "   - uci show wireless | grep guest"
    echo "   - logread | grep -E 'hostapd|wpa'"
    echo "   - wifi status"
fi

if command -v iwinfo >/dev/null 2>&1 && iwinfo | grep -q "$GUEST_SSID"; then
    echo "✅ Wi-Fi '$GUEST_SSID' активен"
    iwinfo | grep -A3 "$GUEST_SSID" | sed 's/^/   /'
else
    echo "⚠️ Wi-Fi '$GUEST_SSID' не виден. Проверь 'iwinfo' и 'logread'"
fi

echo ""
echo "📶 SSID: $GUEST_SSID"
echo "🛡️ Доступ к $MAIN_LAN_IP заблокирован"
echo "🚀 Трафик идёт НАПРЯМУЮ, минуя Xray/TProxy"
echo "📝 Лог: $LOG"