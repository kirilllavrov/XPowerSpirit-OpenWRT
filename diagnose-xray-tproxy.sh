#!/bin/sh
# Xray TProxy — Deep Diagnostics v4

echo "=== Xray TProxy DEEP DIAGNOSTICS v4 ==="

_ok() { echo "[OK]   $1"; }
_warn() { echo "[WARN] $1"; }
_fail() { echo "[FAIL] $1"; }

echo "[1] Xray process:"
pgrep -a xray && _ok "Xray запущен" || _fail "Xray НЕ запущен"

echo -e "\n[2] Порт 12345:"
netstat -tulnp 2>/dev/null | grep -E ':12345' && _ok "Порт 12345 слушается" || \
ss -tulnp 2>/dev/null | grep -E ':12345' && _ok "Порт 12345 слушается" || _fail "Порт 12345 НЕ слушается"

echo -e "\n[3] nftables table ip xray:"
nft list table ip xray 2>/dev/null || _fail "Таблица xray отсутствует"

echo -e "\n[4] Счётчики цепочки xray_tproxy:"
nft -a list chain ip xray xray_tproxy 2>/dev/null || _fail "Цепочка отсутствует"

echo -e "\n[5] ip rule:"
ip -4 rule show | grep -q "fwmark 0x1 lookup xray" && _ok "ip rule настроен" || _fail "ip rule отсутствует"

echo -e "\n[6] ip route table xray:"
ip route show table xray 2>/dev/null || _fail "Таблица xray пуста"

echo -e "\n[7] DNS test:"
nslookup google.com 127.0.0.1 >/dev/null 2>&1 && _ok "DNS через Xray работает" || _fail "DNS REFUSED"

echo -e "\n[8] Трафик на lo:12345 (5 сек):"
timeout 5 tcpdump -ni lo port 12345 -c 5 2>/dev/null || echo "Пакетов на lo:12345 нет"

echo -e "\n[9] Логи Xray:"
logread | grep -iE 'xray|tproxy|error' | tail -10

echo -e "\n[10] Сетевые интерфейсы:"
ip -br link show | grep -E 'br-lan|lan'

echo -e "\n=== END ==="
echo "Рекомендация: с клиента в LAN выполни 'curl -I https://www.google.com' и запусти диагностику снова."