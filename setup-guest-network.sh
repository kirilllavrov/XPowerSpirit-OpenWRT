#!/bin/sh
# OpenWrt 25.12.x — Guest Wi-Fi (по официальной документации)
# Трафик гостей → WAN напрямую, минуя Xray/TProxy

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (по docs.openwrt.org) ==="
[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_NET="guest"
GUEST_IP="192.168.2.1/24"  # CIDR

# Валидация
[ "${#GUEST_SSID}" -lt 1 ] || [ "${#GUEST_SSID}" -gt 32 ] && { echo "❌ SSID: 1-32 символа"; exit 1; }
[ "${#GUEST_PASS}" -lt 8 ] || [ "${#GUEST_PASS}" -gt 63 ] && { echo "❌ Пароль: 8-63 символа"; exit 1; }

get_password() {
    [ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}
[ "$#" -gt 0 ] && echo "⚠️ Пароль в аргументах виден в ps. Безопаснее: /etc/guest-wifi-pass"

# 1. СЕТЬ: создаём bridge-устройство + интерфейс (по официальной доке)
if ! uci get network."${GUEST_NET}_dev" >/dev/null 2>&1; then
    uci set network."${GUEST_NET}_dev"="device"
    uci set network."${GUEST_NET}_dev".type="bridge"
    uci set network."${GUEST_NET}_dev".name="br-${GUEST_NET}"
    echo "✅ Создан bridge: br-${GUEST_NET}"
fi

if ! uci get network."$GUEST_NET" >/dev/null 2>&1; then
    uci set network."$GUEST_NET"="interface"
    uci set network."$GUEST_NET".proto="static"
    uci set network."$GUEST_NET".device="br-${GUEST_NET}"  # ← привязка к мосту!
    uci set network."$GUEST_NET".ipaddr="$GUEST_IP"
    uci set network."$GUEST_NET".dns="1.1.1.1 8.8.8.8"
    uci set network."$GUEST_NET".disabled=0
    echo "✅ Создан интерфейс: $GUEST_NET ($GUEST_IP)"
else
    uci set network."$GUEST_NET".disabled=0
fi
uci commit network

# 2. WIRELESS: привязываем к сети "guest"
RADIO=$(uci show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
[ -z "$RADIO" ] && { echo "❌ Wi-Fi радио не найдено"; exit 1; }

WIFI_PASS=$(get_password)

# Удаляем старое, если есть (для идемпотентности)
uci -q delete wireless."${GUEST_NET}_wifi"

uci set wireless."${GUEST_NET}_wifi"="wifi-iface"
uci set wireless."${GUEST_NET}_wifi".device="$RADIO"
uci set wireless."${GUEST_NET}_wifi".mode="ap"
uci set wireless."${GUEST_NET}_wifi".network="$GUEST_NET"  # ← ссылка на интерфейс (не на device!)
uci set wireless."${GUEST_NET}_wifi".ssid="$GUEST_SSID"
uci set wireless."${GUEST_NET}_wifi".encryption="psk2+ccmp"
uci set wireless."${GUEST_NET}_wifi".key="$WIFI_PASS"
uci set wireless."${GUEST_NET}_wifi".isolate=1  # изоляция клиентов друг от друга
uci set wireless."${GUEST_NET}_wifi".disabled=0
uci commit wireless
echo "✅ Wi-Fi точка: $GUEST_SSID"

# 3. DHCP
uci -q delete dhcp."$GUEST_NET"
uci set dhcp."$GUEST_NET"="dhcp"
uci set dhcp."$GUEST_NET".interface="$GUEST_NET"
uci set dhcp."$GUEST_NET".start=100
uci set dhcp."$GUEST_NET".limit=150
uci set dhcp."$GUEST_NET".leasetime="1h"
uci commit dhcp
echo "✅ DHCP настроен для $GUEST_NET"

# 4. FIREWALL (изоляция + выход в WAN)
# Зона
uci -q delete firewall."${GUEST_NET}"
uci set firewall."${GUEST_NET}"="zone"
uci set firewall."${GUEST_NET}".name="$GUEST_NET"
uci set firewall."${GUEST_NET}".network="$GUEST_NET"
uci set firewall."${GUEST_NET}".input="REJECT"
uci set firewall."${GUEST_NET}".output="ACCEPT"
uci set firewall."${GUEST_NET}".forward="REJECT"
uci set firewall."${GUEST_NET}".masq=1

# Forwarding в WAN
uci -q delete firewall."${GUEST_NET}_wan"
uci set firewall."${GUEST_NET}_wan"="forwarding"
uci set firewall."${GUEST_NET}_wan".src="$GUEST_NET"
uci set firewall."${GUEST_NET}_wan".dest="wan"

# Блокировка LAN
uci -q delete firewall."${GUEST_NET}_lan"
uci set firewall."${GUEST_NET}_lan"="rule"
uci set firewall."${GUEST_NET}_lan".name="Block-${GUEST_NET}-to-lan"
uci set firewall."${GUEST_NET}_lan".src="$GUEST_NET"
uci set firewall."${GUEST_NET}_lan".dest="lan"
uci set firewall."${GUEST_NET}_lan".target="REJECT"

# Блокировка роутера (ПРОБЕЛЫ, не запятые!)
uci -q delete firewall."${GUEST_NET}_rtr"
uci set firewall."${GUEST_NET}_rtr"="rule"
uci set firewall."${GUEST_NET}_rtr".name="Block-${GUEST_NET}-to-router"
uci set firewall."${GUEST_NET}_rtr".src="$GUEST_NET"
uci set firewall."${GUEST_NET}_rtr".dest_ip="$MAIN_LAN_IP"
uci set firewall."${GUEST_NET}_rtr".dest_port="22 53 80 443"  # ← ПРОБЕЛЫ!
uci set firewall."${GUEST_NET}_rtr".proto="tcp udp"
uci set firewall."${GUEST_NET}_rtr".target="REJECT"

# Разрешаем DNS/DHCP для гостей
uci -q delete firewall."${GUEST_NET}_dns"
uci set firewall."${GUEST_NET}_dns"="rule"
uci set firewall."${GUEST_NET}_dns".name="Allow-${GUEST_NET}-DNS"
uci set firewall."${GUEST_NET}_dns".src="$GUEST_NET"
uci set firewall."${GUEST_NET}_dns".dest_port="53"
uci set firewall."${GUEST_NET}_dns".proto="tcp udp"
uci set firewall."${GUEST_NET}_dns".target="ACCEPT"

uci -q delete firewall."${GUEST_NET}_dhcp"
uci set firewall."${GUEST_NET}_dhcp"="rule"
uci set firewall."${GUEST_NET}_dhcp".name="Allow-${GUEST_NET}-DHCP"
uci set firewall."${GUEST_NET}_dhcp".src="$GUEST_NET"
uci set firewall."${GUEST_NET}_dhcp".dest_port="67"
uci set firewall."${GUEST_NET}_dhcp".proto="udp"
uci set firewall."${GUEST_NET}_dhcp".target="ACCEPT"

uci commit firewall
echo "✅ Firewall настроен"

# 5. ПРИМЕНЕНИЕ (правильный порядок)
echo "🔄 Применяю конфигурацию..."
service network restart
sleep 3
wifi reload
sleep 3
service dnsmasq restart
service firewall restart

# Обновляем nftables для байпаса гостевого трафика
[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh 2>/dev/null && echo "✅ nftables обновлены"

# Финальная проверка
echo ""
echo "=== Результат ==="
if ip link show "br-${GUEST_NET}" >/dev/null 2>&1; then
    echo "✅ Мост 'br-${GUEST_NET}' активен"
    ip -4 addr show "br-${GUEST_NET}" | grep "inet " | sed 's/^/   /'
else
    echo "⚠️ Мост не поднялся. Проверь: 'logread | grep -E guest|br-guest'"
fi

if command -v iwinfo >/dev/null 2>&1 && iwinfo | grep -q "$GUEST_SSID"; then
    echo "✅ Wi-Fi '$GUEST_SSID' активен"
    iwinfo | grep -A3 "$GUEST_SSID" | sed 's/^/   /'
fi

echo ""
echo "📶 SSID: $GUEST_SSID"
echo "🔑 Пароль: (скрыт)"
echo "🌐 Шлюз: ${GUEST_IP%%/*}"
echo "🛡️ Доступ к $MAIN_LAN_IP заблокирован"
echo "🚀 Трафик идёт НАПРЯМУЮ, минуя Xray/TProxy"
echo "📝 Лог: $LOG"
echo ""
echo "🧪 Проверка:"
echo "  Подключись к $GUEST_SSID и выполни:"
echo "  curl ifconfig.me  # должен показать твой реальный внешний IP"