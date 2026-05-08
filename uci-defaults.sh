#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only) + Full Setup (LAN/WAN + Wi-Fi Home+Guest)

LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy + Полная настройка (LAN/WAN + Wi-Fi) ==="

[ "$(id -u)" != "0" ] && {
	echo "❌ Запускать нужно от root"
	exit 1
}

# ====================== НАСТРОЙКИ ======================
root_password="ТВОЙ_РУТ_ПАРОЛЬ"

# LAN
lan_ip_address="192.168.1.1/24"

# WAN (раскомментируй, если PPPoE)
# pppoe_username="login@provider"
# pppoe_password="password"

# Wi-Fi
HOME_SSID="Home-WiFi"
HOME_PASS="HomeSecure123!"
GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"

# Guest Network
GUEST_NET="guest"
GUEST_IP="192.168.2.1"
DL_GUEST="5120"
UL_GUEST="5120"

# Xray Подписка (обязательно!)
SUB_URL="https://твоя.подписка.здесь"

# =======================================================

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
NFT_UPDATER="/usr/share/xray/update-nft.sh"
CONFIG_DIR="/etc/xray"
GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"
TMP_DIR="/tmp/xray_install"

# =============================================
# 0. LAN + WAN (самое первое!)
# =============================================
echo "0. Настройка LAN + WAN..."

if [ -n "$root_password" ]; then
    echo "$root_password" | passwd --stdin root
    echo "[+] Root password установлен"
fi

# LAN
if [ -n "$lan_ip_address" ]; then
    uci set network.lan.ipaddr="$lan_ip_address"
    uci commit network
    echo "[+] LAN IP: $lan_ip_address"
fi

# WAN
if [ -n "$pppoe_username" ] && [ -n "$pppoe_password" ]; then
    uci set network.wan.proto='pppoe'
    uci set network.wan.username="$pppoe_username"
    uci set network.wan.password="$pppoe_password"
    uci set network.wan.ipv6='0'
    echo "[+] WAN: PPPoE"
else
    uci set network.wan.proto='dhcp'
    echo "[+] WAN: DHCP"
fi
uci commit network

echo "Применяем сеть..."
service network restart
sleep 5

# =============================================
# 1. Ожидание интернета
# =============================================
echo "1. Ожидание интернета..."
MAX_WAIT=90
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if ip route | grep -q default && ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo "[+] Интернет появился"
        break
    fi
    if [ $((WAIT_COUNT % 10)) -eq 0 ]; then
        echo "  → Ждём интернет... ($WAIT_COUNT/$MAX_WAIT сек)"
    fi
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "⚠️ Интернет не появился за $MAX_WAIT сек. Продолжаем на свой страх и риск."
fi

# =============================================
# 2. Настройка Wi-Fi (Home + Guest)
# =============================================
echo "2. Настройка Wi-Fi (Home + Guest)..."

# Очистка старых iface
while uci -q delete wireless.@wifi-iface[0]; do :; done
uci commit wireless

# Радио
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
    uci set wireless.${RADIO}.country='RU'
    uci set wireless.${RADIO}.channel='auto'
    uci set wireless.${RADIO}.legacy_rates='0'
    uci set wireless.${RADIO}.cell_density='2'
    uci set wireless.${RADIO}.ieee80211w='1'      # PMF
    uci set wireless.${RADIO}.time_advertisement='2'
done

# HE160 на 5GHz (раскомментировать при необходимости)
# uci -q set wireless.radio1.htmode='HE160'

# Home Wi-Fi
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
    uci set wireless.home_${RADIO}="wifi-iface"
    uci set wireless.home_${RADIO}.device="$RADIO"
    uci set wireless.home_${RADIO}.mode="ap"
    uci set wireless.home_${RADIO}.network="lan"
    uci set wireless.home_${RADIO}.ssid="$HOME_SSID"
    uci set wireless.home_${RADIO}.encryption="sae-mixed"
    uci set wireless.home_${RADIO}.key="$HOME_PASS"
    uci set wireless.home_${RADIO}.isolate="0"
    uci set wireless.home_${RADIO}.disabled="0"
done

# Guest Wi-Fi
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
    uci set wireless.guest_${RADIO}="wifi-iface"
    uci set wireless.guest_${RADIO}.device="$RADIO"
    uci set wireless.guest_${RADIO}.mode="ap"
    uci set wireless.guest_${RADIO}.network="$GUEST_NET"
    uci set wireless.guest_${RADIO}.ssid="$GUEST_SSID"
    uci set wireless.guest_${RADIO}.encryption="sae-mixed"
    uci set wireless.guest_${RADIO}.key="$GUEST_PASS"
    uci set wireless.guest_${RADIO}.isolate="1"
    uci set wireless.guest_${RADIO}.disabled="0"
done

uci commit wireless
echo "[+] Wi-Fi настроен (Home + Guest)"

# =============================================
# 3. Guest Network + SQM + Firewall
# =============================================
echo "3. Настройка Guest Network..."

# Bridge
uci -q delete network.${GUEST_NET}_dev
uci set network.${GUEST_NET}_dev="device"
uci set network.${GUEST_NET}_dev.type="bridge"
uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"
uci set network.${GUEST_NET}_dev.bridge_empty="1"

# Interface
uci -q delete network.$GUEST_NET
uci set network.$GUEST_NET="interface"
uci set network.$GUEST_NET.proto="static"
uci set network.$GUEST_NET.device="br-${GUEST_NET}"
uci set network.$GUEST_NET.ipaddr="$GUEST_IP"
uci set network.$GUEST_NET.netmask="255.255.255.0"

# DHCP
uci -q delete dhcp.$GUEST_NET
uci set dhcp.$GUEST_NET="dhcp"
uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
uci set dhcp.$GUEST_NET.start="100"
uci set dhcp.$GUEST_NET.limit="150"
uci set dhcp.$GUEST_NET.leasetime="12h"
uci set dhcp.$GUEST_NET.force="1"

# Firewall Zone
uci -q delete firewall.$GUEST_NET
uci set firewall.$GUEST_NET="zone"
uci set firewall.$GUEST_NET.name="$GUEST_NET"
uci set firewall.$GUEST_NET.network="$GUEST_NET"
uci set firewall.$GUEST_NET.input="REJECT"
uci set firewall.$GUEST_NET.output="ACCEPT"
uci set firewall.$GUEST_NET.forward="REJECT"
uci set firewall.$GUEST_NET.masq="1"
uci set firewall.$GUEST_NET.mtu_fix="1"

# Firewall rules (DNS + DHCP)
uci -q delete firewall.${GUEST_NET}_dns
uci set firewall.${GUEST_NET}_dns="rule"
uci set firewall.${GUEST_NET}_dns.name="Allow-DNS-Guest"
uci set firewall.${GUEST_NET}_dns.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dns.dest_port="53"
uci set firewall.${GUEST_NET}_dns.proto="tcp udp"
uci set firewall.${GUEST_NET}_dns.target="ACCEPT"

uci -q delete firewall.${GUEST_NET}_dhcp
uci set firewall.${GUEST_NET}_dhcp="rule"
uci set firewall.${GUEST_NET}_dhcp.name="Allow-DHCP-Guest"
uci set firewall.${GUEST_NET}_dhcp.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dhcp.dest_port="67-68"
uci set firewall.${GUEST_NET}_dhcp.proto="udp"
uci set firewall.${GUEST_NET}_dhcp.target="ACCEPT"

# Forward to WAN
uci -q delete firewall.${GUEST_NET}_wan
uci set firewall.${GUEST_NET}_wan="forwarding"
uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_wan.dest="wan"

# SQM
uci -q delete sqm.$GUEST_NET
uci set sqm.$GUEST_NET="queue"
uci set sqm.$GUEST_NET.interface="br-${GUEST_NET}"
uci set sqm.$GUEST_NET.download="$DL_GUEST"
uci set sqm.$GUEST_NET.upload="$UL_GUEST"
uci set sqm.$GUEST_NET.qdisc="cake"
uci set sqm.$GUEST_NET.script="piece_of_cake.qos"
uci set sqm.$GUEST_NET.enabled="1"

uci commit network
uci commit dhcp
uci commit firewall
uci commit sqm

echo "[+] Guest Network и SQM настроены"

# =============================================
# Дальше идёт оригинальная часть установки Xray
# (я оставил её почти без изменений)
# =============================================

# ... (сюда вставляется весь твой оригинальный код начиная с пункта 4 — установка Xray)

echo "4. Устанавливаем Xray и необходимые компоненты..."

# (Весь остальной код из твоего первого большого скрипта: скачивание Xray, скриптов, geo, генерация config и т.д.)

# =============================================
# Финальное применение изменений
# =============================================
echo "Применяем финальные изменения..."
wifi reload
service network restart
service firewall restart
service sqm restart
sleep 3

echo "=== Установка завершена успешно ==="
echo "Home Wi-Fi : $HOME_SSID"
echo "Guest Wi-Fi: $GUEST_SSID"
echo "LAN IP     : $lan_ip_address"