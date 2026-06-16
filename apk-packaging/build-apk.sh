#!/bin/sh
# Сборка .apk пакета xray-status
# Использование:
#   ./build-apk.sh                 # сборка с авто-генерацией ключа и подписью
#   ./build-apk.sh --no-sign       # сборка без подписи (нужен --allow-untrusted при установке)

set -e

PKG_NAME="xray-status"
PKG_VER="1.0.0"
PKG_REL="1"
ARCH="noarch"
BUILD_DIR="./build"
KEYS_DIR="./keys"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}-${PKG_VER}-r${PKG_REL}"
OUTPUT="${PKG_NAME}-${PKG_VER}-r${PKG_REL}.apk"
SIGN_KEY_NAME="xpower-sign"

echo "=== Сборка APK пакета: ${PKG_NAME} v${PKG_VER}-r${PKG_REL} ==="

# ─── АРГУМЕНТЫ ───
DO_SIGN=1
for arg in "$@"; do
    case $arg in
        --no-sign) DO_SIGN=0 ;;
    esac
done

# ─── КЛЮЧИ ───
if [ "$DO_SIGN" = "1" ]; then
    mkdir -p "$KEYS_DIR"
    PRIV_KEY="${KEYS_DIR}/${SIGN_KEY_NAME}.key"
    PUB_KEY="${KEYS_DIR}/${SIGN_KEY_NAME}.pub"

    if [ ! -f "$PRIV_KEY" ]; then
        echo "→ Генерируем новую пару ключей RSA 2048..."
        openssl genrsa -out "$PRIV_KEY" 2048 2>/dev/null
        openssl rsa -in "$PRIV_KEY" -pubout -out "$PUB_KEY" 2>/dev/null
        echo "✓ Ключи созданы: $PRIV_KEY, $PUB_KEY"
    else
        echo "→ Используем существующие ключи: $PRIV_KEY"
    fi
fi

# ─── ОЧИСТКА ───
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

# ─── УСТАНОВКА ФАЙЛОВ ───
echo "→ Установка файлов..."
install -Dm755 ../xray-status.py "$PKG_DIR/usr/bin/xray-status"

# ─── .PKGINFO ───
echo "→ Создание .PKGINFO..."
cat > "$PKG_DIR/.PKGINFO" << EOF
pkgname = ${PKG_NAME}
pkgver = ${PKG_VER}-r${PKG_REL}
arch = ${ARCH}
size = $(du -sb "$PKG_DIR" | cut -f1)
pkgdesc = Xray Status Dashboard — CLI-утилита для отображения статуса Xray TProxy на OpenWrt
url = https://github.com/kirilllavrov/XPowerSpirit-OpenWRT
license = MIT
depend = python3-light
depend = xray-core
EOF

# ─── СБОРКА: пробуем apk mkpkg (v3), иначе tar.gz + openssl ───
if command -v apk >/dev/null 2>&1 && apk mkpkg --help >/dev/null 2>&1; then
    echo "→ Используем apk mkpkg (v3)..."
    if [ "$DO_SIGN" = "1" ] && [ -f "$PRIV_KEY" ]; then
        apk mkpkg --sign "$PRIV_KEY" --output "$OUTPUT" "$PKG_DIR"
        echo "✓ Пакет собран и подписан (apk v3, ключ: ${SIGN_KEY_NAME})"
    else
        apk mkpkg --output "$OUTPUT" "$PKG_DIR"
    fi
else
    echo "→ Используем tar.gz + openssl (apk v2/v3 совместимо)..."

    # Собираем tar.gz
    tar -czf "$OUTPUT" -C "$PKG_DIR" .

    if [ "$DO_SIGN" = "1" ] && [ -f "$PRIV_KEY" ] && [ -f "$PUB_KEY" ]; then
        echo "→ Подписываем пакет (RSA-SHA256)..."

        # SHA256 от всего .apk
        APK_SHA256=$(sha256sum "$OUTPUT" | awk '{print $1}')

        # RSA-подпись хеша (сырые байты)
        SIG_FILE="${BUILD_DIR}/signature.bin"
        printf "%s" "$APK_SHA256" | openssl dgst -sha256 -sign "$PRIV_KEY" -out "$SIG_FILE" 2>/dev/null

        # Дозаписываем сигнатуру после gzip-потока (APK v2 формат)
        cat "$SIG_FILE" >> "$OUTPUT"

        echo "✓ Пакет подписан (ключ: ${SIGN_KEY_NAME})"
    fi
fi

echo ""
echo "✓ Пакет собран: ${OUTPUT}"
echo "  Размер: $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  УСТАНОВКА НА OpenWrt:"
echo ""
echo "  # Способ 1 — всегда работает:"
echo "  apk add --allow-untrusted /tmp/upload.apk"
echo ""

if [ "$DO_SIGN" = "1" ] && [ -f "$PUB_KEY" ]; then
    echo "  # Способ 2 — с ключом (без --allow-untrusted):"
    echo "  mkdir -p /etc/apk/keys"
    echo "  cp ${PUB_KEY} /etc/apk/keys/"
    echo "  apk add /tmp/upload.apk"
    echo ""
fi
echo "  # Проверить содержимое:"
echo "  tar -tzf ${OUTPUT} | head -10"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
