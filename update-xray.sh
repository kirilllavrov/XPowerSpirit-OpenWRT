#!/bin/sh
# update-xray.sh — обновление Xray-core, geosite/geoip, подписки и генерация конфига
# OpenWrt 25.12.x (apk-based)

set -e

LOG="/var/log/xray-update.log"

SUB_FILE="/etc/xray/subscription.url"
OUTBOUND_JSON="/etc/xray/outbound.json"
CONFIG_JSON="/etc/xray/config.json"

GENERATOR="/root/xray-generate-config.py"
PARSER="/root/xray-sub-parser.sh"

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

echo "[1] Обновление Xray-core..." >> "$LOG"
apk update >> "$LOG" 2>&1
apk add xray-core >> "$LOG" 2>&1

# -----------------------------
# 2. Обновление geoip/geosite
# -----------------------------
echo "[2] Обновление geoip/geosite..." >> "$LOG"
curl -fsSL "$GEOIP_URL" -o /etc/xray/geoip.dat
curl -fsSL "$GEOSITE_URL" -o /etc/xray/geosite.dat

# -----------------------------
# 3. Скачивание подписки
# -----------------------------
echo "[3] Скачиваем подписку..." >> "$LOG"
SUB_DATA=$(curl -fsSL "$SUB_URL" || true)

if [ -z "$SUB_DATA" ]; then
    echo "Ошибка: подписка не скачана" >> "$LOG"
    exit 1
fi

# -----------------------------
# 4. Декодирование Base64
# -----------------------------
echo "[4] Декодируем Base64..." >> "$LOG"
DECODED=$(echo "$SUB_DATA" | base64 -d 2>/dev/null || true)

if [ -z "$DECODED" ]; then
    echo "Ошибка: подписка не декодируется (Base64)" >> "$LOG"
    exit 1
fi

# -----------------------------
# 5. Извлекаем VLESS
# -----------------------------
echo "[5] Извлекаем VLESS..." >> "$LOG"
VLESS=$(echo "$DECODED" | grep -o 'vless://[^ ]*' | head -n 1)

if [ -z "$VLESS" ]; then
    echo "Ошибка: VLESS не найден" >> "$LOG"
    exit 1
fi

# -----------------------------
# 6. Парсим VLESS → outbound.json
# -----------------------------
echo "[6] Парсим VLESS → outbound.json..." >> "$LOG"

"$PARSER" "$VLESS" > "$OUTBOUND_JSON"

# -----------------------------
# 7. Генерация полного config.json
# -----------------------------
echo "[7] Генерация config.json через генератор..." >> "$LOG"

python3 "$GENERATOR" \
    --outbound "$OUTBOUND_JSON" \
    --geoip /etc/xray/geoip.dat \
    --geosite /etc/xray/geosite.dat \
    --output "$CONFIG_JSON" >> "$LOG" 2>&1

# -----------------------------
# 8. Перезапуск Xray
# -----------------------------
echo "[8] Перезапуск Xray..." >> "$LOG"
/etc/init.d/xray restart >> "$LOG" 2>&1

echo "Готово." >> "$LOG"
