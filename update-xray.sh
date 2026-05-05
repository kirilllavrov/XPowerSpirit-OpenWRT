#!/bin/sh
# OpenWrt — обновление Xray, geoip, geosite и config.json

LOG="/tmp/log/xray-update.log"

die() {
    echo "🚫 $1" >>"$LOG"
    exit 1
}

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

echo "===== $(date) =====" >>"$LOG"

extract_sha256() {
    grep '^SHA2-256' "$1" |
        sed 's/.*= *//' |
        tr -cd '0-9a-fA-F' |
        cut -c1-64
}

# ============================
#   HWID + подписка
# ============================

[ -f "$HWID_FILE" ] || die "Нет HWID"
HWID="$(cat "$HWID_FILE")"

[ -f "$SUB_FILE" ] || die "Нет subscription.url"
SUB_URL="$(cat "$SUB_FILE")"
[ -z "$SUB_URL" ] && die "Пустой URL подписки"

# ============================
#   Обновление Xray
# ============================

LATEST_VERSION=$(curl -H "Cache-Control: no-cache" -s https://api.github.com/repos/XTLS/Xray-core/releases/latest |
    grep '"tag_name"' | cut -d '"' -f 4)

[ -z "$LATEST_VERSION" ] && die "Не удалось получить версию Xray"

ARCH=$(uname -m)
case "$ARCH" in
x86_64 | amd64) MACHINE="64" ;;
aarch64) MACHINE="arm64-v8a" ;;
armv7l) MACHINE="arm32-v7a" ;;
*) MACHINE="64" ;;
esac

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"
SHA_FILE="$STATE_DIR/xray.zip.sha256sum"

curl -H "Cache-Control: no-cache" -s -L -o "$STATE_DIR/xray.dgst" "${ZIP_URL}.dgst"
REMOTE_SHA=$(extract_sha256 "$STATE_DIR/xray.dgst")

FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
[ "$FREE_SPACE_TMP" -lt 20480 ] && die "Недостаточно места в /tmp (нужно минимум 20MB)"

if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
    echo "✅ Xray ZIP не изменился" >>"$LOG"
else
    echo "→ Скачиваем Xray ZIP..." >>"$LOG"
    if ! curl -f -H "Cache-Control: no-cache" -L -o "$ZIP_DEST" "$ZIP_URL"; then
        echo "⚠️ Не удалось скачать Xray ZIP — пропускаем обновление" >>"$LOG"
        rm -f "$ZIP_DEST"
    else
        LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
        if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
            echo "🚫 SHA mismatch Xray ZIP" >>"$LOG"
            rm -f "$ZIP_DEST"
        else
            echo "$REMOTE_SHA" >"$SHA_FILE"
            unzip -q "$ZIP_DEST" -d "$TMP_DIR"
            cp "$TMP_DIR/xray" /usr/bin/xray
            chmod 755 /usr/bin/xray
            echo "✅ Xray обновлён до $LATEST_VERSION" >>"$LOG"
        fi
    fi
fi

# ============================
#   GEOIP / GEOSITE
# ============================

update_geo() {
    local URL="$1"
    local DEST="$2"
    local SHA_FILE="${STATE_DIR}/$(basename "$DEST").sha256sum"

    if ! curl -H "Cache-Control: no-cache" -s -L -o "${DEST}.sha256sum" "${URL}.sha256sum"; then
        echo "⚠️ Не удалось скачать sha256sum для $(basename "$DEST") — пропускаем" >>"$LOG"
        return
    fi
    REMOTE_SHA=$(cut -d' ' -f1 "${DEST}.sha256sum")
    [ -z "$REMOTE_SHA" ] && {
        echo "⚠️ Пустой sha256sum для $(basename "$DEST") — пропускаем" >>"$LOG"
        return
    }

    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
        echo "✅ $(basename "$DEST") не изменился" >>"$LOG"
        return
    fi

    if ! curl -f -H "Cache-Control: no-cache" -sSL -o "$DEST" "$URL"; then
        echo "⚠️ Не удалось скачать $(basename "$DEST") — пропускаем" >>"$LOG"
        return
    fi
    LOCAL_SHA=$(sha256sum "$DEST" | awk '{print $1}')

    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "🚫 SHA mismatch $(basename "$DEST")" >>"$LOG"
        return
    fi

    echo "$REMOTE_SHA" >"$SHA_FILE"
    echo "✅ $(basename "$DEST") обновлён" >>"$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# ============================
#   Генерация config.json
# ============================

echo "→ Генерация config.json..." >>"$LOG"

MAX_RETRIES=2
TRY=1

while [ $TRY -le $MAX_RETRIES ]; do
    TMP_CONFIG="/tmp/xray-config.json"
    : >"$TMP_CONFIG"

    if curl -s -L -m 20 -H "x-hwid: $HWID" "$SUB_URL" |
        python3 "$PARSER" |
        python3 "$GENERATOR" --output "$TMP_CONFIG"; then

        if [ ! -s "$TMP_CONFIG" ]; then
            echo "🚫 Новый config.json пустой (попытка $TRY)" >>"$LOG"
        elif ! xray run -test -config "$TMP_CONFIG" >/dev/null 2>&1; then
            echo "🚫 Новый config.json невалиден (попытка $TRY)" >>"$LOG"
        else
            mv "$TMP_CONFIG" "$CONFIG_JSON"
            echo "✅ Новый config.json установлен (попытка $TRY)" >>"$LOG"
            break
        fi
    else
        echo "🚫 Ошибка при получении или разборе подписки (попытка $TRY)" >>"$LOG"
    fi

    TRY=$((TRY + 1))
done

if [ $TRY -gt $MAX_RETRIES ]; then
    echo "⚠️ Все попытки обновления неудачны — сохраняем старый конфиг" >>"$LOG"
fi

# ============================
#   Финальная проверка config.json
# ============================

if ! xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
    echo "🚫 Итоговый config.json невалиден — отключаем Xray" >>"$LOG"
    /etc/init.d/xray stop
    exit 0
fi

# ============================
#   Пересборка nftables правил
# ============================

/usr/share/xray/update-nft.sh >>"$LOG" 2>&1 || {
    echo "🚫 Ошибка при обновлении nftables" >>"$LOG"
    /etc/init.d/xray stop
    exit 1
}

# ============================
#   Перезапуск Xray
# ============================

if /etc/init.d/xray restart >>"$LOG" 2>&1; then
    echo "✅ Xray перезапущен успешно" >>"$LOG"
else
    echo "⚠️ Не удалось перезапустить Xray" >>"$LOG"
fi
echo "Готово." >>"$LOG"

# Очистка временных файлов
rm -rf "$TMP_DIR"