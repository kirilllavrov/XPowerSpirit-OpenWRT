#!/bin/sh
# Обновление Xray-core, geoip/geosite, подписки и config.json
# OpenWrt 25.12.x

set -e

LOG="/tmp/log/xray-update.log"

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

# ---------------------------------------------------------
# Проверка HWID
# ---------------------------------------------------------
if [ ! -f "$HWID_FILE" ]; then
    echo "[ERR] Нет HWID-файла $HWID_FILE — запусти install" >> "$LOG"
    exit 1
fi
HWID="$(cat "$HWID_FILE")"
echo "[HWID] $HWID" >> "$LOG"

# ---------------------------------------------------------
# Проверка подписки
# ---------------------------------------------------------
if [ ! -f "$SUB_FILE" ]; then
    echo "[ERR] Нет файла подписки $SUB_FILE" >> "$LOG"
    exit 1
fi

SUB_URL="$(cat "$SUB_FILE")"
[ -z "$SUB_URL" ] && { echo "[ERR] Пустой URL подписки" >> "$LOG"; exit 1; }

# ---------------------------------------------------------
# Функция обновления geodata
# ---------------------------------------------------------
download_geo_if_changed() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${STATE_DIR}/$(basename "$DEST").sha256sum"

    echo "[*] Проверяем geodata: $DEST" >> "$LOG"

    REMOTE_SHA=$(curl -s "${URL}.sha256sum" | awk '{print $1}')
    if [ -z "$REMOTE_SHA" ]; then
        echo "    [!] Не удалось получить SHA256" >> "$LOG"
        return 1
    fi

    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
        echo "    ✓ Файл не изменился — пропускаем" >> "$LOG"
        return 0
    fi

    echo "    → Файл изменился, скачиваем..." >> "$LOG"
    curl -fsSL -o "$DEST" "$URL"

    LOCAL_SHA_NEW=$(sha256sum "$DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA_NEW" != "$REMOTE_SHA" ]; then
        echo "    [!] Ошибка SHA256!" >> "$LOG"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"
    echo "    ✓ Файл обновлён" >> "$LOG"
}

# ---------------------------------------------------------
# Функция обновления Xray
# ---------------------------------------------------------
XRAY_UPDATED=0

download_xray_if_changed() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${STATE_DIR}/$(basename "$DEST").sha256sum"
    local DGST_URL="${URL}.dgst"

    echo "[*] Проверяем Xray ZIP" >> "$LOG"

    curl -s -L -o "$STATE_DIR/xray.dgst" "$DGST_URL"

    REMOTE_SHA=$(grep -E 'SHA2-256=|SHA256=|SHA256 ' "$STATE_DIR/xray.dgst" \
        | sed 's/.*= *//' | tr -d '[:space:]')

    if [ -z "$REMOTE_SHA" ]; then
        echo "    [!] Не удалось получить SHA256 из .dgst" >> "$LOG"
        exit 1
    fi

    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
        echo "    ✓ Xray не изменился — пропускаем" >> "$LOG"
        return 0
    fi

    echo "    → Xray изменился, скачиваем ZIP..." >> "$LOG"
    curl -fsSL -o "$DEST" "$URL"

    LOCAL_SHA_NEW=$(sha256sum "$DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA_NEW" != "$REMOTE_SHA" ]; then
        echo "    [!] Ошибка SHA256 Xray ZIP!" >> "$LOG"
        exit 1
    fi

    echo "$REMOTE_SHA" > "$SHA_FILE"
    XRAY_UPDATED=1
    echo "    ✓ Xray ZIP обновлён" >> "$LOG"
}

# ---------------------------------------------------------
# 1. Обновление Xray
# ---------------------------------------------------------
LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"

download_xray_if_changed "$ZIP_URL" "$ZIP_DEST"

if [ "$XRAY_UPDATED" -eq 1 ]; then
    unzip -q "$ZIP_DEST" -d "$TMP_DIR"
    cp "$TMP_DIR/xray" /usr/bin/xray
    chmod 755 /usr/bin/xray
    echo "✓ Xray обновлён до $LATEST_VERSION" >> "$LOG"
else
    echo "✓ Xray не изменился" >> "$LOG"
fi

# ---------------------------------------------------------
# 2. Обновление geodata
# ---------------------------------------------------------
download_geo_if_changed "$GEOIP_URL" "$GEOIP"
download_geo_if_changed "$GEOSITE_URL" "$GEOSITE"

# ---------------------------------------------------------
# 3. Генерация config.json
# ---------------------------------------------------------
TMP_CONFIG="/tmp/xray-config.json"
SUB_RAW="/tmp/xray-sub.raw"

curl -s -L -m 20 \
    -H "User-Agent: Happ" \
    -H "x-hwid: $HWID" \
    "$SUB_URL" > "$SUB_RAW"

grep -q "vless://" "$SUB_RAW" || {
    echo "[ERR] Подписка не содержит vless://" >> "$LOG"
    exit 1
}

cat "$SUB_RAW" \
    | python3 "$PARSER" \
    | python3 "$GENERATOR" --output "$TMP_CONFIG" 2>>"$LOG"

[ -s "$TMP_CONFIG" ] || { echo "[ERR] Пустой config.json" >> "$LOG"; exit 1; }

xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1 \
    || { echo "[ERR] Новый config.json НЕ валиден" >> "$LOG"; exit 1; }

mv "$TMP_CONFIG" "$CONFIG_JSON"
echo "[OK] Новый config.json установлен" >> "$LOG"

# ---------------------------------------------------------
# 4. Перезапуск Xray
# ---------------------------------------------------------
/etc/init.d/xray restart >> "$LOG" 2>&1
echo "Готово." >> "$LOG"
