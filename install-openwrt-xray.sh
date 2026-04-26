#!/bin/sh
# OpenWrt 25.12.x — fw4-compatible TProxy (IPv4-only)
# Xray + TProxy + fw4 include + policy routing + diagnostics

set -e

REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

echo "=== Установка Xray (fw4-compatible TProxy, IPv4-only) ==="

# 1. root
[ "$(id -u)" != "0" ] && { echo "Запускать нужно от root"; exit 1; }

# 2. подписка
printf "Введите URL подписки VLESS: "
read SUB_URL
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL"; exit 1; }

mkdir -p /etc/xray
echo "$SUB_URL" > "$SUB_FILE"
chmod 600 "$SUB_FILE"

# 3. пакеты
apk update
apk add curl xray-core nftables ca-certificates jq python3 ip-full
apk add kmod-nft-tproxy kmod-nft-socket kmod-nft-nat || true

# 4. скрипты
wget -q "$REPO/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
wget -q "$REPO/diagnose-xray-tproxy.sh" -O "$DIAG"; chmod +x "$DIAG"

# 5. dnsmasq → Xray
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 6. fw4 include — prerouting hook
mkdir -p /usr/share/nftables.d/chain-pre/prerouting
cat > /usr/share/nftables.d/chain-pre/prerouting/30-xray-tproxy.nft << 'EOF'
jump xray_tproxy
EOF

# 7. fw4 include — TProxy rules
mkdir -p /usr/share/nftables.d/table-post
cat > /usr/share/nftables.d/table-post/30-xray-tproxy-chain.nft << 'EOF'
chain xray_tproxy {
    type filter hook prerouting priority mangle; policy accept;

    # LAN interface
    iifname "br-lan" meta l4proto tcp tproxy to 127.0.0.1:12345 meta mark set 1 accept
    iifname "br-lan" meta l4proto udp tproxy to 127.0.0.1:12345 meta mark set 1 accept

    # Bypass private networks
    ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return

    # Bypass Xray itself
    meta mark 0xff return

    # DHCP bypass
    udp dport { 67, 68 } return

    # QUIC drop
    iifname "br-lan" udp dport 443 drop
}
EOF

# 8. reload fw4
/etc/init.d/firewall restart

# 9. policy routing
grep -q "100 xray" /etc/iproute2/rt_tables || echo "100 xray" >> /etc/iproute2/rt_tables

ip rule | grep -q "fwmark 0x1 lookup xray" || ip rule add fwmark 1 lookup xray
ip route show table xray | grep -q "local 0.0.0.0/0" || ip route add local 0.0.0.0/0 dev lo table xray

# 10. sysctl
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 11. HWID
if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

# 12. config.json
curl -s -L -m 15 -H "User-Agent: Happ" -H "x-hwid: $HWID" "$SUB_URL" \
    | python3 "$PARSER" | python3 "$GENERATOR" --output "$CONFIG_JSON"

# 13. cron
CRON_LINE="0 */3 * * * /root/update-xray.sh"
grep -qF "$CRON_LINE" /etc/crontabs/root || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# 14. enable services
/etc/init.d/xray enable || true
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/xray restart

# 15. диагностика
echo
echo "=== АВТО-ДИАГНОСТИКА ==="
"$DIAG"
echo

echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"
