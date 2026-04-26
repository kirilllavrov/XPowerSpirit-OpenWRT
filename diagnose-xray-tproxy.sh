#!/bin/sh

echo "=== Xray TProxy DEEP DIAGNOSTICS ==="

# 1. Xray process
echo
echo "[1] Xray process:"
pgrep -a xray || echo "Xray НЕ запущен"

# 2. Проверка, какой конфиг реально использует init.d
echo
echo "[2] UCI config (/etc/config/xray):"
uci show xray 2>/dev/null || echo "UCI-конфиг отсутствует!"

# 3. Проверка config.json на ошибки
echo
echo "[3] Проверка config.json (xray run -test):"
xray run -test -config /etc/xray/config.json 2>&1 | sed 's/^/    /'

# 4. Проверка слушает ли порт 12345
echo
echo "[4] Listening on port 12345:"
netstat -tulnp 2>/dev/null | grep 12345 || echo "Порт 12345 НЕ слушается!"

# 5. Проверка конфликта DNS (порт 53)
echo
echo "[5] Конфликт порта 53:"
netstat -tulnp 2>/dev/null | grep ":53" || echo "Порт 53 свободен"

# 6. Проверка inbound tproxy-in
echo
echo "[6] Проверка inbound tproxy-in:"
grep -R "tproxy" /etc/xray/config.json || echo "В config.json нет inbound с tproxy!"

# 7. nftables: порядок prerouting
echo
echo "[7] Порядок prerouting в ruleset:"
nft list ruleset | grep -n "prerouting" | sed 's/^/    /'

# 8. nftables table ip xray
echo
echo "[8] nftables table ip xray:"
nft list table ip xray 2>/dev/null || echo "Таблица ip xray отсутствует!"

# 9. nftables counters
echo
echo "[9] nftables counters (цепочка xray_tproxy):"
nft -a list chain ip xray xray_tproxy 2>/dev/null | grep -E "packets|bytes" || echo "Нет счётчиков — пакеты НЕ попадают в цепочку!"

# 10. Проверка fw4 include
echo
echo "[10] Проверка fw4 include:"
ls -l /usr/share/nftables.d/ruleset-post/ | sed 's/^/    /'

# 11. Проверка policy routing
echo
echo "[11] ip rule:"
ip rule || echo "ip rule не работает"

echo
echo "[12] ip route table xray:"
ip route show table xray || echo "Таблица маршрутизации xray пуста!"

# 12. sysctl
echo
echo "[13] sysctl route_localnet:"
sysctl net.ipv4.conf.all.route_localnet

echo
echo "[14] sysctl ip_forward:"
sysctl net.ipv4.ip_forward

# 13. DNS test
echo
echo "[15] DNS test через Xray:"
nslookup google.com 127.0.0.1 || echo "DNS через Xray НЕ работает!"

# 14. DHCP test
echo
echo "[16] DHCP test:"
udhcpc -n -q -t 1 || echo "DHCP НЕ работает — nftables может ломать DHCP!"

# 15. Проверка трафика на br-lan до TProxy
echo
echo "[17] Трафик на br-lan (tcpdump 3 сек):"
timeout 3 tcpdump -ni br-lan 2>/dev/null | head || echo "Нет трафика на br-lan!"

# 16. Проверка трафика до Xray
echo
echo "[18] Трафик на lo:12345 (tcpdump 3 сек):"
timeout 3 tcpdump -ni lo port 12345 2>/dev/null || echo "На lo:12345 НЕТ пакетов!"

# 17. Логи Xray
echo
echo "[19] Логи Xray:"
tail -n 50 /tmp/log/xray-error.log 2>/dev/null || echo "Логов нет"

echo
echo "=== END ==="
