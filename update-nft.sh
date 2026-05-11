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

# Извлекаем IP‑адреса серверов из config.json
extract_server_ips() {
	local raw

	# Пробуем Python-парсер
	raw=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr:
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null)

	# Fallback на grep
	if [ -z "$raw" ]; then
		raw=$(grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONF" 2>/dev/null |
			sed 's/.*"\([^"]*\)"$/\1/' |
			sort -u)
	fi

	[ -z "$raw" ] && return

	# Разделяем IP и домены, резолвим домены
	local ips=""
	while IFS= read -r addr; do
		case "$addr" in
		"hole" | "0.0.0.0" | "127.0.0.1" | "")
			continue
			;;
		*[a-zA-Z]*)
			# Домен — резолвим с таймаутом 5 секунд
			local resolved
			resolved=$(timeout 5 resolveip -4 "$addr" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
			if [ -n "$resolved" ]; then
				# Проверяем валидность полученного IP
				if echo "$resolved" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
					ips="$ips,$resolved"
					logger -t update-nft "Resolved $addr → $resolved"
				else
					logger -t update-nft "Invalid IP resolved for $addr: $resolved"
				fi
			else
				logger -t update-nft "Failed to resolve $addr (timeout or error)"
			fi
			;;
		*.*.*.*)
			# Уже IP — проверяем валидность
			if echo "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
				ips="$ips,$addr"
			fi
			;;
		esac
	done <<EOF
$raw
EOF

	echo "$ips" | sed 's/^,//'
}

setup_network() {
	# Очистка старых правил (безопасная)
	ip rule del fwmark 1 table 100 2>/dev/null || true
	ip route flush table 100 2>/dev/null || true

	# Policy routing
	ip rule add fwmark 1 table 100
	ip route add 0.0.0.0/0 dev lo table 100

	# Получаем IP прокси-серверов для bypass
	local bypass_ips
	bypass_ips=$(extract_server_ips)

	# nftables
	nft list table inet xray >/dev/null 2>&1 && nft delete table inet xray

	local nft_file="/tmp/xray.nft"

	# Начинаем создавать правила
	cat >"$nft_file" <<NFT
table inet xray {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # 1. Пропускаем уже помеченный трафик (от Xray или уже обработанный)
        meta mark 0x1 return;

        # 2. Пропускаем трафик от самого процесса Xray (избегаем петли)
        meta skuid xray return;

        # 3. Локальные и приватные IP — bypass
        ip daddr {
            127.0.0.0/8,
            10.0.0.0/8,
            172.16.0.0/12,
            192.168.0.0/16,
            169.254.0.0/16,
            224.0.0.0/3
        } return;
NFT

	# 4. Bypass IPs (прокси-серверы) — если есть
	if [ -n "$bypass_ips" ]; then
		# Проверяем, что все IP валидны
		VALID_IPS=$(echo "$bypass_ips" | tr ',' '\n' | grep -Ex '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ',' | sed 's/,$//')
		if [ -n "$VALID_IPS" ]; then
			cat >>"$nft_file" <<NFT
        # 4. Прокси-серверы — bypass
        ip daddr { $VALID_IPS } return;
NFT
			logger -t update-nft "Bypass IPs added: $VALID_IPS"
		else
			logger -t update-nft "No valid bypass IPs found, skipping bypass rule"
		fi
	fi

	# 5. DHCP и ответы от Xray
	cat >>"$nft_file" <<NFT

        # 5. DHCP запросы — bypass
        udp dport { 67, 68 } return;

        # 6. Ответы от самого Xray (TProxy ответы, DNS ответы)
        tcp sport 12345 return;
        udp sport 5353 return;

        # 7. Весь остальной трафик с LAN → TProxy
        iifname "$LAN_IF" meta l4proto { tcp, udp } \
            tproxy ip to 127.0.0.1:12345 meta mark set 1 accept;
    }
}
NFT

	# Применяем правила
	if nft -f "$nft_file"; then
		logger -t update-nft "Network rules applied successfully"

		# Дополнительная проверка: убедимся, что правила действительно загружены
		if nft list table inet xray >/dev/null 2>&1; then
			logger -t update-nft "nftables table 'inet xray' verified"
		else
			logger -t update-nft "WARNING: nftables table not found after apply!"
			rm -f "$nft_file"
			return 1
		fi
	else
		logger -t update-nft "nftables apply failed"
		rm -f "$nft_file"
		return 1
	fi

	rm -f "$nft_file"
	return 0
}

# Выполняем настройку
if setup_network; then
	logger -t update-nft "TProxy network setup completed successfully"
	exit 0
else
	logger -t update-nft "TProxy network setup failed"
	exit 1
fi
