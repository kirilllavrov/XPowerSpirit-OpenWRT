#!/bin/sh

echo "=== Xray TProxy DIAGNOSTICS ==="

# 1. Проверка процесса Xray
echo
echo "[1] Xray process:"
pgrep -a xray || echo "Xray НЕ запущен"

# 2. Проверка слушает ли порт 12345
echo
echo "[2] Listening on port 12345:"
netstat -tulnp 2>/dev/null | grep 12345 || echo "Порт 12345 НЕ слушается!"

# 3. Проверка inbound tproxy-in
echo
echo "[3] Проверка inbound tproxy-in:"
grep -R "tproxy" /etc/xray/config.json || echo "В config.json нет inbound с tproxy!"

# 4. Проверка таблицы nftables
echo
echo "[4] nftables table ip xray:"
nft list table ip xray 2>/dev/null || echo "Таблица ip xray отсутствует!"

# 5. Проверка, перехватывает ли nft пакеты
echo
echo "[5] nftables counters:"
nft -a list chain ip xray prerouting 2>/dev/null | grep -E "packets|bytes" || echo "Нет счётчиков — пакеты НЕ попадают в цепочку!"

# 6. Проверка policy routing
echo
echo "[6] ip rule:"
ip rule || echo "ip rule не работает"

echo
echo "[7] ip route table xray:"
ip route show table xray || echo "Таблица маршрутизации xray пуста!"

# 7. Проверка sysctl для TProxy
echo
echo "[8] sysctl route_localnet:"
sysctl net.ipv4.conf.all.route_localnet

echo
echo "[9] sysctl ip_forward:"
sysctl net.ipv4.ip_forward

# 8. Проверка DNS
echo
echo "[10] DNS test через Xray:"
nslookup google.com 127.0.0.1 || echo "DNS через Xray НЕ работает!"

# 9. Проверка DHCP (важно!)
echo
echo "[11] DHCP test:"
udhcpc -n -q -t 1 || echo "DHCP НЕ работает — nftables может ломать DHCP!"

# 10. Проверка, доходят ли пакеты до Xray
echo
echo "[12] Проверка трафика до Xray (tcpdump 3 сек):"
timeout 3 tcpdump -ni lo port 12345 2>/dev/null || echo "На lo:12345 НЕТ пакетов!"

echo
echo "=== END ==="
