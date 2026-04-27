#!/bin/sh
# Xray TProxy Deep Diagnostics — улучшенная версия

echo "=== Xray TProxy DEEP DIAGNOSTICS ==="

# 1. Процессы Xray
echo "[1] Xray process:"
pgrep -a xray || echo "Xray НЕ запущен"

# 2. Порт 12345
echo
echo "[2] Listening on port 12345:"
netstat -tulnp 2>/dev/null | grep 12345 || ss -tulnp 2>/dev/null | grep 12345 || echo "Порт 12345 НЕ слушается!"

# 3. Inbound tproxy-in
echo
echo "[3] Проверка inbound tproxy-in:"
grep -A 20 '"tag": "tproxy-in"' /etc/xray/config.json 2>/dev/null || echo "В config.json нет inbound tproxy-in!"

# 4. nftables — полная информация
echo
echo "[4] nftables table ip xray:"
nft list table ip xray 2>/dev/null || echo "Таблица ip xray отсутствует!"

echo
echo "[5] nftables chain xray_tproxy (счётчики):"
nft -a list chain ip xray xray_tproxy 2>/dev/null || echo "Цепочка xray_tproxy отсутствует!"

# 6. Порядок правил в prerouting
echo
echo "[6] Порядок prerouting chains:"
nft list ruleset | grep -E "prerouting|hook prerouting" -A 5

# 7. ip rule и route
echo
echo "[7] ip rule:"
ip rule show

echo
echo "[8] ip route table xray:"
ip route show table xray 2>/dev/null || echo "Таблица xray отсутствует или пуста!"

# 8. sysctl
echo
echo "[9] sysctl route_localnet:"
sysctl net.ipv4.conf.all.route_localnet

echo "[10] sysctl ip_forward:"
sysctl net.ipv4.ip_forward

# 9. DNS
echo
echo "[11] DNS test через Xray:"
nslookup google.com 127.0.0.1 || echo "DNS через Xray НЕ работает!"

# 10. Трафик
echo
echo "[12] Трафик на lo:12345 (tcpdump 5 сек):"
timeout 5 tcpdump -ni lo port 12345 -c 10 2>/dev/null || echo "На lo:12345 пакетов НЕТ!"

echo
echo "[13] Трафик на br-lan (tcpdump 5 сек, только новые соединения):"
timeout 5 tcpdump -ni br-lan 'tcp or udp' -c 5 2>/dev/null || echo "Трафик на br-lan не пойман"

# 11. Логи Xray
echo
echo "[14] Последние логи Xray:"
logread | grep -i xray | tail -15 || echo "Логов Xray нет"

# 12. Интерфейсы
echo
echo "[15] Сетевые интерфейсы:"
ip -br link show | grep -E 'br-lan|lan|eth'

echo
echo "=== END ==="