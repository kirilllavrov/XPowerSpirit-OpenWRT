#!/bin/sh
# Xray TProxy — Глубокая диагностика (v3)
echo "=== Xray TProxy DEEP DIAGNOSTICS v3 ==="

# Хелперы статуса
_ok()   { echo "[OK]   $1"; }
_warn() { echo "[WARN] $1"; }
_fail() { echo "[FAIL] $1"; }

# 1. Процесс
echo "[1] Xray process:"
pgrep -a xray >/dev/null && _ok "Xray запущен" || _fail "Xray НЕ запущен"

# 2. Порт 12345
echo -e "\n[2] Listening on port 12345:"
(netstat -tulnp 2>/dev/null || ss -tulnp 2>/dev/null) | grep -q ':12345' && \
  _ok "Порт 12345 активен (LISTEN не отображается для TProxy — это норма)" || \
  _fail "Порт 12345 не слушается"

# 3. Конфиг (TProxy + Mark)
echo -e "\n[3] Конфигурация Xray:"
CFG="/etc/xray/config.json"
[ -f "$CFG" ] || { _fail "$CFG отсутствует!"; exit 1; }
grep -q '"tproxy": "tproxy"' "$CFG" && _ok "TProxy включён в inbound" || _fail "TProxy не настроен"
grep -q '"mark": 255' "$CFG" && _ok "Mark 255 (исключение трафика Xray) на месте" || _fail "Mark 255 отсутствует! Трафик уйдёт в цикл."

# 4. nftables (критично: исключение DNS)
echo -e "\n[4] Правила nftables (ip xray):"
if nft list table ip xray 2>/dev/null >/dev/null; then
    _ok "Таблица ip xray загружена"
    # Проверка исключения порта 53
    if nft list chain ip xray xray_tproxy 2>/dev/null | grep -qE 'dport.*53.*return'; then
        _ok "DNS (порт 53) ИСКЛЮЧЁН из TProxy"
    else
        _fail "DNS (порт 53) НЕ исключён! ГЛАВНАЯ ПРИЧИНА: 'сайты не грузятся'"
    fi
    # Проверка hook/priority
    if nft list chain ip xray xray_tproxy 2>/dev/null | grep -q "type filter hook prerouting priority mangle"; then
        _ok "Цепочка хукает prerouting priority mangle"
    else
        _fail "Цепочка имеет неверный hook/priority"
    fi
else
    _fail "Таблица ip xray отсутствует!"
fi

# 5. Интеграция с fw4
echo -e "\n[5] Интеграция с fw4:"
if nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep -q "jump xray_tproxy"; then
    _ok "jump xray_tproxy вставлен в fw4"
else
    _warn "jump отсутствует (не критично, цепочка работает автономно)"
fi

# 6. Routing
echo -e "\n[6] Policy Routing:"
ip -4 rule show | grep -q "fwmark 0x1 lookup xray" && _ok "ip rule настроен" || _fail "ip rule отсутствует"
ip route show table xray 2>/dev/null | grep -q "local default" && _ok "Таблица маршрутов xray верна" || _fail "Таблица маршрутов xray неверна"

# 7. dnsmasq → 1053
echo -e "\n[7] DNS Forwarding (dnsmasq):"
uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#1053" && \
  _ok "dnsmasq перенаправляет на Xray:1053" || _fail "dnsmasq НЕ настроен на Xray"

# 8. Ошибки Xray
echo -e "\n[8] Ошибки Xray (/tmp/log/xray-error.log):"
if [ -s /tmp/log/xray-error.log ]; then
    tail -3 /tmp/log/xray-error.log | while read -r line; do echo "  → $line"; done
else
    _ok "Ошибок в логах нет"
fi

# 9. Доступность сервера
echo -e "\n[9] Доступность VLESS сервера:"
SERVER=$(grep -o '"address": "[^"]*"' "$CFG" | head -1 | cut -d'"' -f4)
if [ -n "$SERVER" ]; then
    echo -n "  Проверка $SERVER... "
    curl -sI -m 3 "https://$SERVER" >/dev/null 2>&1 && _ok "Доступен (HTTPS)" || \
    ping -c 1 -W 2 "$SERVER" >/dev/null 2>&1 && _ok "Доступен (ICMP)" || _warn "Сервер не отвечает (Reality может дропать зонды — это норма)"
else
    _warn "Адрес сервера не найден"
fi

# 10. Быстрый DNS-тест
echo -e "\n[10] Локальный DNS-тест:"
nslookup google.com 127.0.0.1 2>/dev/null | grep -q "Address:" && _ok "Xray DNS отвечает" || _warn "Локальный DNS не отвечает"

# === АВТО-РЕКОМЕНДАЦИИ ===
echo -e "\n🔧 РЕКОМЕНДАЦИИ:"
if ! nft list chain ip xray xray_tproxy 2>/dev/null | grep -qE 'dport.*53.*return'; then
    echo "[FIX DNS] Выполни:"
    echo "nft delete table ip xray; /etc/init.d/xray-tproxy-rules restart"
fi
if ! uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.1#1053"; then
    echo "[FIX DNSMASQ] Выполни:"
    echo "uci set dhcp.@dnsmasq[0].noresolv='1'"
    echo "uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#1053' && uci commit && /etc/init.d/dnsmasq restart"
fi
if grep -q '"mark": 255' "$CFG" 2>/dev/null; then
    echo "[OK] Конфиг валиден. Если сайты не грузятся → очистите DNS-кэш на клиенте."
fi
echo "=== END ==="