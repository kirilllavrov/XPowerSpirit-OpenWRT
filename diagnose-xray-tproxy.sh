#!/bin/sh
# Xray TProxy — Глубокая диагностика (v5)
printf "=== Xray TProxy DEEP DIAGNOSTICS v5 ===\n\n"

_ok()   { printf "[OK]   %s\n" "$1"; }
_warn() { printf "[WARN] %s\n" "$1"; }
_fail() { printf "[FAIL] %s\n" "$1"; }

# 1. Процесс
printf "[1] Xray process:\n"
pgrep -a xray >/dev/null && _ok "Xray запущен" || _fail "Xray НЕ запущен"

# 2. Порты
printf "\n[2] Listening on port 12345:\n"
ss -tuln 2>/dev/null | grep -q ':12345' && \
    _ok "Порт 12345 слушается" || \
    _warn "Порт 12345 не найден в ss (для TProxy это норма)"

# 3. Конфиг (TProxy + Mark)
printf "\n[3] Config Xray:\n"
CFG="/etc/xray/config.json"
[ -f "$CFG" ] || { _fail "$CFG отсутствует!"; exit 1; }
grep -q '"tproxy": "tproxy"' "$CFG" && _ok "TProxy включён в inbound" || _fail "TProxy не настроен"
grep -q '"mark": 2' "$CFG" && _ok "Mark 2 на месте (sockopt) — loop prevention через OUTPUT" || _warn "Mark 2 не найден (может быть не указан явно)"

# 4. nftables (inet fw4, цепочка xray_tproxy)
printf "\n[4] nftables (inet fw4 xray_tproxy):\n"
CHAIN_EXISTS=$(nft list chain inet fw4 xray_tproxy 2>/dev/null)
if [ -n "$CHAIN_EXISTS" ]; then
    _ok "Цепочка inet fw4 xray_tproxy загружена"
    
    # Проверяем, что цепочка вызывается из prerouting
    JUMP_EXISTS=$(nft list chain inet fw4 prerouting 2>/dev/null | grep -q "jump xray_tproxy" && echo "1" || echo "0")
    if [ "$JUMP_EXISTS" = "1" ]; then
        _ok "jump в xray_tproxy из prerouting настроен"
    else
        _warn "jump в xray_tproxy не найден (возможно, другая интеграция)"
    fi
    
    # Проверяем bypass DNS (порт 53)
    echo "$CHAIN_EXISTS" | grep -qE 'dport.*53.*return' && \
        _ok "DNS (порт 53) исключён из TProxy" || \
        _warn "DNS (порт 53) не исключён явно (может быть не нужно)"

    # Проверяем bypass прокси-серверов
    BYPASS_CNT=$(echo "$CHAIN_EXISTS" | grep -c "ip daddr.*return")
    [ "$BYPASS_CNT" -gt 0 ] && _ok "Bypass для серверов: $BYPASS_CNT правил" || _warn "Bypass для серверов не найден"

    # Проверяем TProxy правилa
    echo "$CHAIN_EXISTS" | grep -q "tproxy ip to 127.0.0.1:12345" && \
        _ok "TProxy на порт 12345 настроен" || \
        _fail "TProxy на порт 12345 НЕ настроен!"

    # Проверяем блокировку QUIC
    echo "$CHAIN_EXISTS" | grep -q "udp dport 443 drop" && \
        _ok "Блокировка QUIC настроена" || \
        _warn "Блокировка QUIC не настроена"
else
    _fail "Цепочка inet fw4 xray_tproxy отсутствует!"
fi

# 5. OUTPUT chain (xray_output) — для трафика самого роутера
printf "\n[5] nftables OUTPUT (inet fw4 xray_output):\n"
OUTPUT_CHAIN=$(nft list chain inet fw4 xray_output 2>/dev/null)
if [ -n "$OUTPUT_CHAIN" ]; then
    _ok "Цепочка inet fw4 xray_output загружена"

    # Loop prevention
    echo "$OUTPUT_CHAIN" | grep -q "meta mark 2 return" && \
        _ok "Loop prevention (mark 2 return) настроена" || \
        _warn "Loop prevention (mark 2 return) не найдена"

    # Маркировка для TProxy
    echo "$OUTPUT_CHAIN" | grep -q "meta mark set 1" && \
        _ok "Маркировка трафика роутера (mark 1) настроена" || \
        _warn "Маркировка трафика роутера не найдена"
else
    _warn "Цепочка xray_output отсутствует (трафик роутера не проксируется)"
fi

# 6. Routing
printf "\n[6] Policy Routing:\n"
ip -4 rule show | grep -q "fwmark 0x1 lookup 100" && _ok "ip rule fwmark 1 → table 100" || _fail "ip rule отсутствует"
ip route show table 100 2>/dev/null | grep -q "local default" && _ok "Таблица 100: local default dev lo" || _fail "Таблица 100 неверна"

# 7. dnsmasq → Xray DNS (порт 5353)
printf "\n[7] DNS Forwarding (dnsmasq → Xray:5353):\n"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#5353" && \
    _ok "dnsmasq → 127.0.0.1:5353" || _fail "dnsmasq НЕ настроен на Xray DNS (5353)"

# 8. Ошибки Xray
printf "\n[8] Ошибки Xray:\n"
if [ -s /tmp/log/xray-error.log ]; then
    tail -3 /tmp/log/xray-error.log | while read -r line; do printf "  → %s\n" "$line"; done
else
    _ok "Ошибок в логах нет"
fi

# 9. Доступность сервера
printf "\n[9] Доступность сервера:\n"
SERVER=$(grep -o '"address": "[^"]*"' "$CFG" | head -1 | cut -d'"' -f4)
if [ -n "$SERVER" ]; then
    printf "  Проверка %s... " "$SERVER"
    curl -sI -m 3 "https://$SERVER" >/dev/null 2>&1 && _ok "Доступен (HTTPS)" || \
    ping -c 1 -W 2 "$SERVER" >/dev/null 2>&1 && _ok "Доступен (ICMP)" || \
    _warn "Не отвечает (Reality — норма)"
else
    _warn "Адрес сервера не найден"
fi

# 10. DNS-тесты
printf "\n[10] DNS-тест (127.0.0.1):\n"
nslookup google.com 127.0.0.1 2>/dev/null | grep -q "Address:" && _ok "Локальный DNS отвечает" || _warn "Локальный DNS не отвечает"

printf "\n[11] DNS-тест (77.88.8.8):\n"
nslookup google.com 77.88.8.8 2>/dev/null | grep -q "Address:" && _ok "Внешний DNS отвечает" || _warn "Внешний DNS не отвечает"

# Рекомендации
printf "\n============= РЕКОМЕНДАЦИИ =============\n"
if ! nft list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "tproxy ip to 127.0.0.1:12345"; then
    printf "[FIX NFT] TProxy правила отсутствуют — выполни:\n"
    printf "  /usr/share/xray/update-nft.sh\n"
fi
if ! uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#5353"; then
    printf "[FIX DNSMASQ] Выполни:\n"
    printf "  uci set dhcp.@dnsmasq[0].noresolv='1'\n"
    printf "  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'\n"
    printf "  uci commit && /etc/init.d/dnsmasq restart\n"
fi
printf "\n=== END ===\n"