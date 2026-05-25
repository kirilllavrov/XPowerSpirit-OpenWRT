#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IF="br-lan"
GUEST_IF="br-guest"

extract_server_ips() {
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr and addr not in ["hole", "0.0.0.0", "127.0.0.1"]:
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

setup_network() {
    # Policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Создаём цепочку
    if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        nft add chain inet fw4 xray_tproxy
        nft add rule inet fw4 prerouting jump xray_tproxy
    else
        nft flush chain inet fw4 xray_tproxy
    fi

    # Базовые bypass
    nft add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    nft add rule inet fw4 xray_tproxy ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0 } return
    nft add rule inet fw4 xray_tproxy meta mark 0x1 return

    # DHCP — НЕ ТРОГАЕМ
    nft add rule inet fw4 xray_tproxy udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_tproxy ip daddr $ip return
        fi
    done

    # Гостевая сеть (если существует)
    if ip link show br-guest >/dev/null 2>&1; then
        nft add rule inet fw4 xray_tproxy iifname "$GUEST_IF" return
    fi

    # TProxy для LAN
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # QUIC блокировка
    if ! nft list chain inet fw4 prerouting 2>/dev/null | grep -q "udp dport 443 drop"; then
        nft insert rule inet fw4 prerouting udp dport 443 drop
    fi

    logger -t update-nft "Xray TProxy rules applied"
}

setup_network