#!/bin/sh
# Xray TProxy — улучшенная глубокая диагностика (v2)

echo "=== Xray TProxy DEEP DIAGNOSTICS v2 ==="

# 1. Процесс Xray
echo "[1] Xray process:"
pgrep -a xray || echo "Xray НЕ запущен"

# 2. Порт 12345
echo
echo "[2] Listening on port 12345:"
netstat -tulnp 2>/dev/null | grep -E ':12345' || ss -tulnp 2>/dev/null | grep -E ':12345' || echo "Порт 12345 НЕ слушается!"

# 3. Inbound tproxy-in
echo
echo "[3] Inbound tproxy-in в config:"
grep -A 30 '"tag": "tproxy-in"' /etc/xray/config.json 2>/dev/null || echo "tproxy-in не найден"

# 4. nftables — полная таблица
echo
echo "[4] nftables table ip xray (полная):"
nft list table ip xray 2>/dev/null || echo "Таблица ip xray отсутствует!"

echo
echo "[5] nftables chain xray_tproxy с счётчиками:"
nft -a list chain ip xray xray_tproxy 2>/dev/null || echo "Цепочка xray_tproxy отсутствует!"

# 6. Порядок правил в mangle_prerouting
echo
echo "[6] Порядок в mangle_prerouting:"
nft list chain inet fw4 mangle_prerouting 2>/dev/null || nft list chain ip fw4 mangle_prerouting 2>/dev/null

# 7. ip rule и route
echo
echo "[7] ip rule:"
ip -4 rule show

echo
echo "[8] ip route table xray:"
ip route show table xray 2>/dev/null || echo "Таблица xray отсутствует!"

# 8. sysctl
echo
echo "[9] sysctl:"
sysctl net.ipv4.conf.all.route_localnet
sysctl net.ipv4.ip_forward

# 9. DNS
echo
echo "[10] DNS test через 127.0.0.1:"
nslookup google.com 127.0.0.1 || echo "DNS REFUSED или не работает"

# 10. Трафик
echo
echo "[11] Трафик на lo:12345 (tcpdump 5 сек):"
timeout 5 tcpdump -ni lo port 12345 -c 8 2>/dev/null || echo "На lo:12345 пакетов НЕТ!"

echo
echo "[12] Трафик на br-lan (tcpdump 5 сек):"
timeout 5 tcpdump -ni br-lan 'tcp or udp' and not port 53 -c 5 2>/dev/null || echo "Трафик на br-lan не пойман"

# 11. Логи
echo
echo "[13] Последние логи Xray:"
logread | grep -iE 'xray|tproxy' | tail -20 || echo "Логов нет"

# 12. Интерфейсы
echo
echo "[14] Сетевые интерфейсы:"
ip -br link show | grep -E 'br-lan|lan|eth|wan'

echo
echo "=== END ==="
echo "Рекомендация: после запуска тестового трафика (curl google.com с клиента) запусти диагностику снова."