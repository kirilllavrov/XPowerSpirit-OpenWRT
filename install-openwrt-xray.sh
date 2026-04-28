echo "[+] Устанавливаем Xray..."

LATEST_VERSION=$(curl -H "Cache-Control: no-cache" -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep '"tag_name"' | cut -d '"' -f 4)

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) MACHINE="64" ;;
  aarch64) MACHINE="arm64-v8a" ;;
  armv7l) MACHINE="arm32-v7a" ;;
  *) MACHINE="64" ;;
esac

TMP_DIR="/tmp/xray_install"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
ZIP_DEST="$TMP_DIR/xray.zip"
SHA_FILE="$STATE_DIR/xray.zip.sha256sum"

curl -H "Cache-Control: no-cache" -s -L -o "$STATE_DIR/xray.dgst" "${ZIP_URL}.dgst"

REMOTE_SHA=$(grep -E 'SHA2-256|SHA256' "$STATE_DIR/xray.dgst" \
    | head -n1 \
    | sed 's/.*= *//' \
    | tr -d '[:space:]')

if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ]; then
    echo "✓ Xray ZIP уже скачан — пропускаем"
else
    echo "→ Скачиваем Xray ZIP..."
    curl -H "Cache-Control: no-cache" -L -o "$ZIP_DEST" "$ZIP_URL"

    LOCAL_SHA=$(sha256sum "$ZIP_DEST" | awk '{print $1}')
    [ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "Ошибка SHA Xray ZIP"; exit 1; }

    echo "$REMOTE_SHA" > "$SHA_FILE"
fi

unzip -q "$ZIP_DEST" -d "$TMP_DIR"
cp "$TMP_DIR/xray" /usr/bin/xray
chmod 755 /usr/bin/xray

echo "✓ Xray установлен ($LATEST_VERSION)"
