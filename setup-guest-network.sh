#!/bin/sh
# OpenWrt 25.12.x — Guest Wi-Fi на двух радио (один SSID)

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой Wi-Fi на двух радио (один SSID) ==="

[ "$(id -u)" != "0" ] && { echo "❌ Требуются права root"; exit 1; }

# === Настройки ===
GUEST_NET="guest"
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_IP="192.168.2.1/24"

MAIN_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1)
[ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.1.1"

get_password() {
    [ -f "/etc/guest-wifi-pass" ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS"
}

[ "$#" -gt 0 ] && echo "⚠️ Пароль передаётся в аргументах (виден в ps)"

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
uci set network.$GUEST_NET.dns="1.1.1.1 8.8.8.8"
uci set network.$GUEST_NET.force_link="1"
uci commit network

# === 2. Wireless — на всех радио ===
echo "Настройка Wi-Fi на двух радио..."

WIFI_PASS=$(get_password)

# Удаляем старые гостевые интерфейсы
uci -q delete wireless.${GUEST_NET}_2g
uci -q delete wireless.${GUEST_NET}_5g

# Получаем все доступные радио
RADIO_LIST=$(uci show wireless | grep "=wifi-device" | cut -d. -f2)

for RADIO in $RADIO_LIST; do
    SUFFIX=$(echo $RADIO | sed 's/radio//')
    IFACE_NAME="${GUEST_NET}_${SUFFIX}"
    
    uci set wireless.$IFACE_NAME="wifi-iface"
    uci set wireless.$IFACE_NAME.device="$RADIO"
    uci set wireless.$IFACE_NAME.mode="ap"
    uci set wireless.$IFACE_NAME.network="$GUEST_NET"
    uci set wireless.$IFACE_NAME.ssid="$GUEST_SSID"
    uci set wireless.$IFACE_NAME.encryption="psk2+ccmp"
    uci set wireless.$IFACE_NAME.key="$WIFI_PASS"
    uci set wireless.$IFACE_NAME.isolate="1"
    uci set wireless.$IFACE_NAME.bridge_isolate="1"
    uci set wireless.$IFACE_NAME.disabled="0"
    
    echo "✅ Добавлена гостевая сеть на $RADIO ($IFACE_NAME)"
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

# === 4. Firewall (один раз) ===
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

# Блокировка LAN
uci -q delete firewall.${GUEST_NET}_lan
uci set firewall.${GUEST_NET}_lan="rule"
uci set firewall.${GUEST_NET}_lan.name="Block-${GUEST_NET}-to-lan"
uci set firewall.${GUEST_NET}_lan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_lan.dest="lan"
uci set firewall.${GUEST_NET}_lan.target="REJECT"

# Блокировка роутера
uci -q delete firewall.${GUEST_NET}_rtr
uci set firewall.${GUEST_NET}_rtr="rule"
uci set firewall.${GUEST_NET}_rtr.name="Block-${GUEST_NET}-to-router"
uci set firewall.${GUEST_NET}_rtr.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_rtr.dest_ip="$MAIN_LAN_IP/32"
uci set firewall.${GUEST_NET}_rtr.target="REJECT"

# Разрешаем DNS + DHCP
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

# === Применение ===
echo "🔄 Применяем конфигурацию..."
service network restart
sleep 3
wifi reload
sleep 3
service dnsmasq restart
service firewall restart

[ -x /usr/share/xray/update-nft.sh ] && /usr/share/xray/update-nft.sh && echo "✅ nftables обновлены"

echo ""
echo "=== Успешно настроено ==="
echo "📶 SSID: $GUEST_SSID (на всех диапазонах)"
echo "🌐 IP:   ${GUEST_IP%%/*}"
echo "🛡️  Изоляция клиентов: включена"
echo ""
echo "Проверь: iwinfo | grep -A5 \"$GUEST_SSID\""