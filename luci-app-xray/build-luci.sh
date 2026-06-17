#!/bin/sh
# Сборка LuCI .apk пакета luci-app-xray
# Использует Alpine docker с apk mkpkg (v3 ADB формат)
# или tar.gz fallback для v2

set -e

PKG_NAME="luci-app-xray"
PKG_VER="1.0.0"
PKG_REL="1"
ARCH="noarch"
BUILD_DIR="./build"
PKG_DIR="${BUILD_DIR}/${PKG_NAME}-${PKG_VER}-r${PKG_REL}"
OUTPUT="${PKG_NAME}-${PKG_VER}-r${PKG_REL}.apk"
SRC_DIR="../luci-app-xray"

echo "=== Сборка LuCI APK пакета: ${PKG_NAME} v${PKG_VER}-r${PKG_REL} ==="

rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR"

# ─── Установка файлов LuCI ───
echo "→ Установка файлов LuCI..."
mkdir -p "$PKG_DIR/www/luci-static/resources/view/xray"
mkdir -p "$PKG_DIR/usr/share/luci/menu.d"
mkdir -p "$PKG_DIR/usr/share/rpcd/acl.d"
mkdir -p "$PKG_DIR/usr/share/xray"

cp "$SRC_DIR/htdocs/luci-static/resources/view/xray/status.js" "$PKG_DIR/www/luci-static/resources/view/xray/"
cp "$SRC_DIR/root/usr/share/luci/menu.d/luci-app-xray.json" "$PKG_DIR/usr/share/luci/menu.d/"
cp "$SRC_DIR/root/usr/share/rpcd/acl.d/luci-app-xray.json" "$PKG_DIR/usr/share/rpcd/acl.d/"
cp "$SRC_DIR/root/usr/share/xray/rpc.sh" "$PKG_DIR/usr/share/xray/"
chmod 755 "$PKG_DIR/usr/share/xray/rpc.sh"

# ─── Переводы (po → lmo) ───
if [ -d "$SRC_DIR/po/ru" ]; then
    mkdir -p "$PKG_DIR/usr/lib/lua/luci/i18n"
    # Копируем .po как есть (LuCI скомпилирует при установке или использует как есть)
    cp "$SRC_DIR/po/ru/xray.po" "$PKG_DIR/usr/lib/lua/luci/i18n/xray.ru.po" 2>/dev/null || true
fi

# ─── Сборка через Docker (Alpine) ───
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "→ Сборка APK v3 (ADB) через Alpine..."

    for ALPINE_IMG in alpine:edge alpine:latest; do
        if docker run --rm "$ALPINE_IMG" true >/dev/null 2>&1; then
            break
        fi
    done

    docker run --rm \
        -v "$(pwd)/$PKG_DIR:/tmp/pkg:ro" \
        -v "$(pwd):/out" \
        "$ALPINE_IMG" sh -c "
        apk mkpkg \\
          --files /tmp/pkg \\
          --output /tmp/pkg.apk \\
          --info 'name:${PKG_NAME}' \\
          --info 'version:${PKG_VER}-r${PKG_REL}' \\
          --info 'arch:${ARCH}' \\
          --info 'description:LuCI Xray Status Dashboard - Web dashboard for Xray TProxy on OpenWrt' \\
          --info 'url:https://github.com/kirilllavrov/XPowerSpirit-OpenWRT' \\
          --info 'license:Apache-2.0' \\
          --info 'origin:${PKG_NAME}' \\
          2>&1

        cp /tmp/pkg.apk /out/${OUTPUT}
        chmod 644 /out/${OUTPUT}
        echo '✓ V3 LuCI пакет собран (ADB формат)'
        " 2>&1 || true

    if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
        echo ""
        echo "✓ Пакет собран: ${OUTPUT} (APK v3 ADB формат)"
        echo "  Размер: $(du -h "$OUTPUT" | cut -f1)"
        echo ""
        echo "  Установка: apk add --allow-untrusted /tmp/${OUTPUT}"
        exit 0
    fi
fi

# ─── Fallback: tar.gz v2 ───
echo "→ Используем tar.gz fallback..."

cat > "$PKG_DIR/.PKGINFO" << EOF
pkgname = ${PKG_NAME}
pkgver = ${PKG_VER}-r${PKG_REL}
arch = ${ARCH}
size = $(du -sb "$PKG_DIR" | cut -f1)
pkgdesc = LuCI Xray Status Dashboard
url = https://github.com/kirilllavrov/XPowerSpirit-OpenWRT
license = Apache-2.0
depend = luci-base
EOF

tar -czf "$OUTPUT" -C "$PKG_DIR" .

echo ""
echo "✓ Пакет собран: ${OUTPUT} (tar.gz v2)"
echo "  Установка: apk add --allow-untrusted /tmp/${OUTPUT}"
