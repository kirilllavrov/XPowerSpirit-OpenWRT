#!/bin/sh
# OpenWrt — Настройка LED для индикации интернета и Xray
# Проверено для Cudy WR3000S v1
# Проверить наличие LED: ls /sys/class/leds/

echo "=== Настройка LED Xray ==="

# Проверяем, существуют ли LED
if [ ! -d "/sys/class/leds/white:wps" ]; then
    echo "[X] LED white:wps не найден"
    exit 1
fi
if [ ! -d "/sys/class/leds/white:wan-online" ]; then
    echo "[X] LED white:wan-online не найден"
    exit 1
fi

# Удаляем ВСЕ старые LED-конфигурации
while uci -q delete system.@led[0]; do :; done 2>/dev/null || true
uci commit system
service led restart

# LED 1: Xray трафик (wps мигает при трафике через lo)
uci add system led >/dev/null
uci set system.@led[-1].name='Xray_Status'
uci set system.@led[-1].sysfs='white:wps'
uci set system.@led[-1].trigger='netdev'
uci set system.@led[-1].interval='100'
uci set system.@led[-1].dev='lo'
uci set system.@led[-1].mode='tx rx'
uci commit system
service led restart

# LED 2: Интернет (проверка через probe-URL из settings.json → health.probe_url)
cat > /usr/share/xray/net-check.sh << 'EOF'
#!/bin/sh
# Адрес проверки берётся из настроек: он же используется burstObservatory,
# поэтому лампочка и балансировщик проверяют один и тот же endpoint.
# Второго набора значений по умолчанию нет: если ключа нет в settings.json,
# он берётся из эталона — иначе адрес в коде разошёлся бы с эталоном
SETTINGS=/etc/xray/settings.json
DEFAULTS=/usr/share/xray/settings.default.json
FAILS=/tmp/.xray-wan-check-fails
LED=/sys/class/leds/white:wan-online/trigger

PROBE_URL=$(jq -r '.health.probe_url // empty' "$SETTINGS" 2>/dev/null)
[ -n "$PROBE_URL" ] || PROBE_URL=$(jq -r '.health.probe_url // empty' "$DEFAULTS" 2>/dev/null)
# Проверять нечего — состояние лампочки не трогаем: незаполненные настройки
# не означают «интернета нет»
[ -n "$PROBE_URL" ] || exit 1

# Проверка идёт через прокси, поэтому без запущенного Xray интернета для
# клиентов нет: гасим сразу и не тратим запрос впустую
if ! pidof xray >/dev/null 2>&1; then
    echo "none" > "$LED"
    exit 0
fi

if curl -fs --max-time 5 "$PROBE_URL" >/dev/null 2>&1; then
    echo 0 > "$FAILS"
    echo "default-on" > "$LED"
else
    # Одиночный сбой (потерянный пакет, таймаут узла) не должен гасить
    # индикатор: гасим после двух промахов подряд, то есть примерно через 2 минуты
    fails=$(cat "$FAILS" 2>/dev/null || echo 0)
    fails=$((fails + 1))
    echo "$fails" > "$FAILS"
    [ "$fails" -ge 2 ] && echo "none" > "$LED"
fi
exit 0
EOF
chmod +x /usr/share/xray/net-check.sh

# Добавляем в cron
CRON_ENTRY="* * * * * /usr/share/xray/net-check.sh"
if ! crontab -l 2>/dev/null | grep -qF "net-check.sh"; then
    (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
    echo "[+] Cron-задача для индикации интернета добавлена"
fi
service cron restart

# Первая проверка сразу
sleep 10
/usr/share/xray/net-check.sh

echo "[+] LED настроены:"
echo "    white:wps        — мигает при трафике Xray (lo)"
echo "    white:wan-online — горит при доступе в интернет (проверка раз в минуту)"