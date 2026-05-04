#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"
LAN_IF="br-lan"

# Автоопределение LAN интерфейса, если br-lan отсутствует
if ! ip link show br-lan >/dev/null 2>&1; then
	LAN_IF="$(uci show network | grep "=interface" | grep -v 'wan\|loopback' | head -1 | cut -d. -f2)"
	[ -z "$LAN_IF" ] && LAN_IF="br-lan"
	logger -t update-nft "LAN интерфейс auto-detected: $LAN_IF"
fi

# Извлекаем IP‑адреса серверов из config.json
extract_server_ips() {
	grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null |
		sed 's/.*"\([^"]*\)"$/\1/' |
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
		sort -u
}

setup_network() {
	# Очистка старых правил
	while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
	ip route flush table 100 2>/dev/null

	# Policy routing
	ip rule add fwmark 1 table 100
	ip route add local 0.0.0.0/0 dev lo table 100

	# Bypass IPs
	local bypass_ips
	bypass_ips=$(extract_server_ips | tr '\n' ',' | sed 's/,$//')

	# nftables
	nft list table inet xray >/dev/null 2>&1 && nft delete table inet xray

	local nft_file="/tmp/xray.nft"
	cat >"$nft_file" <<NFT
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        } return;

        meta mark 0xff return;
NFT

	[ -n "$bypass_ips" ] &&
		echo "        ip daddr { $bypass_ips } return;" >>"$nft_file"

	cat >>"$nft_file" <<NFT
        udp dport { 67, 68 } return;

        iifname "$LAN_IF" meta l4proto { tcp, udp } \
            tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFT

	if nft -f "$nft_file"; then
		logger -t update-nft "Network rules applied (bypass: ${bypass_ips:-none})"
	else
		logger -t update-nft "nftables apply failed"
		rm -f "$nft_file"
		return 1
	fi

	rm -f "$nft_file"
}

setup_network
