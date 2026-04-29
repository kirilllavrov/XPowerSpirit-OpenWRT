#!/bin/sh
# Обновление Xray-core, geoip/geosite, подписки и config.json
# OpenWrt 25.12.x

set -e

LOG="/tmp/log/xray-update.log"
mkdir -p /tmp/log

CONFIG_DIR="/etc/xray"
SUB_FILE="$CONFIG_DIR/subscription.url"
CONFIG_JSON="$CONFIG_DIR/config.json"
HWID_FILE="$CONFIG_DIR/hwid"

STATE_DIR="/etc/xray/state"
TMP_DIR="/tmp/xray_update"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"

GEO_DIR="/usr/share/xray"
GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat"
GEOSITE_URL="https://cdn.jsdelivr.net/gh/kirilllavrov/geosite-builder@release/geosite.dat"

mkdir -p "$STATE_DIR" "$TMP_DIR"

echo "===== $(date) =====" >> "$LOG"

extract_sha256() {
    grep '^SHA2-256' "$1" \
        | sed 's/.*= *//' \
        | tr -cd '0-9a-fA-F' \
        | cut -c1-64
}

# HWID
[ -f "$HWID_FILE" ] || { echo "[ERR] Нет HWID" >> "$LOG"; exit 1; }
HWID="$(cat "$HWID_FILE")"

# Подписка
[ -f "$SUB_FILE" ] || { echo "[ERR] Нет subscription.url" >> "$LOG"; exit 1; }
SUB_URL="$(cat "$SUB_FILE")"
[ -z "$SUB_URL" ] && { echo "[ERR] Пустой URL подписки" >> "$LOG"; exit 1; }

# Версия Xray
LATEST_VERSION=$(curl -H "Cache-Control: no-cache" -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

[ -z "$LATEST_VERSION" ] && { echo "[ERR] Не удалось получить версию Xray" >> "$LOG"; exit 1; }

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"
SHA_FILE="$STATE_DIR/xray.zip.sha256sum"

# Скачиваем .dgst (без -f!)
curl -H "Cache-Control: no-cache" -s -L -o "$STATE_DIR/xray.dgst" "${ZIP_URL}.dgst"

REMOTE_SHA=$(extract_sha256 "$STATE_DIR/xray.dgst")

if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
    echo "✓ Xray ZIP не изменился" >> "$LOG"
else
    echo "→ Скачиваем Xray ZIP..." >> "$LOG"
    curl -f -H "Cache-Control: no-cache" -L -o "$ZIP_DEST" "$ZIP_URL"

    LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
    [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "[ERR] SHA mismatch Xray ZIP" >> "$LOG"; exit 1; }

    echo "$REMOTE_SHA" > "$SHA_FILE"

    unzip -q "$ZIP_DEST" -d "$TMP_DIR"
    cp "$TMP_DIR/xray" /usr/bin/xray
    chmod 755 /usr/bin/xray

    echo "✓ Xray обновлён до $LATEST_VERSION" >> "$LOG"
fi

# ============================
#   GEOIP / GEOSITE (SHA256SUM)
# ============================

update_geo() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${STATE_DIR}/$(basename "$DEST").sha256sum"

    # Скачиваем .sha256sum
    curl -H "Cache-Control: no-cache" -s -L -o "${DEST}.sha256sum" "${URL}.sha256sum"

    # Извлекаем SHA
    REMOTE_SHA=$(cut -d' ' -f1 "${DEST}.sha256sum")

    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
        echo "✓ $(basename "$DEST") не изменился" >> "$LOG"
        return
    fi

    # Скачиваем файл
    curl -f -H "Cache-Control: no-cache" -sSL -o "$DEST" "$URL"

    LOCAL_SHA=$(sha256sum "$DEST" | awk '{print $1}')

    [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || {
        echo "[ERR] SHA mismatch $(basename "$DEST")" >> "$LOG"
        exit 1
    }

    echo "$REMOTE_SHA" > "$SHA_FILE"
    echo "✓ $(basename "$DEST") обновлён" >> "$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# Генерация config.json
TMP_CONFIG="/tmp/xray-config.json"
SUB_RAW="/tmp/xray-sub.raw"

curl -H "Cache-Control: no-cache" -s -L -m 20 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" > "$SUB_RAW"

grep -q "vless://" "$SUB_RAW" || { echo "[ERR] Подписка не содержит vless://" >> "$LOG"; exit 1; }

cat "$SUB_RAW" \
    | python3 "$PARSER" \
    | python3 "$GENERATOR" --output "$TMP_CONFIG"

[ -s "$TMP_CONFIG" ] || { echo "[ERR] Пустой config.json" >> "$LOG"; exit 1; }

xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1 \
    || { echo "[ERR] Новый config.json невалиден" >> "$LOG"; exit 1; }

mv "$TMP_CONFIG" "$CONFIG_JSON"
echo "✓ Новый config.json установлен" >> "$LOG"

/etc/init.d/xray restart >> "$LOG" 2>&1
echo "Готово." >> "$LOG"
