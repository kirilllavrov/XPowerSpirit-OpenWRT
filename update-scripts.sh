#!/bin/sh
# OpenWrt — автообновление установленных скриптов из latest.zip (Yandex Object Storage).
#
# Что делает:
#   1. Скачивает latest.zip.sha256 (~70 байт) и сравнивает с установленным хешем.
#   2. Если хеш изменился — скачивает latest.zip, сверяет sha256 и распаковывает.
#   3. Проверяет синтаксис новых скриптов ДО применения (sh -n / compile для python).
#   4. Сохраняет текущие скрипты в /etc/xray/state/scripts-prev и заменяет файлы
#      атомарно через rename(2) в пределах одной ФС: работающий скрипт продолжает
#      читать свой прежний inode, поэтому замена самой себя безопасна.
#   5. Доливает в settings.json отсутствующие ключи из settings.default.json,
#      не перезаписывая текущие значения.
#
# Флаги:
#   --check     — показать установленный и доступный sha256, ничего не менять
#   --force     — применить архив, даже если sha256 совпадает
#   --rollback  — вернуть скрипты из /etc/xray/state/scripts-prev
#
# Запуск: cron (02:20) или вручную. Полный цикл обновления роутера — update-xray.sh.

# ============================================
#   КОНФИГУРАЦИЯ (переопределяется в тестах)
# ============================================

SCRIPTS_DIR="${XRAY_SCRIPTS_DIR:-/usr/share/xray}"
SETTINGS_JSON="${XRAY_SETTINGS_JSON:-/etc/xray/settings.json}"
STATE_DIR="${XRAY_STATE_DIR:-/etc/xray/state}"
LOG="${XRAY_SCRIPTS_LOG:-/tmp/log/xray-scripts.log}"
TMP_DIR="${XRAY_SCRIPTS_TMP:-/tmp/xray-scripts}"
LOCK_FILE="${XRAY_SCRIPTS_LOCK:-/var/lock/xray-scripts.lock}"

SHA_FILE="$STATE_DIR/scripts.zip.sha256"
PREV_DIR="$STATE_DIR/scripts-prev"

# Источник архива. Переопределяется в settings.json → update.archive_url
DEFAULT_ARCHIVE_URL="https://storage.yandexcloud.net/flyz-cryp-olxn-mojw/XPowerSpirit-OpenWRT/latest.zip"
ARCHIVE_URL="${XRAY_SCRIPTS_URL:-}"

# Файлы, которые разрешено заменять автоматически. Здесь же — сам этот скрипт:
# его замена безопасна, потому что mv подменяет имя, а не содержимое inode.
SCRIPTS="xray-generate-config.py xray-sub-parser.py update-xray.sh update-nft.sh update-scripts.sh"

MODE="apply"

# ============================================
#   БЛОКИРОВКА И ЛОГИ
# ============================================

mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
exec 200>"$LOCK_FILE" || exit 1
if ! flock -n 200; then
    echo "Другой экземпляр update-scripts.sh уже запущен" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    echo "$1" >>"$LOG"
}

die() {
    echo "[X] $1" | tee -a "$LOG" >&2
    exit 1
}

rotate_log() {
    local file="$1"
    local max_size="${2:-262144}"
    [ -f "$file" ] || return
    local size
    size=$(stat -c%s "$file" 2>/dev/null || wc -c <"$file")
    if [ "$size" -gt "$max_size" ]; then
        : >"$file"
    fi
}

usage() {
    cat <<'EOF'
Использование: update-scripts.sh [--check|--force|--rollback]

  без флагов  применить latest.zip, если sha256 изменился
  --check     только сравнить установленный и доступный sha256
  --force     применить архив независимо от sha256
  --rollback  вернуть скрипты из /etc/xray/state/scripts-prev
EOF
}

# ============================================
#   ХЕЛПЕРЫ
# ============================================

# Чтение значения из settings.json по jq-пути
settings_get() {
    local key="$1"
    [ -f "$SETTINGS_JSON" ] || return 1
    jq -r "$key // empty" "$SETTINGS_JSON" 2>/dev/null
}

# Скачивание с ретраями. Без заголовков подписки: Object Storage их не требует.
fetch_url() {
    local url="$1"
    local dst="$2"
    local retry=1

    while [ $retry -le 3 ]; do
        curl -fsS -L --max-time 60 -o "$dst" "$url"
        if [ $? -eq 0 ] && [ -s "$dst" ]; then
            if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
                rm -f "$dst"
            else
                return 0
            fi
        fi
        [ $retry -lt 3 ] && sleep 2
        retry=$((retry + 1))
    done
    return 1
}

installed_complete() {
    local f
    for f in $SCRIPTS; do
        [ -f "$SCRIPTS_DIR/$f" ] || return 1
    done
    return 0
}

valid_sha() {
    case "$1" in
    "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ ${#1} -eq 64 ] || return 1
    return 0
}

# Скачивает архив и сверяет sha256. Две попытки: между чтением .sha256 и .zip
# workflow мог выгрузить новую версию. По успеху обновляет REMOTE_SHA — источником
# истины становится хеш, под который реально проверен скачанный файл.
download_verified() {
    local attempt=1
    local remote actual

    while [ $attempt -le 2 ]; do
        if fetch_url "${ARCHIVE_URL}.sha256" "$TMP_DIR/latest.zip.sha256"; then
            remote=$(cut -d' ' -f1 "$TMP_DIR/latest.zip.sha256" | head -1)
            if ! valid_sha "$remote"; then
                log "[!] Некорректный sha256 в latest.zip.sha256: '$remote'"
                return 1
            fi
            if fetch_url "$ARCHIVE_URL" "$TMP_DIR/latest.zip"; then
                actual=$(sha256sum "$TMP_DIR/latest.zip" | awk '{print $1}')
                if [ "$actual" = "$remote" ]; then
                    REMOTE_SHA="$remote"
                    return 0
                fi
                log "[!] sha256 не совпал: ожидался $remote, получен $actual"
                rm -f "$TMP_DIR/latest.zip"
            fi
        else
            log "[!] Не удалось скачать latest.zip.sha256 (попытка $attempt)"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

check_syntax() {
    local f
    for f in $SCRIPTS; do
        case "$f" in
        *.sh)
            if ! sh -n "$NEW_DIR/$f" 2>>"$LOG"; then
                log "[X] Синтаксическая ошибка в $f"
                return 1
            fi
            ;;
        *.py)
            if ! python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' \
                "$NEW_DIR/$f" 2>>"$LOG"; then
                log "[X] Ошибка компиляции $f"
                return 1
            fi
            ;;
        esac
    done
    return 0
}

backup_scripts() {
    local f
    rm -rf "$PREV_DIR"
    mkdir -p "$PREV_DIR" || return 1
    for f in $SCRIPTS; do
        [ -f "$SCRIPTS_DIR/$f" ] && cp -p "$SCRIPTS_DIR/$f" "$PREV_DIR/$f"
    done
    return 0
}

# Копирует файлы в $SCRIPTS_DIR/.new и подменяет имена через mv (rename в одной ФС)
replace_files() {
    local src_dir="$1"
    shift
    local f mode

    mkdir -p "$SCRIPTS_DIR/.new" || return 1
    for f in "$@"; do
        [ -f "$src_dir/$f" ] || continue
        mode=755
        case "$f" in
        *.json) mode=644 ;;
        esac
        cp "$src_dir/$f" "$SCRIPTS_DIR/.new/$f" || return 1
        chmod "$mode" "$SCRIPTS_DIR/.new/$f" || return 1
    done
    for f in "$@"; do
        [ -f "$SCRIPTS_DIR/.new/$f" ] || continue
        mv -f "$SCRIPTS_DIR/.new/$f" "$SCRIPTS_DIR/$f" || return 1
    done
    rmdir "$SCRIPTS_DIR/.new" 2>/dev/null
    return 0
}

restore_scripts() {
    [ -d "$PREV_DIR" ] || return 1
    replace_files "$PREV_DIR" $SCRIPTS
}

# Доливает отсутствующие ключи из дефолтов. jq `*` рекурсивно сливает объекты,
# правый операнд (текущие настройки) имеет приоритет; массивы заменяются целиком.
merge_settings() {
    local def_file="$1"
    [ -f "$def_file" ] || return 0
    [ -f "$SETTINGS_JSON" ] || return 0
    if jq --slurpfile def "$def_file" '. as $cur | $def[0] * $cur' "$SETTINGS_JSON" \
        >"${SETTINGS_JSON}.new" 2>>"$LOG"; then
        mv "${SETTINGS_JSON}.new" "$SETTINGS_JSON" && chmod 600 "$SETTINGS_JSON"
        return 0
    fi
    rm -f "${SETTINGS_JSON}.new"
    return 1
}

# ============================================
#   РАЗБОР АРГУМЕНТОВ
# ============================================

case "${1:-}" in
"" ) MODE="apply" ;;
--check ) MODE="check" ;;
--force ) MODE="force" ;;
--rollback ) MODE="rollback" ;;
-h | --help )
    usage
    exit 0
    ;;
* )
    echo "Неизвестный аргумент: $1" >&2
    usage
    exit 2
    ;;
esac

rotate_log "$LOG"

# ============================================
#   ОТКАТ
# ============================================

if [ "$MODE" = "rollback" ]; then
    if [ ! -d "$PREV_DIR" ]; then
        die "Нет копии предыдущих скриптов: $PREV_DIR"
    fi
    if ! restore_scripts; then
        die "Не удалось восстановить скрипты из $PREV_DIR"
    fi
    rm -f "$SHA_FILE"
    log "[+] Скрипты восстановлены из $PREV_DIR (следующий запуск снова поставит обновление)"
    exit 0
fi

# ============================================
#   ИСТОЧНИК ОБНОВЛЕНИЙ
# ============================================

[ -n "$ARCHIVE_URL" ] || ARCHIVE_URL=$(settings_get ".update.archive_url")
[ -n "$ARCHIVE_URL" ] || ARCHIVE_URL="$DEFAULT_ARCHIVE_URL"

mkdir -p "$STATE_DIR" "$TMP_DIR" || die "Не удалось создать $STATE_DIR или $TMP_DIR"

FREE_KB=$(df "$TMP_DIR" | awk 'NR==2 {print $4}')
if [ "${FREE_KB:-0}" -lt 4096 ]; then
    die "Мало места в $TMP_DIR: ${FREE_KB}KB (нужно 4MB)"
fi

if ! fetch_url "${ARCHIVE_URL}.sha256" "$TMP_DIR/latest.zip.sha256"; then
    log "[!] Не удалось получить sha256 архива ($ARCHIVE_URL.sha256) — пропускаем"
    exit 0
fi

REMOTE_SHA=$(cut -d' ' -f1 "$TMP_DIR/latest.zip.sha256" | head -1)
if ! valid_sha "$REMOTE_SHA"; then
    die "Некорректный sha256 в latest.zip.sha256: '$REMOTE_SHA'"
fi

LOCAL_SHA=""
[ -f "$SHA_FILE" ] && LOCAL_SHA=$(cat "$SHA_FILE" 2>/dev/null)

if [ "$MODE" = "check" ]; then
    echo "установлено: ${LOCAL_SHA:-—}"
    echo "доступно:   $REMOTE_SHA"
    if [ "$REMOTE_SHA" = "$LOCAL_SHA" ] && installed_complete; then
        echo "обновление не требуется"
    else
        echo "доступно обновление"
    fi
    exit 0
fi

if [ "$MODE" != "force" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ] && installed_complete; then
    log "✓ Скрипты актуальны: $REMOTE_SHA"
    exit 0
fi

log "===== $(date '+%Y-%m-%d %H:%M:%S') Обновление скриптов ====="
log "→ установлено: ${LOCAL_SHA:-—}"
log "→ доступно:   $REMOTE_SHA"

# ============================================
#   СКАЧИВАНИЕ И ПРОВЕРКА
# ============================================

if ! download_verified; then
    die "Не удалось скачать и проверить latest.zip"
fi

rm -rf "$TMP_DIR/new"
mkdir -p "$TMP_DIR/new" || die "Не удалось создать $TMP_DIR/new"
if ! unzip -q "$TMP_DIR/latest.zip" -d "$TMP_DIR/new" >>"$LOG" 2>&1; then
    die "Не удалось распаковать latest.zip"
fi

NEW_DIR=$(ls -d "$TMP_DIR"/new/*/ 2>/dev/null | head -1)
NEW_DIR=${NEW_DIR%/}
[ -n "$NEW_DIR" ] && [ -d "$NEW_DIR" ] || die "В архиве нет каталога с файлами"

# MANIFEST.txt лежит в корне архива (zip -j), но допускаем и вариант внутри префикса
COMMIT=""
for manifest in "$TMP_DIR/new/MANIFEST.txt" "$NEW_DIR/MANIFEST.txt"; do
    [ -f "$manifest" ] || continue
    COMMIT=$(sed -n 's/^commit: //p' "$manifest" | head -1)
    [ -n "$COMMIT" ] && break
done
log "→ версия архива: ${COMMIT:-неизвестна}"

if ! check_syntax; then
    die "Новые скрипты не прошли проверку синтаксиса — установка отменена"
fi

# ============================================
#   ПРИМЕНЕНИЕ
# ============================================

backup_scripts || die "Не удалось сохранить копию текущих скриптов в $PREV_DIR"

if ! replace_files "$NEW_DIR" $SCRIPTS; then
    log "[!] Ошибка применения — откатываемся"
    restore_scripts || log "[X] Откат не удался, проверьте $PREV_DIR вручную"
    die "Обновление не применено"
fi

if ! installed_complete; then
    log "[!] После применения не хватает файлов — откатываемся"
    restore_scripts || log "[X] Откат не удался, проверьте $PREV_DIR вручную"
    die "Обновление не применено"
fi

# settings.default.json — эталон для следующих обновлений, настройки не перезаписывает
if [ -f "$NEW_DIR/settings.default.json" ]; then
    replace_files "$NEW_DIR" settings.default.json || log "[!] Не удалось обновить settings.default.json"
    if merge_settings "$SCRIPTS_DIR/settings.default.json"; then
        log "✓ settings.json дополнен отсутствующими ключами"
    else
        log "[!] Не удалось долить ключи в $SETTINGS_JSON — проверьте файл вручную"
    fi
fi

echo "$REMOTE_SHA" >"$SHA_FILE"

rm -rf "$TMP_DIR/new"

log "[+] Скрипты обновлены до ${COMMIT:-$REMOTE_SHA}"
log "→ перезапустите update-xray.sh, чтобы применить новые парсер и генератор"
log "===== Готово ====="

flock -u 200
exit 0
