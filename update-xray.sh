#!/bin/sh
# update-xray.sh — обновление Xray-core, geosite/geoip, подписки и генерация конфига
# OpenWrt 25.12.x (apk-based)

set -e

LOG="/var/log/xray-update.log"

SUB_FILE="/etc/xray/subscription.url"
OUTBOUND_JSON="/etc/xray/outbound.json"
CONFIG_JSON="/etc/xray/config.json"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.py"

# Твои собственные сборки geosite/geoip
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
# 2. Обновление Xray-core
# -----------------------------
echo "[1] Обновление Xray-core..." >> "$LOG"
apk update >> "$LOG" 2>&1
apk add xray-core >> "$LOG" 2>&1

# -----------------------------
# 3. Обновление geoip/geosite
# -----------------------------
echo "[2] Обновление geoip/geosite..." >> "$LOG"
curl -fsSL "$GEOIP_URL" -o /etc/xray/geoip.dat
curl -fsSL "$GEOSITE_URL" -o /etc/xray/geosite.dat

# -----------------------------
# 4. Парсинг подписки (исправлено!)
# -----------------------------
echo "[3] Парсим подписку → outbound.json..." >> "$LOG"

printf '%s\n' "$SUB_URL" | python3 "$PARSER" > "$OUTBOUND_JSON" 2>>"$LOG"

if [ ! -s "$OUTBOUND_JSON" ]; then
    echo "Ошибка: парсер не создал outbound.json" >> "$LOG"
    exit 1
fi

# -----------------------------
# 5. Генерация полного config.json
# -----------------------------
echo "[4] Генерация config.json через генератор..." >> "$LOG"

python3 "$GENERATOR" \
    --outbound "$OUTBOUND_JSON" \
    --geoip /etc/xray/geoip.dat \
    --geosite /etc/xray/geosite.dat \
    --output "$CONFIG_JSON" >> "$LOG" 2>&1

# -----------------------------
# 6. Перезапуск Xray
# -----------------------------
echo "[5] Перезапуск Xray..." >> "$LOG"
/etc/init.d/xray restart >> "$LOG" 2>&1

echo "Готово." >> "$LOG"
