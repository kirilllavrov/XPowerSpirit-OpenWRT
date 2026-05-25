#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IF="br-lan"
GUEST_IF="br-guest"

# Автоопределение LAN интерфейса, если br-lan отсутствует
if ! ip link show br-lan >/dev/null 2>&1; then
    LAN_IF=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$LAN_IF" ] && LAN_IF="br-lan"
fi

# Извлекаем IP‑адреса серверов из config.json
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
    # Очистка старых правил policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # nftables — создаём отдельную таблицу с высоким приоритетом
    nft list table inet xray >/dev/null 2>&1 && nft delete table inet xray
    
    local nft_file="/tmp/xray.nft"

    cat >"$nft_file" <<'NFTEOF'
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle + 5; policy accept;

        # 1. Bypass локальных и служебных подсетей
        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16
        } return;

        # 2. Bypass DoH/DNS-серверов
        ip daddr { 77.88.8.8, 77.88.8.1, 1.1.1.1, 1.0.0.1, 45.90.28.0, 45.90.30.0 } return;

NFTEOF

    # 3. Bypass прокси-серверов (из подписки)
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "        ip daddr $ip return;" >> "$nft_file"
            logger -t update-nft "Bypass IP added: $ip"
        fi
    done

    cat >>"$nft_file" <<'NFTEOF'
        # 4. Bypass уже помеченного трафика (от самого Xray)
        meta mark 0x1 return;

        # 5. Гостевая сеть — НЕ проксируем, идёт напрямую
        iifname "br-guest" return;

        # 6. Блокируем UDP 443 (QUIC) — принудительно переключаем клиентов на TCP
        udp dport 443 drop;

        # 7. DHCP — не трогаем
        udp dport { 67, 68 } return;

        # 8. Всё остальное с LAN → TProxy
        iifname "br-lan" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
        iifname "br-lan" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFTEOF

    if nft -f "$nft_file"; then
        logger -t update-nft "Network rules applied successfully (LAN: $LAN_IF, GUEST: $GUEST_IF)"
        rm -f "$nft_file"
    else
        logger -t update-nft "nftables apply failed"
        rm -f "$nft_file"
        return 1
    fi
}

setup_network