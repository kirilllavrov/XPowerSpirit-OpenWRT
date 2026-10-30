#!/bin/sh
# Bootstrap установки XPowerSpirit-OpenWRT из Yandex Object Storage.
#
# Скачивает latest.zip, проверяет sha256, распаковывает и запускает установщик
# из архива. Все аргументы передаются установщику как есть:
#
#   curl -fsSL https://storage.yandexcloud.net/flyz-cryp-olxn-mojw/XPowerSpirit-OpenWRT/install.sh \
#     | sh -s -- --sub=<URL_подписки>
#
# Если Object Storage недоступен (нет объекта, сеть, несовпадение sha256), ставится
# установщик с GitHub — как раньше, без проверки контрольной суммы архива.
#
# Это полная установка, а не обновление: для обновления скриптов на уже
# установленной системе есть /usr/share/xray/update-scripts.sh.

set -e

ARCHIVE_BASE="${XRAY_ARCHIVE_BASE:-https://storage.yandexcloud.net/flyz-cryp-olxn-mojw/XPowerSpirit-OpenWRT}"
REPO_RAW="${XRAY_REPO_RAW:-https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main}"
WORK_DIR="${XRAY_INSTALL_TMP:-/tmp/xray-bootstrap}"

die() {
    echo "[X] $1" >&2
    exit 1
}

# Бутстрапу нужны curl (скачать), unzip и sha256sum (проверить архив).
# Проверяем сразу и говорим, что поставить: иначе пользователь видит
# только «sh: unzip: not found» на середине установки.
_missing=""
for _cmd in curl unzip sha256sum; do
    command -v "$_cmd" >/dev/null 2>&1 || _missing="$_missing $_cmd"
done
[ -n "$_missing" ] && die "Не хватает команд:$_missing
Установите пакеты и повторите:
  apk update && apk add curl ca-bundle nftables-json kmod-nft-tproxy kmod-nft-socket python3 resolveip unzip jq"

# Запасной путь: установщик прямо с GitHub, без архива
fallback_github() {
    local reason="$1"
    shift
    echo "[!] $reason — ставлю установщик с GitHub (без проверки sha256 архива)" >&2
    curl -fsSL "$REPO_RAW/install-openwrt-xray.sh" -o "$WORK_DIR/install-openwrt-xray.sh" ||
        die "Не удалось скачать установщик ни из Object Storage, ни с GitHub"
    cd "$WORK_DIR" || die "Не удалось перейти в $WORK_DIR"
    exec sh "$WORK_DIR/install-openwrt-xray.sh" "$@"
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" || die "Не удалось создать $WORK_DIR"
cd "$WORK_DIR" || die "Не удалось перейти в $WORK_DIR"
echo "→ Источник: $ARCHIVE_BASE"

curl -fsSLo latest.zip.sha256 "$ARCHIVE_BASE/latest.zip.sha256" ||
    fallback_github "нет latest.zip.sha256" "$@"
curl -fsSLo latest.zip "$ARCHIVE_BASE/latest.zip" ||
    fallback_github "не удалось скачать latest.zip" "$@"
sha256sum -c latest.zip.sha256 >/dev/null ||
    fallback_github "sha256 latest.zip не совпал" "$@"

unzip -q latest.zip || die "Не удалось распаковать latest.zip"

ARCHIVE_DIR=$(ls -d XPowerSpirit-OpenWRT*/ 2>/dev/null | head -1)
[ -n "$ARCHIVE_DIR" ] || die "В latest.zip нет каталога с файлами"
[ -f "$ARCHIVE_DIR/install-openwrt-xray.sh" ] || die "В latest.zip нет install-openwrt-xray.sh"

COMMIT=$(sed -n 's/^commit: //p' MANIFEST.txt 2>/dev/null | head -1)
echo "[+] Архив проверен: ${COMMIT:-версия неизвестна}"
echo "→ Запуск установщика из архива"

exec sh "./${ARCHIVE_DIR}install-openwrt-xray.sh" "$@"
