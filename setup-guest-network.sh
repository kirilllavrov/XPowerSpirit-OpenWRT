#!/bin/sh
# OpenWrt 25.12.x — Guest Wi-Fi на двух радио (2.4 + 5 GHz)
# Трафик гостей → WAN напрямую, минуя Xray/TProxy

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой сети (2.4 + 5 GHz) ==="

[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

# === Переменные ===
MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

GUEST_NET="guest"
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_IP="192.168.2.1/24"

# Валидация
[ "${#GUEST_SSID}" -lt 1 ] || [ "${#GUEST_SSID}" -gt 32 ] && { echo "❌ SSID: 1-32 символа"; exit 1; }
[ "${#GUEST_PASS}" -lt 8 ] || [ "${#GUEST_PASS}" -gt 63 ] && { echo "❌ Пароль: 8-63 символа"; exit 1; }

get_password() {
    [ -f "/etc/guest-wifi-pass" ] && [ -r "/etc/guest-wifi-pass" ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}

[ "$#" -gt 0 ] && echo "⚠️ Пароль в аргументах виден в ps. Рекомендуется: /etc/guest-wifi-pass"

# === 1. Network (bridge + interface) — ОДИН мост для обоих радио ===
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
uci set network.$GUEST_NET.dns="1.1.1.1 8.8.8.8"
uci set network.$GUEST_NET.force_link="1"
uci commit network

# === 2. Wireless — ДВА интерфейса (radio0 + radio1) ===
echo "Настройка Wi-Fi (2.4 + 5 GHz)..."

WIFI_PASS=$(get_password)

# Функция создания wifi-iface для заданного радио
setup_wifi_iface() {
    local radio="$1"
    local suffix="$2"  # "" для первого, "-5g" для второго
    
    uci -q delete wireless.${GUEST_NET}_wifi${suffix}
    uci set wireless.${GUEST_NET}_wifi${suffix}="wifi-iface"
    uci set wireless.${GUEST_NET}_wifi${suffix}.device="$radio"
    uci set wireless.${GUEST_NET}_wifi${suffix}.mode="ap"
    uci set wireless.${GUEST_NET}_wifi${suffix}.network="$GUEST_NET"  # ← один и тот же network!
    uci set wireless.${GUEST_NET}_wifi${suffix}.ssid="$GUEST_SSID"
    uci set wireless.${GUEST_NET}_wifi${suffix}.encryption="psk2+ccmp"
    uci set wireless.${GUEST_NET}_wifi${suffix}.key="$WIFI_PASS"
    uci set wireless.${GUEST_NET}_wifi${suffix}.isolate="1"
    uci set wireless.${GUEST_NET}_wifi${suffix}.bridge_isolate="1"
    uci set wireless.${GUEST_NET}_wifi${suffix}.disabled="0"
}

# Находим доступные радио
RADIO0=$(uci -q show wireless | grep -m1 "=wifi-device" | cut -d. -f2)
RADIO1=$(uci -q show wireless | grep "=wifi-device" | tail -1 | cut -d. -f2)

# Создаём интерфейс для первого радио (обычно 2.4 GHz)
if [ -n "$RADIO0" ]; then
    setup_wifi_iface "$RADIO0" ""
    echo "✅ Wi-Fi настроен на $RADIO0"
fi

# Создаём интерфейс для второго радио (обычно 5 GHz), если есть
if [ -n "$RADIO1" ] && [ "$RADIO1" != "$RADIO0" ]; then
    setup_wifi_iface "$RADIO1" "-5g"
    echo "✅ Wi-Fi настроен на $RADIO1"
fi

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

# Зона guest
uci -q delete firewall.$GUEST_NET
uci set firewall.$GUEST_NET="zone"
uci set firewall.$GUEST_NET.name="$GUEST_NET"
uci set firewall.$GUEST_NET.network="$GUEST_NET"
uci set firewall.$GUEST_NET.input="REJECT"
uci set firewall.$GUEST_NET.output="ACCEPT"
uci set firewall.$GUEST_NET.forward="REJECT"
uci set firewall.$GUEST_NET.masq="1"
uci set firewall.$GUEST_NET.mtu_fix="1"

# Forwarding guest → wan
uci -q delete firewall.${GUEST_NET}_wan
uci set firewall.${GUEST_NET}_wan="forwarding"
uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_wan.dest="wan"

# Блокировка LAN
uci -q delete firewall.${GUEST_NET}_lan
uci set firewall.${GUEST_NET}_lan="rule"
uci set firewall.${GUEST_NET}_lan.name="Block-${GUEST_NET}-to-lan"
uci set firewall.${GUEST_NET}_lan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_lan.dest="lan"
uci set firewall.${GUEST_NET}_lan.target="REJECT"

# Блокировка доступа к роутеру
uci -q delete firewall.${GUEST_NET}_rtr
uci set firewall.${GUEST_NET}_rtr="rule"
uci set firewall.${GUEST_NET}_rtr.name="Block-${GUEST_NET}-to-router"
uci set firewall.${GUEST_NET}_rtr.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_rtr.dest_ip="$MAIN_LAN_IP/32"
uci set firewall.${GUEST_NET}_rtr.target="REJECT"

# Разрешаем DHCP и DNS
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

echo "✅ Конфигурация завершена"

# === 5. Применение ===
echo "🔄 Применяем изменения..."
service network restart
sleep 3
wifi reload
sleep 3
service dnsmasq restart
service firewall restart

# Обновление nftables для байпаса гостевого трафика
[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh && echo "✅ nftables обновлены"

# === Финальная проверка ===
echo ""
echo "=== Результат ==="
ip link show "br-${GUEST_NET}" >/dev/null 2>&1 && echo "✅ Мост br-${GUEST_NET} активен" || echo "⚠️ Мост не найден"

if command -v iwinfo >/dev/null; then
    COUNT=$(iwinfo | grep -c "$GUEST_SSID")
    [ "$COUNT" -ge 1 ] && echo "✅ Wi-Fi '$GUEST_SSID' активен на $COUNT радио" || echo "⚠️ Wi-Fi не виден"
fi

echo ""
echo "📶 SSID     : $GUEST_SSID (2.4 + 5 GHz)"
echo "🔑 Пароль   : (в /etc/guest-wifi-pass или аргумент)"
echo "🌐 IP       : ${GUEST_IP%%/*}"
echo "🛡️  Изоляция: включена (между клиентами и радио)"
echo "🚀 Трафик   : напрямую в WAN (минуя Xray)"
echo "📝 Лог      : $LOG"

echo ""
echo "🧪 Тест:"
echo "   curl ifconfig.me          # должен показать реальный внешний IP"
echo "   ping 8.8.8.8              # интернет"
echo "   ping $MAIN_LAN_IP         # должен быть заблокирован"