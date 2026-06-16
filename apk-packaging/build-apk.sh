#!/bin/sh
# Сборка .apk пакета xray-status
# Использование:
#   ./build-apk.sh              # сборка без подписи (для тестов)
#   ./build-apk.sh --sign KEY   # сборка с подписью

set -e

PKG_NAME="xray-status"
PKG_VER="1.0.0"
PKG_REL="1"
ARCH="noarch"
BUILD_DIR="./build"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}-${PKG_VER}-r${PKG_REL}"
OUTPUT="${PKG_NAME}-${PKG_VER}-r${PKG_REL}.apk"

echo "=== Сборка APK пакета: ${PKG_NAME} ==="

# Очистка
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

# Установка файлов
echo "→ Установка файлов..."
install -Dm755 ../xray-status.py "$PKG_DIR/usr/bin/xray-status"

# Создаём .PKGINFO
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

# Создаём .INSTALL (если нужны post-install скрипты)
# Пока не требуется

# Пробуем использовать apk mkpkg (v3)
if command -v apk >/dev/null 2>&1 && apk mkpkg --help >/dev/null 2>&1; then
    echo "→ Используем apk mkpkg (v3)..."
    apk mkpkg --output "$OUTPUT" "$PKG_DIR"
else
    # Fallback: собираем как v2 (tar.gz + подпись опционально)
    echo "→ Используем tar.gz (apk v2 формат)..."
    tar -czf "$OUTPUT" -C "$PKG_DIR" .

    if [ "$1" = "--sign" ] && [ -n "$2" ]; then
        echo "→ Подписываем ключом $2..."
        openssl dgst -sha256 -sign "$2" -out "${OUTPUT}.sig" "$OUTPUT"
        cat "${OUTPUT}.sig" >> "$OUTPUT"
        rm -f "${OUTPUT}.sig"
        echo "✓ Пакет подписан"
    fi
fi

echo ""
echo "✓ Пакет собран: ${OUTPUT}"
echo "  Размер: $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "Установка на OpenWrt:"
echo "  apk add --allow-untrusted ./${OUTPUT}"
echo ""
echo "Проверка:"
echo "  tar -tzf ${OUTPUT}"
