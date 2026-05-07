#!/bin/sh
# Xray TProxy — Глубокая диагностика (v4)
printf "=== Xray TProxy DEEP DIAGNOSTICS v4 ===\n\n"

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
grep -q '"mark": 255' "$CFG" && _ok "Mark 255 на месте" || _fail "Mark 255 отсутствует"

# 4. nftables (inet xray, цепочка prerouting)
printf "\n[4] nftables (inet xray):\n"
if nft list table inet xray 2>/dev/null >/dev/null; then
    _ok "Таблица inet xray загружена"
    if nft list chain inet xray prerouting 2>/dev/null | grep -qE 'dport.*53.*return'; then
        _ok "DNS (порт 53) исключён из TProxy"
    else
        _fail "DNS (порт 53) НЕ исключён!"
    fi
    if nft list chain inet xray prerouting 2>/dev/null | grep -q "type filter hook prerouting priority mangle"; then
        _ok "Хук prerouting priority mangle"
    else
        _fail "Неверный hook/priority"
    fi
else
    _fail "Таблица inet xray отсутствует!"
fi

# 5. Интеграция с fw4
printf "\n[5] Интеграция с fw4:\n"
if nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -q "jump prerouting"; then
    _ok "jump в xray prerouting найден"
else
    _warn "jump отсутствует (автономная цепочка)"
fi

# 6. Routing
printf "\n[6] Policy Routing:\n"
ip -4 rule show | grep -q "fwmark 0x1 lookup 100" && _ok "ip rule fwmark 1 → table 100" || _fail "ip rule отсутствует"
ip route show table 100 2>/dev/null | grep -q "local default" && _ok "Таблица 100: local default dev lo" || _fail "Таблица 100 неверна"

# 7. dnsmasq → 5053/5054
printf "\n[7] DNS Forwarding (dnsmasq):\n"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#5053" && \
    _ok "dnsmasq → 127.0.0.1:5053" || _fail "dnsmasq НЕ настроен на 5053"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#5054" && \
    _ok "dnsmasq → 127.0.0.1:5054" || _warn "dnsmasq: 5054 не найден"

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
if ! nft list chain inet xray prerouting 2>/dev/null | grep -qE 'dport.*53.*return'; then
    printf "[FIX DNS] Выполни:\n"
    printf "  /usr/share/xray/update-nft.sh\n"
fi
if ! uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#5053"; then
    printf "[FIX DNSMASQ] Выполни:\n"
    printf "  uci set dhcp.@dnsmasq[0].noresolv='1'\n"
    printf "  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'\n"
    printf "  uci commit && /etc/init.d/dnsmasq restart\n"
fi
printf "\n=== END ===\n"