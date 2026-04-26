#!/bin/sh
# update-xray.sh — обновление Xray-core, geoip/geosite, подписки и генерация конфига
# OpenWrt 25.12.x (apk-based)

set -e

LOG="/var/log/xray-update.log"

SUB_FILE="/etc/xray/subscription.url"
CONFIG_JSON="/etc/xray/config.json"
HWID_FILE="/etc/xray/hwid"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo "===== $(date) =====" >> "$LOG"

# -----------------------------
# 1. Проверка подписки
# -----------------------------
if [ ! -f "$SUB_FILE" ]; then
    echo "Ошибка: нет файла подписки $SUB_FILE" >> "$LOG"
    exit 1
fi

SUB_URL=$(cat "$SUB_FILE")

if [ -z "$SUB_URL" ]; then
    echo "Ошибка: пустой URL подписки" >> "$LOG"
    exit 1
fi

# -----------------------------
# 2. HWID (persistent)
# -----------------------------
if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi

echo "[HWID] $HWID" >> "$LOG"

# -----------------------------
# 3. Обновление Xray-core
# -----------------------------
echo "[1] Обновление Xray-core..." >> "$LOG"
apk update >> "$LOG" 2>&1
apk add xray-core >> "$LOG" 2>&1

# -----------------------------
# 4. Обновление geoip/geosite
# -----------------------------
echo "[2] Обновление geoip/geosite..." >> "$LOG"
curl -fsSL "$GEOIP_URL" -o /etc/xray/geoip.dat
curl -fsSL "$GEOSITE_URL" -o /etc/xray/geosite.dat

# -----------------------------
# 5. Генерация config.json
# -----------------------------
echo "[3] Обновляем config.json..." >> "$LOG"

curl -s -L -m 15 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" | python3 "$PARSER" | python3 "$GENERATOR" \
    --geoip /etc/xray/geoip.dat \
    --geosite /etc/xray/geosite.dat \
    --output "$CONFIG_JSON" >> "$LOG" 2>&1

if [ ! -s "$CONFIG_JSON" ]; then
    echo "Ошибка: генератор не создал config.json" >> "$LOG"
    exit 1
fi

# -----------------------------
# 6. Перезапуск Xray
# -----------------------------
echo "[4] Перезапуск Xray..." >> "$LOG"
/etc/init.d/xray restart >> "$LOG" 2>&1

echo "Готово." >> "$LOG"
