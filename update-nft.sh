#!/bin/sh
# OpenWrt — обновление nftables правил для Xray TProxy

CONF="/etc/xray/config.json"

# Откат при неудаче: иначе маркировка трафика роутера остаётся без TProxy-правил
# (пакет уходит в table 100 → lo и теряется), и роутер остаётся без интернета.
fail() {
    logger -t update-nft "$1"
    echo "[X] $1" >&2
    nft delete table inet xray_self 2>/dev/null
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    echo "[X] Правила TProxy откатены, трафик идёт напрямую" >&2
    exit 1
}

# Автоопределение LAN интерфейса
if ip link show br-lan >/dev/null 2>&1; then
    LAN_IF="br-lan"
else
    # Fallback: читаем из UCI
    LAN_IF=$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo "br-lan")
    # Если UCI вернул несколько интерфейсов (bridge), берём первый
    LAN_IF="${LAN_IF%% *}"
fi

if [ -z "$LAN_IF" ] || ! ip link show "$LAN_IF" >/dev/null 2>&1; then
    fail "LAN-интерфейс '${LAN_IF:-<пусто>}' не существует"
fi

# Автоопределение Guest интерфейса
if ip link show br-guest >/dev/null 2>&1; then
    GUEST_IF="br-guest"
else
    GUEST_IF=$(uci -q get network.guest.device || uci -q get network.guest.ifname || echo "")
    GUEST_IF="${GUEST_IF%% *}"
fi

# Автоопределение IoT интерфейса
if ip link show br-iot >/dev/null 2>&1; then
    IOT_IF="br-iot"
else
    IOT_IF=$(uci -q get network.iot.device || uci -q get network.iot.ifname || echo "")
    IOT_IF="${IOT_IF%% *}"
fi

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

# IP DNS-серверов из config.json (dns.hosts и литеральные адреса в dns.servers):
# нужны, чтобы запросы DoH уходили мимо TProxy и не зацикливались
extract_dns_ips() {
    python3 -c '
import json, sys
def is_ipv4(a):
    if not isinstance(a, str) or a.count(".") != 3:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in a.split("."))
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    dns = cfg.get("dns") or {}
    ips = set()
    for value in (dns.get("hosts") or {}).values():
        for a in (value if isinstance(value, list) else [value]):
            if is_ipv4(a):
                ips.add(a)
    for server in (dns.get("servers") or []):
        addr = server.get("address") if isinstance(server, dict) else server
        if is_ipv4(addr):
            ips.add(addr)
    for a in sorted(ips):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

setup_network() {
    # busybox в OpenWrt не имеет paste — собираем список вручную
    DNS_SET=$(extract_dns_ips | tr '\n' ',')
    DNS_SET=${DNS_SET%,}
    if [ -z "$DNS_SET" ]; then
        logger -t update-nft "DNS bypass list is empty — check dns.hosts/servers in config.json"
    fi

    # Policy routing
    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Создаём цепочку xray_tproxy (PREROUTING)
    if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        nft add chain inet fw4 xray_tproxy
        nft add rule inet fw4 prerouting jump xray_tproxy
    else
        nft flush chain inet fw4 xray_tproxy
    fi

    # Убираем устаревшую интеграцию: jump из fw4 output в xray_output.
    # Цепочка fw4 имеет type filter — mark, выставленный там, не влияет на
    # маршрутизацию, поэтому трафик роутера шёл мимо прокси.
    _h=$(nft -a list chain inet fw4 output 2>/dev/null | grep 'jump xray_output' | sed 's/.*handle //' | head -1)
    [ -n "$_h" ] && nft delete rule inet fw4 output handle "$_h" 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null

    # ========== PREROUTING (xray_tproxy) ==========

    # Если пакет уже отмаркирован Xray (mark 2) — пропускаем (защита от петель)
    nft add rule inet fw4 xray_tproxy meta mark 2 return

    # Базовые bypass
    nft add rule inet fw4 xray_tproxy ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    if [ -n "$DNS_SET" ]; then
        nft add rule inet fw4 xray_tproxy ip daddr { $DNS_SET } return
    fi

    # DHCP — НЕ ТРОГАЕМ
    nft add rule inet fw4 xray_tproxy udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet fw4 xray_tproxy ip daddr $ip return
        fi
    done

    # Гостевая сеть (если существует)
    if [ -n "$GUEST_IF" ] && ip link show "$GUEST_IF" >/dev/null 2>&1; then
        nft add rule inet fw4 xray_tproxy iifname "$GUEST_IF" return
    fi

    # IoT сеть (если существует)
    if [ -n "$IOT_IF" ] && ip link show "$IOT_IF" >/dev/null 2>&1; then
        nft add rule inet fw4 xray_tproxy iifname "$IOT_IF" return
    fi

    # Блокировка QUIC (UDP/443) — ДО TProxy, иначе пакет уйдёт в Xray до проверки
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" udp dport 443 drop

    # TProxy для LAN (сохраняем оригинальный mark 0x1 для policy routing)
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto tcp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept
    nft add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto udp tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept

    # TProxy для трафика самого роутера (перенаправлен из OUTPUT с mark 0x1 через lo)
    # Эти правила не имеют iifname — сработают для пакетов, уже отмаркированных OUTPUT chain
    nft add rule inet fw4 xray_tproxy meta mark 0x1 meta l4proto tcp tproxy ip to 127.0.0.1:12345 accept
    nft add rule inet fw4 xray_tproxy meta mark 0x1 meta l4proto udp tproxy ip to 127.0.0.1:12345 accept

    # ========== OUTPUT (трафик самого роутера) ==========
    # Отдельная таблица с type route hook output priority mangle — как в официальном
    # руководстве по TProxy. В цепочке fw4 (type filter) mark не влияет на
    # маршрутизацию, и трафик роутера уходил мимо прокси.
    nft delete table inet xray_self 2>/dev/null
    nft add table inet xray_self
    nft "add chain inet xray_self output { type route hook output priority mangle; policy accept; }"

    # Loop prevention: пакеты с mark 2 (от Xray outbound) — пропускаем, не трогаем
    nft add rule inet xray_self output meta mark 2 return

    # Базовые bypass (локальные сети)
    nft add rule inet xray_self output ip daddr { 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } return
    if [ -n "$DNS_SET" ]; then
        nft add rule inet xray_self output ip daddr { $DNS_SET } return
    fi
    nft add rule inet xray_self output udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            nft add rule inet xray_self output ip daddr $ip return
        fi
    done

    # Помечаем mark 1: правило fwmark 1 → table 100 (local default dev lo)
    # возвращает пакет в prerouting, где его ловит TProxy
    nft add rule inet xray_self output meta l4proto tcp meta mark set 1
    nft add rule inet xray_self output meta l4proto udp meta mark set 1

    # Проверяем, что ключевые правила реально применились: иначе init.d сочтёт
    # правила готовыми и запустит Xray без TProxy (прокси молча не работает)
    _chain=$(nft list chain inet fw4 xray_tproxy 2>/dev/null)
    for _pat in "tproxy ip to 127.0.0.1:12345" "udp dport 443 drop"; do
        if ! echo "$_chain" | grep -qF "$_pat"; then
            fail "В цепочке xray_tproxy нет правила: $_pat"
        fi
    done
    if ! echo "$_chain" | grep -qE "mark (0x0*2|2) return"; then
        fail "В цепочке xray_tproxy нет защиты от петель (mark 2 return)"
    fi
    if [ -n "$DNS_SET" ]; then
        _dns_first=${DNS_SET%%,*}
        if ! echo "$_chain" | grep -qF "$_dns_first"; then
            fail "В цепочке xray_tproxy нет bypass для DNS-серверов ($_dns_first)"
        fi
    fi

    _self=$(nft list chain inet xray_self output 2>/dev/null)
    if ! echo "$_self" | grep -q "mark set 0x00000001"; then
        fail "В цепочке xray_self нет правила маркировки (mark set 1)"
    fi
    if ! echo "$_self" | grep -qE "type route hook output priority mangle"; then
        fail "Цепочка xray_self должна быть type route hook output priority mangle"
    fi

    logger -t update-nft "Xray TProxy rules applied"
}

setup_network