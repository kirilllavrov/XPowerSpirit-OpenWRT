#!/bin/sh
# Сборка .apk пакета xray-status (APK v3 ADB формат для OpenWrt 25.12+)
# Использование:
#   ./build-apk.sh                 # сборка v3 через Alpine (есть docker) или tar.gz fallback
#   ./build-apk.sh --no-docker     # принудительный tar.gz fallback (v2, нужен --allow-untrusted)

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
SRC_SCRIPT="../xray-status.py"

echo "=== Сборка APK пакета: ${PKG_NAME} v${PKG_VER}-r${PKG_REL} ==="

# ─── АРГУМЕНТЫ ───
USE_DOCKER=1
for arg in "$@"; do
    case $arg in
        --no-docker) USE_DOCKER=0 ;;
    esac
done

# ─── ОЧИСТКА ───
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

# ─── УСТАНОВКА ФАЙЛОВ ───
echo "→ Установка файлов..."
install -Dm755 "$SRC_SCRIPT" "$PKG_DIR/usr/bin/xray-status"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  СПОСОБ 1: APK v3 через Alpine docker (ADB формат)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$USE_DOCKER" = "1" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "→ Сборка APK v3 (ADB) через Alpine..."
    
    # Пробуем alpine:edge, если нет — alpine:latest
    for ALPINE_IMG in alpine:edge alpine:latest; do
        if docker run --rm -v "$(pwd)/..:/src:ro" "$ALPINE_IMG" true >/dev/null 2>&1; then
            echo "  Используем образ: $ALPINE_IMG"
            break
        fi
    done

    docker run --rm \
        -v "$(pwd)/..:/src:ro" \
        -v "$(pwd):/out" \
        "$ALPINE_IMG" sh -c "
        set -e
        mkdir -p /tmp/pkg/usr/bin
        cp /src/xray-status.py /tmp/pkg/usr/bin/xray-status
        chmod 755 /tmp/pkg/usr/bin/xray-status

        apk mkpkg \\
          --files /tmp/pkg \\
          --output /tmp/pkg.apk \\
          --info 'name:${PKG_NAME}' \\
          --info 'version:${PKG_VER}-r${PKG_REL}' \\
          --info 'arch:${ARCH}' \\
          --info 'description:Xray Status Dashboard - CLI tool for Xray TProxy on OpenWrt' \\
          --info 'url:https://github.com/kirilllavrov/XPowerSpirit-OpenWRT' \\
          --info 'license:MIT' \\
          --info 'origin:${PKG_NAME}' \\
          2>&1

        cp /tmp/pkg.apk /out/${OUTPUT}
        chmod 644 /out/${OUTPUT}
        echo '✓ V3 пакет собран (ADB формат)'
        " 2>&1 || true

    if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
        echo ""
        echo "✓ Пакет собран: ${OUTPUT} (APK v3 ADB формат)"
        echo "  Размер: $(du -h "$OUTPUT" | cut -f1) ($(wc -c < "$OUTPUT") байт)"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  УСТАНОВКА НА OpenWrt 25.12+:"
        echo "  apk add --allow-untrusted /tmp/${OUTPUT}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    fi
    echo "  [!] Docker-сборка не удалась, пробуем tar.gz fallback..."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  СПОСОБ 2: tar.gz fallback (v2, требует --allow-untrusted на OpenWrt APK v3)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "→ Используем tar.gz fallback (v2 формат)..."

# ─── .PKGINFO ───
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

tar -czf "$OUTPUT" -C "$PKG_DIR" .

echo ""
echo "✓ Пакет собран: ${OUTPUT} (tar.gz v2 формат)"
echo "  Размер: $(du -h "$OUTPUT" | cut -f1) ($(wc -c < "$OUTPUT") байт)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  УСТАНОВКА НА OpenWrt:"
echo ""
echo "  # Для APK v3 (OpenWrt 25.12+) — требуется --allow-untrusted:"
echo "  apk add --allow-untrusted /tmp/${OUTPUT}"
echo ""
echo "  # Для APK v2 (старые версии Alpine):"
echo "  apk add --allow-untrusted ./${OUTPUT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
