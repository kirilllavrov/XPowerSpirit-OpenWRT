#!/bin/sh
# Xray TProxy — Глубокая диагностика (v5)
printf "=== Xray TProxy DEEP DIAGNOSTICS v5 ===\n\n"

_listen() {
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null
    else
        netstat -tuln 2>/dev/null
    fi
}

_ok()   { printf "[OK]   %s\n" "$1"; }
_warn() { printf "[WARN] %s\n" "$1"; }
_fail() { printf "[FAIL] %s\n" "$1"; }

# Параметры TProxy — из settings.json → tproxy, а если ключа нет, из эталона
# settings.default.json: проверяем ровно те значения, с которыми собраны
# config.json и правила nftables
SETTINGS_JSON="${XRAY_SETTINGS_JSON:-/etc/xray/settings.json}"
SETTINGS_DEFAULTS="${XRAY_SETTINGS_DEFAULTS:-/usr/share/xray/settings.default.json}"
_sset() { jq -r "$1 // empty" "$SETTINGS_JSON" 2>/dev/null; }
_sdef() { jq -r "$1 // empty" "$SETTINGS_DEFAULTS" 2>/dev/null; }
_sval() {
    _v=$(_sset "$1")
    [ -n "$_v" ] || _v=$(_sdef "$1")
    printf '%s' "$_v"
}
TPROXY_PORT=$(_sval '.tproxy.port')
DNS_PORT=$(_sval '.tproxy.dns_port')
TPROXY_MARK=$(_sval '.tproxy.mark')
TPROXY_FWMARK=$(_sval '.tproxy.fwmark')
ROUTE_TABLE=$(_sval '.tproxy.route_table')
if [ -z "$TPROXY_PORT" ] || [ -z "$DNS_PORT" ] || [ -z "$TPROXY_MARK" ] ||
    [ -z "$TPROXY_FWMARK" ] || [ -z "$ROUTE_TABLE" ]; then
    _fail "Не удалось определить параметры TProxy: нет ни $SETTINGS_JSON, ни $SETTINGS_DEFAULTS"
    exit 1
fi

# 1. Процесс
printf "[1] Xray process:\n"
pgrep -a xray >/dev/null && _ok "Xray запущен" || _fail "Xray НЕ запущен"

# 2. Порты
printf "\n[2] Listening on port %s:\n" "$TPROXY_PORT"
_listen | grep -q ":$TPROXY_PORT" && \
    _ok "Порт $TPROXY_PORT слушается" || \
    _warn "Порт $TPROXY_PORT не найден в ss (для TProxy это норма)"

# 3. Конфиг (TProxy + Mark)
printf "\n[3] Config Xray:\n"
CFG="/etc/xray/config.json"
[ -f "$CFG" ] || { _fail "$CFG отсутствует!"; exit 1; }
if jq -e 'any(.inbounds[]?; .streamSettings.sockopt.tproxy == "tproxy")' "$CFG" >/dev/null 2>&1; then
    _ok "TProxy включён в inbound"
else
    _fail "TProxy не настроен"
fi
if jq -e "any(.outbounds[]?; .streamSettings.sockopt.mark == $TPROXY_MARK)" "$CFG" >/dev/null 2>&1; then
    _ok "Mark $TPROXY_MARK на месте (sockopt) — loop prevention через OUTPUT"
else
    _warn "Mark $TPROXY_MARK не найден (может быть не указан явно)"
fi

# 4. nftables (таблица inet xray_prerouting с собственным хуком prerouting)
printf "\n[4] nftables (inet xray_prerouting):\n"
CHAIN_EXISTS=$(nft list table inet xray_prerouting 2>/dev/null)
if [ -n "$CHAIN_EXISTS" ]; then
    _ok "Таблица inet xray_prerouting загружена"

    # Правила живут в собственной таблице с хуком prerouting — fw4 их не сносит
    echo "$CHAIN_EXISTS" | grep -q "type filter hook prerouting priority mangle - 5" && \
        _ok "Хук prerouting priority mangle - 5 настроен (раньше fw4)" || \
        _warn "Хук prerouting priority mangle - 5 не найден"
    
    # Проверяем bypass DNS (порт 53)
    echo "$CHAIN_EXISTS" | grep -qE 'dport.*53.*return' && \
        _ok "DNS (порт 53) исключён из TProxy" || \
        _warn "DNS (порт 53) не исключён явно (может быть не нужно)"

    # Проверяем bypass прокси-серверов
    BYPASS_CNT=$(echo "$CHAIN_EXISTS" | grep -c "ip daddr.*return")
    [ "$BYPASS_CNT" -gt 0 ] && _ok "Bypass для серверов: $BYPASS_CNT правил" || _warn "Bypass для серверов не найден"

    # Проверяем TProxy правилa
    echo "$CHAIN_EXISTS" | grep -q "tproxy ip to 127.0.0.1:$TPROXY_PORT" && \
        _ok "TProxy на порт $TPROXY_PORT настроен" || \
        _fail "TProxy на порт $TPROXY_PORT НЕ настроен!"

    # Проверяем блокировку QUIC
    echo "$CHAIN_EXISTS" | grep -q "udp dport 443 drop" && \
        _ok "Блокировка QUIC настроена" || \
        _warn "Блокировка QUIC не настроена"
else
    _fail "Таблица inet xray_prerouting отсутствует — TProxy не работает!"
fi

# 5. OUTPUT: трафик самого роутера (отдельная таблица type route)
printf "\n[5] nftables OUTPUT (inet xray_self):\n"
SELF_CHAIN=$(nft list chain inet xray_self output 2>/dev/null)
if [ -n "$SELF_CHAIN" ]; then
    if echo "$SELF_CHAIN" | grep -qE "type route hook output priority mangle"; then
        _ok "Цепочка xray_self: type route hook output priority mangle"
    else
        _fail "Цепочка xray_self есть, но без type route — mark не повлияет на маршрутизацию"
    fi

    echo "$SELF_CHAIN" | grep -qE "meta mark (0x0*$TPROXY_MARK|$TPROXY_MARK) return" && \
        _ok "Loop prevention (mark $TPROXY_MARK return) настроена" || \
        _warn "Loop prevention (mark $TPROXY_MARK return) не найдена"

    echo "$SELF_CHAIN" | grep -qE "mark set (0x0*$TPROXY_FWMARK|$(printf '0x%08x' "$TPROXY_FWMARK")|$TPROXY_FWMARK)\$" && \
        _ok "Маркировка трафика роутера (mark $TPROXY_FWMARK) настроена" || \
        _warn "Маркировка трафика роутера не найдена"
else
    _warn "Таблица inet xray_self отсутствует (трафик роутера не проксируется)"
fi

# Устаревшая схема через fw4 output (type filter) не работает — предупреждаем, если осталась
if nft list chain inet fw4 xray_output >/dev/null 2>&1; then
    _warn "Найдена устаревшая цепочка fw4 xray_output — перезапусти update_nft.py"
fi

# 6. Routing
printf "\n[6] Policy Routing:\n"
ip rule show 2>/dev/null | grep -qE "fwmark (0x0*$TPROXY_FWMARK|$TPROXY_FWMARK) lookup ($ROUTE_TABLE|xray)" && _ok "ip rule fwmark $TPROXY_FWMARK → table $ROUTE_TABLE" || _fail "ip rule отсутствует"
ip route show table 100 2>/dev/null | grep -q "local default" && _ok "Таблица 100: local default dev lo" || _fail "Таблица 100 неверна"

# 7. dnsmasq → Xray DNS (tproxy.dns_port)
printf "\n[7] DNS Forwarding (dnsmasq → Xray:%s):\n" "$DNS_PORT"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#$DNS_PORT" && \
    _ok "dnsmasq → 127.0.0.1:$DNS_PORT" || _fail "dnsmasq НЕ настроен на Xray DNS ($DNS_PORT)"

# 8. Ошибки Xray
printf "\n[8] Ошибки Xray:\n"
ERR_LOG="/tmp/log/xray-error.log"
if [ -s "$ERR_LOG" ]; then
    tail -3 "$ERR_LOG" | while read -r line; do printf "  → %s\n" "$line"; done
else
    # Пустой файл не доказывает отсутствие ошибок: журнал ошибок может быть отключён
    # или, как в пресете normal, писаться не в файл, а в stdout → syslog
    PRESET=$(jq -r '.log.preset // empty' /etc/xray/settings.json 2>/dev/null)
    case "$PRESET" in
    quiet)
        _ok "журнал ошибок отключён пресетом log.preset=quiet (это ожидаемо)"
        ;;
    debug)
        _warn "$ERR_LOG пуст или отсутствует — журнал ошибок Xray не ведётся"
        ;;
    *)
        _ok "журнал ошибок Xray пишется в syslog (log.preset=${PRESET:-normal}) — см. вывод ниже"
        ;;
    esac
fi
# В пресете normal ошибки Xray идут в syslog напрямую, плюс init.d пишет туда же
# через logger -t xray — это основной источник, когда файлового журнала нет
if command -v logread >/dev/null 2>&1; then
    SYSLOG_LINES=$(logread -e xray 2>/dev/null | tail -3)
    if [ -n "$SYSLOG_LINES" ]; then
        printf "  syslog (Xray и logger -t xray):\n"
        printf "%s\n" "$SYSLOG_LINES" | while read -r line; do printf "  → %s\n" "$line"; done
    fi
fi

# 9. Доступность сервера
printf "\n[9] Доступность сервера:\n"
SERVER=$(jq -r '[.outbounds[]?.settings.vnext[]?.address] | first // empty' "$CFG" 2>/dev/null)
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
if ! nft list table inet xray_prerouting 2>/dev/null | grep -q "tproxy ip to 127.0.0.1:$TPROXY_PORT"; then
    printf "[FIX NFT] TProxy правила отсутствуют — выполни:\n"
    printf "  python3 -B /usr/share/xray/update_nft.py\n"
fi
if ! uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#$DNS_PORT"; then
    printf "[FIX DNSMASQ] Выполни:\n"
    printf "  uci set dhcp.@dnsmasq[0].noresolv='1'\n"
    printf "  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#%s'\n" "$DNS_PORT"
    printf "  uci commit && /etc/init.d/dnsmasq restart\n"
fi
printf "\n=== END ===\n"