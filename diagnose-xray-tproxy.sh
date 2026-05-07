#!/bin/sh
# Xray TProxy — Глубокая диагностика (v4)
echo "=== Xray TProxy DEEP DIAGNOSTICS v4 ==="

# Хелперы статуса
_ok()   { echo "[OK]   $1"; }
_warn() { echo "[WARN] $1"; }
_fail() { echo "[FAIL] $1"; }

# 1. Процесс
printf "\n[1] Xray process:\n"
pgrep -a xray >/dev/null && _ok "Xray запущен" || _fail "Xray НЕ запущен"

# 2. Порты (TProxy не показывает LISTEN, проверяем через ss)
printf "\n[2] Listening on port 12345:\n"
if ss -ulnp 2>/dev/null | grep -q ':12345' || ss -tlnp 2>/dev/null | grep -q ':12345'; then
    _ok "Порт 12345 активен (LISTEN)"
else
    _warn "Порт 12345 не виден в ss (норма для TProxy — сокет открывается при первом пакете)"
fi

# 3. Конфиг (TProxy + Mark)
printf "\n[3] Конфигурация Xray:\n"
CFG="/etc/xray/config.json"
[ -f "$CFG" ] || { _fail "$CFG отсутствует!"; exit 1; }
grep -q '"tproxy": "tproxy"' "$CFG" && _ok "TProxy включён в inbound" || _fail "TProxy не настроен"
grep -q '"mark": 255' "$CFG" && _ok "Mark 255 (исключение трафика Xray) на месте" || _fail "Mark 255 отсутствует! Трафик уйдёт в цикл."

# 4. nftables — таблица inet xray (family=inet, как создаётся update-nft.sh)
printf "\n[4] Правила nftables (inet xray):\n"
if nft list table inet xray >/dev/null 2>&1; then
    _ok "Таблица inet xray загружена"
    # Проверка hook/priority в цепочке prerouting
    if nft list chain inet xray prerouting 2>/dev/null | grep -q "type filter hook prerouting priority mangle"; then
        _ok "Цепочка prerouting хукает mangle priority"
    else
        _fail "Цепочка inet xray prerouting не найдена или имеет неверный hook"
    fi
    # Проверка, что трафик на DHCP-порты исключён
    if nft list chain inet xray prerouting 2>/dev/null | grep -qE 'dport.*67|dport.*68'; then
        _ok "DHCP (67/68) исключён из TProxy"
    else
        _warn "DHCP-исключение не обнаружено"
    fi
else
    _fail "Таблица inet xray отсутствует!"
fi

# 5. Policy Routing
printf "\n[5] Policy Routing:\n"
ip -4 rule show | grep -q "fwmark 0x1 lookup" && _ok "ip rule с fwmark 0x1 настроен" || _fail "ip rule отсутствует"
ip route show table 100 2>/dev/null | grep -q "local" && _ok "Таблица маршрутов 100 верна" || \
    ip route show table xray 2>/dev/null | grep -q "local" && _ok "Таблица маршрутов xray верна" || \
    _fail "Таблица маршрутов (100/xray) не настроена"

# 6. dnsmasq → https-dns-proxy (порты 5053/5054)
printf "\n[6] DNS Forwarding (dnsmasq → https-dns-proxy):\n"
if uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -qE "127\.0\.0\.1#505[34]"; then
    _ok "dnsmasq перенаправляет на https-dns-proxy (5053/5054)"
else
    _fail "dnsmasq НЕ настроен на https-dns-proxy:5053/5054"
fi

# 7. Ошибки Xray
printf "\n[7] Ошибки Xray (/tmp/log/xray-error.log):\n"
if [ -s /tmp/log/xray-error.log ]; then
    tail -3 /tmp/log/xray-error.log | while IFS= read -r line; do echo "  → $line"; done
else
    _ok "Ошибок в логах нет (или лог пустой)"
fi

# 8. Доступность сервера
printf "\n[8] Доступность VLESS сервера:\n"
SERVER=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address", "")
            if addr and addr not in ("0.0.0.0", "127.0.0.1", "hole"):
                print(addr)
                break
except Exception:
    pass
' "$CFG" 2>/dev/null | head -1)
if [ -n "$SERVER" ]; then
    echo "  Проверка $SERVER..."
    if curl -sI -m 3 "https://$SERVER" >/dev/null 2>&1; then
        _ok "Доступен (HTTPS)"
    elif ping -c 1 -W 2 "$SERVER" >/dev/null 2>&1; then
        _ok "Доступен (ICMP)"
    else
        _warn "Сервер не отвечает (Reality может дропать зонды — это норма)"
    fi
else
    _warn "Адрес сервера не найден в config.json"
fi

# 9. DNS-тест через dnsmasq
printf "\n[9] DNS-тест через локальный dnsmasq:\n"
nslookup google.com 127.0.0.1 2>/dev/null | grep -q "Address" && _ok "dnsmasq отвечает" || _warn "Локальный DNS не отвечает"
printf "\n[9b] DNS-тест через 1.1.1.1:\n"
nslookup google.com 1.1.1.1 2>/dev/null | grep -q "Address" && _ok "1.1.1.1 DNS отвечает" || _warn "1.1.1.1 DNS не отвечает"

# === АВТО-РЕКОМЕНДАЦИИ ===
printf "\n🔧 РЕКОМЕНДАЦИИ:\n"
if ! nft list table inet xray >/dev/null 2>&1; then
    echo "[FIX NFTABLES] Таблица inet xray отсутствует. Выполни:"
    echo "  /usr/share/xray/update-nft.sh"
fi
if ! uci show dhcp.@dnsmasq[0].server 2>/dev/null | grep -qE "127\.0\.0\.1#505[34]"; then
    echo "[FIX DNSMASQ] dnsmasq не направлен на https-dns-proxy. Выполни:"
    echo "  uci set dhcp.@dnsmasq[0].noresolv='1'"
    echo "  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5053'"
    echo "  uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5054'"
    echo "  uci commit dhcp && /etc/init.d/dnsmasq restart"
fi
if grep -q '"mark": 255' "$CFG" 2>/dev/null; then
    echo "[OK] Конфиг валиден. Если сайты не грузятся → очистите DNS-кэш на клиенте."
fi
echo "=== END ==="

echo ""
echo "На клиенте (Windows / Linux):"
echo "curl -v --interface 192.168.1.138 http://ipinfo.io/ip"