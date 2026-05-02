#!/bin/sh
# OpenWrt 25.12.x — создаёт гостевую Wi-Fi сеть (Direct/Bypass Xray)
# Трафик гостей идёт напрямую в WAN, минуя Xray/TProxy

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (Direct/Bypass Xray) для OpenWrt 25.12 ==="
[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

# Динамический IP роутера
MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

# Параметры (можно переопределить аргументами)
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_NET="guest"
GUEST_CIDR="192.168.2.1/24"
DNS_SERVERS="1.1.1.1 8.8.8.8"

# Валидация
[ "${#GUEST_SSID}" -lt 1 ] || [ "${#GUEST_SSID}" -gt 32 ] && { echo "❌ SSID: 1-32 символа"; exit 1; }
[ "${#GUEST_PASS}" -lt 8 ] || [ "${#GUEST_PASS}" -gt 63 ] && { echo "❌ Пароль: 8-63 символа"; exit 1; }

# Безопасный пароль из файла
get_password() {
    [ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}
[ "$#" -gt 0 ] && echo "⚠️ Пароль в аргументах виден в ps. Безопаснее: /etc/guest-wifi-pass"

# 1. Сетевой интерфейс (CIDR, без device для WiFi)
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

# 2. Wi-Fi интерфейс — используем "uci add" для надёжности
RADIO=$(uci show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
[ -z "$RADIO" ] && { echo "❌ Wi-Fi радио не найдено"; exit 1; }

WIFI_PASS=$(get_password)

# Проверяем, есть ли уже гостевой wifi-iface по network=guest
EXISTING_WIFI=$(uci show wireless | grep "\.network='${GUEST_NET}'$" | cut -d. -f1-2 | head -1)

if [ -z "$EXISTING_WIFI" ]; then
    uci add wireless wifi-iface
    # Перезапрашиваем, чтобы получить точный идентификатор только что созданной секции
    WIFI_SEC=$(uci show wireless | grep "\.network='${GUEST_NET}'$" | cut -d. -f1-2 | head -1)
    
    uci set "${WIFI_SEC}.device"="$RADIO"
    uci set "${WIFI_SEC}.network"="$GUEST_NET"
    uci set "${WIFI_SEC}.mode"='ap'
    uci set "${WIFI_SEC}.ssid"="$GUEST_SSID"
    uci set "${WIFI_SEC}.encryption"='psk2+ccmp'
    uci set "${WIFI_SEC}.key"="$WIFI_PASS"
    uci set "${WIFI_SEC}.isolate"='1'
    uci set "${WIFI_SEC}.disabled"='0'
    echo "✅ Wi-Fi точка создана (секция: ${WIFI_SEC#wireless.}, SSID: $GUEST_SSID)"
else
    uci set "${EXISTING_WIFI}.ssid"="$GUEST_SSID"
    uci set "${EXISTING_WIFI}.key"="$WIFI_PASS"
    uci set "${EXISTING_WIFI}.disabled"='0'
    echo "ℹ️ Wi-Fi интерфейс обновлён (секция: ${EXISTING_WIFI#wireless.})"
fi
uci commit wireless

# 3. DHCP для гостевой сети
uci add_list dhcp.@dnsmasq[0].interface="$GUEST_NET" 2>/dev/null
uci commit dhcp
echo "✅ DHCP разрешён для '$GUEST_NET'"

# 4. Firewall (изоляция + выход в WAN) — ОДИН commit в конце
# Зона
FW_ZONE=$(uci show firewall | grep "\.name='${GUEST_NET}'$" | cut -d. -f1-2 | head -1)
if [ -z "$FW_ZONE" ]; then
    uci add firewall zone
    FW_ZONE=$(uci show firewall | grep "\.name='${GUEST_NET}'$" | cut -d. -f1-2 | head -1)
fi
uci set "${FW_ZONE}.network"="$GUEST_NET"
uci set "${FW_ZONE}.input"='REJECT'
uci set "${FW_ZONE}.output"='ACCEPT'
uci set "${FW_ZONE}.forward"='REJECT'
uci set "${FW_ZONE}.masq"='1'

# Forwarding в WAN
FW_FWD=$(uci show firewall | grep "\.src='${GUEST_NET}'.*\.dest='wan'$" | cut -d. -f1-2 | head -1)
if [ -z "$FW_FWD" ]; then
    uci add firewall forwarding
    FW_FWD=$(uci show firewall | grep "\.src='${GUEST_NET}'.*\.dest='wan'$" | cut -d. -f1-2 | head -1)
fi
uci set "${FW_FWD}.src"="$GUEST_NET"
uci set "${FW_FWD}.dest"='wan'

# Блокировка LAN
FW_RULE_LAN=$(uci show firewall | grep "\.name='Block-${GUEST_NET}-to-lan'" | cut -d. -f1-2 | head -1)
if [ -z "$FW_RULE_LAN" ]; then
    uci add firewall rule
    FW_RULE_LAN=$(uci show firewall | grep "\.name='Block-${GUEST_NET}-to-lan'" | cut -d. -f1-2 | head -1)
fi
uci set "${FW_RULE_LAN}.src"="$GUEST_NET"
uci set "${FW_RULE_LAN}.dest"='lan'
uci set "${FW_RULE_LAN}.target"='REJECT'

# Блокировка админки роутера (ПРОБЕЛЫ, не запятые!)
FW_RULE_RTR=$(uci show firewall | grep "\.name='Block-${GUEST_NET}-to-router'" | cut -d. -f1-2 | head -1)
if [ -z "$FW_RULE_RTR" ]; then
    uci add firewall rule
    FW_RULE_RTR=$(uci show firewall | grep "\.name='Block-${GUEST_NET}-to-router'" | cut -d. -f1-2 | head -1)
fi
uci set "${FW_RULE_RTR}.src"="$GUEST_NET"
uci set "${FW_RULE_RTR}.dest_ip"="$MAIN_LAN_IP"
uci set "${FW_RULE_RTR}.dest_port"='22 53 80 443'  # ← ПРОБЕЛЫ!
uci set "${FW_RULE_RTR}.proto"='tcp udp'
uci set "${FW_RULE_RTR}.target"='REJECT'

# 🔥 ОДИН commit для firewall — в конце
uci commit firewall
echo "✅ Firewall настроен"

# 5. Применяем изменения (правильный порядок для OpenWrt 25.12)
echo "🔄 Применяю конфигурацию..."

# Сначала wifi reload, потом ifup
wifi reload
sleep 4

# ifup как страховка
ifup "$GUEST_NET" 2>/dev/null || true
sleep 2

# Ждём появления интерфейса
for i in $(seq 1 10); do
    ip link show "$GUEST_NET" >/dev/null 2>&1 && break
    sleep 1
done

# Обновляем nftables для байпаса гостевого трафика
[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh 2>/dev/null && echo "✅ nftables обновлены"

# Финальная проверка
echo ""
echo "=== Результат ==="
if ip link show "$GUEST_NET" >/dev/null 2>&1; then
    echo "✅ Интерфейс '$GUEST_NET' активен"
    ip -4 addr show "$GUEST_NET" | grep "inet " | sed 's/^/   /'
else
    echo "⚠️ Интерфейс не поднялся. Проверь: 'logread | grep -E guest|wifi'"
fi

if command -v iwinfo >/dev/null 2>&1 && iwinfo | grep -q "$GUEST_SSID"; then
    echo "✅ Wi-Fi '$GUEST_SSID' активен"
    iwinfo | grep -A3 "$GUEST_SSID" | sed 's/^/   /'
fi

echo ""
echo "📶 SSID: $GUEST_SSID"
echo "🔑 Пароль: (скрыт)"
echo "🌐 Шлюз: ${GUEST_CIDR%%/*}"
echo "🛡️ Доступ к $MAIN_LAN_IP заблокирован"
echo "🚀 Трафик идёт НАПРЯМУЮ, минуя Xray/TProxy"
echo "📝 Лог: $LOG"
echo ""
echo "🧪 Проверка:"
echo "  Подключись к $GUEST_SSID и выполни:"
echo "  curl ifconfig.me  # должен показать твой реальный внешний IP"