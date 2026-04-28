#!/bin/sh
# update-xray.sh — версия с установкой из GitHub
# Обновление Xray-core, geoip/geosite, подписки и генерация конфига
# OpenWrt 25.12.x

set -e

LOG="/tmp/log/xray-update.log"

SUB_FILE="/etc/xray/subscription.url"
CONFIG_JSON="/etc/xray/config.json"
HWID_FILE="/etc/xray/hwid"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"

GEO_DIR="/usr/share/xray"
GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

echo "===== $(date) =====" >> "$LOG"

# 1. подписка
if [ ! -f "$SUB_FILE" ]; then
    echo "Ошибка: нет файла подписки $SUB_FILE" >> "$LOG"
    exit 1
fi

SUB_URL=$(cat "$SUB_FILE")
[ -z "$SUB_URL" ] && { echo "Ошибка: пустой URL подписки" >> "$LOG"; exit 1; }

# 2. HWID
if [ -f "$HWID_FILE" ]; then
    HWID="$(cat "$HWID_FILE")"
else
    HWID="$(hexdump -n 16 -v -e '/1 "%02x"' /dev/urandom)"
    echo "$HWID" > "$HWID_FILE"
    chmod 600 "$HWID_FILE"
fi
echo "[HWID] $HWID" >> "$LOG"

# 3. Xray-core (GitHub)
echo "[1] Обновление Xray-core..." >> "$LOG"

LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

TMP_DIR="/tmp/xray_install"
mkdir -p "$TMP_DIR"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"

curl -L -o "$TMP_DIR/xray.zip" "$ZIP_URL"
unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR"

install -m 755 "$TMP_DIR/xray" /usr/bin/xray
[ -f "$TMP_DIR/xrayctl" ] && install -m 755 "$TMP_DIR/xrayctl" /usr/bin/xrayctl

rm -rf "$TMP_DIR"

echo "✓ Xray обновлён до $LATEST_VERSION" >> "$LOG"

# 4. geoip/geosite
echo "[2] Обновление geoip/geosite..." >> "$LOG"
mkdir -p "$GEO_DIR"
curl -fsSL "$GEOIP_URL" -o "$GEOIP"
curl -fsSL "$GEOSITE_URL" -o "$GEOSITE"

# 5. config.json
echo "[3] Обновляем config.json..." >> "$LOG"
TMP_CONFIG="/tmp/xray-config.json"

curl -s -L -m 15 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" | python3 "$PARSER" | python3 "$GENERATOR" \
    --output "$TMP_CONFIG" >> "$LOG" 2>&1

if [ ! -s "$TMP_CONFIG" ]; then
    echo "Ошибка: генератор не создал config.json" >> "$LOG"
    exit 1
fi

# 6. проверка
if xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1; then
    echo "[OK] Новый конфиг валиден" >> "$LOG"
    mv "$TMP_CONFIG" "$CONFIG_JSON"
else
    echo "[ERR] Новый конфиг НЕ валиден, откат!" >> "$LOG"
    exit 1
fi

# 7. перезапуск
echo "[4] Перезапуск Xray..." >> "$LOG"
/etc/init.d/xray restart >> "$LOG" 2>&1

echo "Готово." >> "$LOG"
