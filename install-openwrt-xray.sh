#!/bin/sh
# install-xray-nft.sh — nftables + TProxy + policy routing
# OpenWrt 25.12.x (apk-based)

set -e

REPO_RAW="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"
UPDATER="/root/update-xray.sh"
DIAG="/root/diagnose-xray-tproxy.sh"

CONFIG_JSON="/etc/xray/config.json"
SUB_FILE="/etc/xray/subscription.url"
HWID_FILE="/etc/xray/hwid"

GEO_DIR="/usr/share/xray"
mkdir -p "$GEO_DIR"

GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo "=== Установка Xray на OpenWrt (nftables + TProxy + policy routing) ==="

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

# 4. geoip/geosite
curl -fsSL "$GEOIP_URL" -o "$GEOIP"
curl -fsSL "$GEOSITE_URL" -o "$GEOSITE"

# 5. генератор/парсер/обновлялка/диагностика
wget -q "$REPO_RAW/xray-generate-config.py" -O "$GENERATOR"; chmod +x "$GENERATOR"
wget -q "$REPO_RAW/xray-sub-parser.py" -O "$PARSER"; chmod +x "$PARSER"
wget -q "$REPO_RAW/update-xray.sh" -O "$UPDATER"; chmod +x "$UPDATER"
wget -q "$REPO_RAW/diagnose-xray-tproxy.sh" -O "$DIAG"; chmod +x "$DIAG"

# 6. dnsmasq → Xray
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53'
uci commit dhcp

# 7. nftables: table ip xray
cat > /etc/nftables.d/xray.nft << 'EOF'
table ip xray {
    chain prerouting {
        type filter hook prerouting priority mangle;
        policy accept;

        # Bypass приватных подсетей
        ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return

        # Bypass трафика самого Xray
        meta mark 0xff return

        # DHCP — не трогать
        udp dport { 67, 68 } return

        # QUIC drop
        iifname "br-lan" udp dport 443 drop

        # TCP TPROXY
        iifname "br-lan" meta l4proto tcp \
            tproxy to 127.0.0.1:12345 meta mark set 1 accept

        # UDP TPROXY
        iifname "br-lan" meta l4proto udp \
            tproxy to 127.0.0.1:12345 meta mark set 1 accept
    }
}
EOF

nft -f /etc/nftables.d/xray.nft

# 8. init-скрипт для nftables
cat > /etc/init.d/nft-xray << 'EOF'
#!/bin/sh /etc/rc.common
START=15
start() {
    nft -f /etc/nftables.d/xray.nft
}
EOF

chmod +x /etc/init.d/nft-xray
/etc/init.d/nft-xray enable

# 9. policy routing для TProxy
# таблица xray
grep -q "100 xray" /etc/iproute2/rt_tables 2>/dev/null || echo "100 xray" >> /etc/iproute2/rt_tables

# правило fwmark 1 → table xray
ip rule | grep -q "fwmark 0x1 lookup xray" || ip rule add fwmark 1 lookup xray

# local route в таблице xray
ip route show table xray | grep -q "local 0.0.0.0/0" || ip route add local 0.0.0.0/0 dev lo table xray

# 10. sysctl для TProxy
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# persist sysctl (если есть sysctl.conf)
if grep -q "route_localnet" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^net.ipv4.conf.all.route_localnet=.*/net.ipv4.conf.all.route_localnet=1/' /etc/sysctl.conf
else
    echo "net.ipv4.conf.all.route_localnet=1" >> /etc/sysctl.conf
fi

if grep -q "ip_forward" /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

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
grep -qF "$CRON_LINE" /etc/crontabs/root 2>/dev/null || echo "$CRON_LINE" >> /etc/crontabs/root
/etc/init.d/cron restart

# 14. включаем и перезапускаем сервисы
/etc/init.d/xray enable || true
/etc/init.d/dnsmasq restart
/etc/init.d/nft-xray start
/etc/init.d/xray restart

# 15. авто-диагностика
echo
echo "=== АВТО-ДИАГНОСТИКА ==="
"$DIAG"
echo

echo "=== Установка завершена ==="
echo "HWID: $HWID"
echo "Config: $CONFIG_JSON"
