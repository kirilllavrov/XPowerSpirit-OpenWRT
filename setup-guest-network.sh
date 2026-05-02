#!/bin/sh
# OpenWrt — Guest Wi-Fi на двух радио (одинаковый SSID)

LOG="/tmp/guest-setup.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка гостевой Wi-Fi на двух радио ==="

[ "$(id -u)" != "0" ] && { echo "❌ Нужно root"; exit 1; }

GUEST_NET="guest"
GUEST_SSID="${1:-Guest-WiFi}"
GUEST_PASS="${2:-GuestSecure123!}"
GUEST_IP="192.168.2.1/24"

# === Очистка старого ===
uci -q delete network.${GUEST_NET}_dev
uci -q delete network.$GUEST_NET

for old in $(uci show wireless | grep -E "guest_[0-9]" | cut -d. -f1-2); do
    uci -q delete "$old"
done

# === 1. Network ===
uci set network.${GUEST_NET}_dev="device"
uci set network.${GUEST_NET}_dev.type="bridge"
uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"

uci set network.$GUEST_NET="interface"
uci set network.$GUEST_NET.proto="static"
uci set network.$GUEST_NET.device="br-${GUEST_NET}"
uci set network.$GUEST_NET.ipaddr="${GUEST_IP%%/*}"
uci set network.$GUEST_NET.netmask="255.255.255.0"
uci set network.$GUEST_NET.force_link="1"
uci commit network

# === 2. Wireless — исправленная версия ===
WIFI_PASS=$( [ -f /etc/guest-wifi-pass ] && head -n1 /etc/guest-wifi-pass || echo "$GUEST_PASS" )

echo "Создаём гостевые интерфейсы на всех радио..."

for RADIO in $(uci show wireless | grep "=wifi-device" | cut -d. -f2); do
    BAND=$(uci get wireless.${RADIO}.band 2>/dev/null)
    IFACE_NAME="${GUEST_NET}_${RADIO}"

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

    echo "✅ Создан $IFACE_NAME на $RADIO (${BAND:-?} band)"
done

uci commit wireless

# === 3. DHCP + Firewall (без изменений, можно оставить как было) ===
uci -q delete dhcp.$GUEST_NET
uci set dhcp.$GUEST_NET="dhcp"
uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
uci set dhcp.$GUEST_NET.start="100"
uci set dhcp.$GUEST_NET.limit="150"
uci set dhcp.$GUEST_NET.leasetime="1h"
uci set dhcp.$GUEST_NET.force="1"
uci commit dhcp

# Firewall (сокращённо)
uci -q delete firewall.$GUEST_NET
uci set firewall.$GUEST_NET="zone"
uci set firewall.$GUEST_NET.name="$GUEST_NET"
uci set firewall.$GUEST_NET.network="$GUEST_NET"
uci set firewall.$GUEST_NET.input="REJECT"
uci set firewall.$GUEST_NET.output="ACCEPT"
uci set firewall.$GUEST_NET.forward="REJECT"
uci set firewall.$GUEST_NET.masq="1"

uci -q delete firewall.${GUEST_NET}_wan
uci set firewall.${GUEST_NET}_wan="forwarding"
uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_wan.dest="wan"

uci commit firewall

# === Применение ===
echo "🔄 Перезапускаем..."
service network restart
sleep 2
wifi reload
sleep 3
service dnsmasq restart
service firewall restart

echo ""
echo "=== Проверка ==="
uci show wireless | grep -E "guest_.*=wifi-iface"
echo ""
wifi status | grep -A 20 "interfaces"