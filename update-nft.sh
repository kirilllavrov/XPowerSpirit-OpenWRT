#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IF="br-lan"

# Автоопределение LAN интерфейса, если br-lan отсутствует
if ! ip link show br-lan >/dev/null 2>&1; then
	LAN_IF=$(uci -q get network.lan.device 2>/dev/null)
	[ -z "$LAN_IF" ] && LAN_IF="br-lan"
	logger -t update-nft "LAN интерфейс auto-detected: $LAN_IF"
fi

# Извлекаем адреса серверов из config.json
extract_server_addrs() {
	local raw

	raw=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and addr not in ("hole", "0.0.0.0", "127.0.0.1", ""):
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null)

	[ -z "$raw" ] && {
		raw=$(grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null |
			sed 's/.*"\([^"]*\)"$/\1/' |
			grep -vE '^(hole|0\.0\.0\.0|127\.0\.0\.1|)$' |
			sort -u)
	}

	echo "$raw"
}

# Резолвим домены в IP (если возможно)
resolve_to_ips() {
	while IFS= read -r addr; do
		[ -z "$addr" ] && continue
		case "$addr" in
		*.*.*.*)
			echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && echo "$addr"
			;;
		*)
			timeout 3 resolveip -4 "$addr" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
			;;
		esac
	done
}

setup_network() {
	# Очистка старых правил
	ip rule del fwmark 1 table 100 2>/dev/null || true
	ip route flush table 100 2>/dev/null || true

	# Policy routing
	ip rule add fwmark 1 table 100
	ip route add 0.0.0.0/0 dev lo table 100

	# Получаем адреса и резолвим что можем
	local server_addrs
	server_addrs=$(extract_server_addrs)
	
	local bypass_ips=""
	[ -n "$server_addrs" ] && bypass_ips=$(echo "$server_addrs" | resolve_to_ips | sort -u | tr '\n' ',' | sed 's/,$//')

	# nftables
	nft list table inet xray >/dev/null 2>&1 && nft delete table inet xray

	local nft_file="/tmp/xray.nft"

	cat >"$nft_file" <<NFT
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 1. Уже помеченный трафик — пропускаем
        meta mark 0x1 return;

        # 2. Ответы от Xray клиентам — пропускаем
        tcp sport 12345 return;
        udp sport 12345 return;

        # 3. DNS ответы от Xray — пропускаем
        udp sport 5353 return;

        # 4. Локальные/приватные IP — напрямую
        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            224.0.0.0/3
        } return;
NFT

	# 5. IP прокси-серверов (если зарезолвились) — напрямую
	if [ -n "$bypass_ips" ]; then
		echo "        ip daddr { $bypass_ips } return;" >>"$nft_file"
		logger -t update-nft "Bypass IPs: $bypass_ips"
	fi

	# 6. DHCP и TProxy
	cat >>"$nft_file" <<NFT

        # 6. DHCP — напрямую
        udp dport { 67, 68 } return;

        # 7. Всё остальное с LAN → TProxy
        iifname "$LAN_IF" meta l4proto { tcp, udp } \
            tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFT

	if nft -f "$nft_file"; then
		logger -t update-nft "Rules applied successfully"
		rm -f "$nft_file"
		return 0
	else
		logger -t update-nft "nftables apply failed"
		rm -f "$nft_file"
		return 1
	fi
}

setup_network