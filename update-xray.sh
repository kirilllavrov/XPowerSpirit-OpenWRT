#!/bin/sh
# OpenWrt — обновление Xray, geoip, geosite, подписки и config.json
# Подписка — только JSON (Happ/Sing-box/XPower). User-Agent задаётся в
# settings.json → subscription.user_agent и передаётся провайдеру.

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

# Блокировка от одновременного запуска
LOCK_FILE="/var/lock/xray-update.lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Другой экземпляр уже запущен" >&2
    exit 1
fi

LOG="/tmp/log/xray-update.log"
mkdir -p /tmp/log

die() {
    echo "[X] $1" | tee -a "$LOG"
    exit 1
}

# Единая функция загрузки (curl)
fetch_url() {
    local url="$1"
    local dst="$2"
    local max_retries=2
    local retry=1

    # Системные заголовки из settings.json
    local _ua _ver _model _os
    _ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "OpenWrt-Xray/1.0")
    _ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
    _model=$(settings_get ".device_model" 2>/dev/null || echo "")
    _os=$(settings_get ".device_os" 2>/dev/null || echo "")

    while [ $retry -le $max_retries ]; do
        curl -fsS -L --max-time 15 \
            -H "User-Agent: $_ua" \
            ${_ver:+-H "X-Ver-Os: $_ver"} \
            ${_model:+-H "X-Device-Model: $_model"} \
            ${_os:+-H "X-Device-Os: $_os"} \
            -o "$dst" "$url"
        local rc=$?

        if [ $rc -eq 0 ] && [ -s "$dst" ]; then
            if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
                rm -f "$dst"
            else
                return 0
            fi
        fi

        if [ $retry -lt $max_retries ]; then
            sleep 2
        fi
        retry=$((retry + 1))
    done

    return 1
}

CONFIG_DIR="/etc/xray"
SETTINGS_JSON="$CONFIG_DIR/settings.json"
CONFIG_JSON="$CONFIG_DIR/config.json"

# =============================================
#   ОБЩИЕ ХЕЛПЕРЫ (settings.json, архитектура, ротация)
# =============================================
# Код живёт в xray-common.sh: те же функции нужны установщику. Если библиотеки нет
# (например, скрипты обновились раньше, чем собрался архив), пробуем скачать её один раз.
COMMON_SH="/usr/share/xray/xray-common.sh"
REPO_RAW="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main"
if [ ! -r "$COMMON_SH" ]; then
    echo "[!] Нет $COMMON_SH — скачиваем" >>"$LOG"
    mkdir -p "$(dirname "$COMMON_SH")"
    if curl -fsS -L --max-time 15 -o "$COMMON_SH" "$REPO_RAW/xray-common.sh" 2>>"$LOG"; then
        chmod 755 "$COMMON_SH"
    else
        rm -f "$COMMON_SH"
    fi
fi
[ -r "$COMMON_SH" ] ||
    die "Нет $COMMON_SH — проверьте сеть или выполните /usr/share/xray/update-scripts.sh"
. "$COMMON_SH"

STATE_DIR="/etc/xray/state"
TMP_DIR="/tmp/xray_update"

GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"

# Пути нужны sync_cron: по ним распознаются и перезаписываются строки crontab
UPDATER="/usr/share/xray/update-xray.sh"
SCRIPTS_UPDATER="/usr/share/xray/update-scripts.sh"

GEO_DIR="/usr/share/xray"
GEOIP="$GEO_DIR/geoip.dat"
GEOSITE="$GEO_DIR/geosite.dat"

GEOIP_URL=$(settings_get ".geo.geoip_url")
GEOSITE_URL=$(settings_get ".geo.geosite_url")

mkdir -p "$STATE_DIR" "$TMP_DIR"

echo "===== $(date) =====" >>"$LOG"

# =============================================
#   Синхронизация crontab по settings.json → update.cron
# =============================================
# Расписание живёт в настройках, а не в crontab: при изменении update.cron.*
# строки перезаписываются здесь, переустановка не нужна.
sync_cron() {
    local scripts_cron xray_cron tmpfile
    scripts_cron=$(settings_get ".update.cron.scripts" 2>/dev/null)
    xray_cron=$(settings_get ".update.cron.xray" 2>/dev/null)
    [ -n "$scripts_cron" ] || scripts_cron="20 2 * * *"
    [ -n "$xray_cron" ] || xray_cron="30 2 * * *"

    # Ровно пять полей: иначе cron молча не выполнит задачу.
    # Считаем через awk, а не `set -- $_c`: звёздочки в расписании раскрылись бы
    # как имена файлов текущего каталога.
    local _c _n
    for _c in "$scripts_cron" "$xray_cron"; do
        _n=$(printf '%s' "$_c" | awk '{print NF}')
        if [ "$_n" -ne 5 ]; then
            echo "[!] Расписание '$_c' из update.cron некорректно (нужно 5 полей) — оставлено прежнее" >>"$LOG"
            return 0
        fi
    done

    tmpfile=$(mktemp) || return 0
    crontab -l 2>/dev/null |
        grep -v -e "$SCRIPTS_UPDATER" -e "$UPDATER" -e '^[[:space:]]*$' >"$tmpfile"
    echo "$scripts_cron $SCRIPTS_UPDATER >>/tmp/log/xray-scripts.log 2>&1" >>"$tmpfile"
    echo "$xray_cron $UPDATER >>/tmp/log/xray-update.log 2>&1" >>"$tmpfile"

    # Сравнение строк, а не diff: в OpenWrt утилиты diff по умолчанию нет
    if [ "$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*$')" = "$(cat "$tmpfile")" ]; then
        rm -f "$tmpfile"
        return 0
    fi
    if crontab "$tmpfile"; then
        echo "[+] Расписание обновлений синхронизировано: скрипты '$scripts_cron', Xray '$xray_cron'" >>"$LOG"
    else
        echo "[!] Не удалось обновить crontab" >>"$LOG"
    fi
    rm -f "$tmpfile"
}

sync_cron

# =============================================
#   Очистка/ротация логов (rotate_log из xray-common.sh)
# =============================================
# Порог ротации зависит от пресета log.preset (settings.json): на роутере журналы
# выключены или маленькие, на стенде нужен подробный журнал, поэтому порог выше
LOG_PRESET=$(settings_get ".log.preset" 2>/dev/null)
[ -n "$LOG_PRESET" ] || LOG_PRESET="quiet"
case "$LOG_PRESET" in
debug)
    ACCESS_MAX=2097152 # 2MB
    ERROR_MAX=1048576  # 1MB
    ;;
*)
    ACCESS_MAX=524288 # 512KB
    ERROR_MAX=262144  # 256KB
    ;;
esac
rotate_log "/tmp/log/xray-access.log" "$ACCESS_MAX"
rotate_log "/tmp/log/xray-error.log" "$ERROR_MAX"
rotate_log "$LOG" 262144

# Проверка свободного места в /
FREE_SPACE_ROOT=$(df / | awk 'NR==2 {print $4}')
if [ "$FREE_SPACE_ROOT" -lt 10240 ]; then
    die "Недостаточно места в / (нужно минимум 10MB, доступно ${FREE_SPACE_ROOT}KB)"
fi

# ============================
#   HWID + подписка + настройки (из settings.json)
# ============================

[ -f "$SETTINGS_JSON" ] || die "Нет $SETTINGS_JSON"

HWID="$(settings_get ".hwid")"
[ -z "$HWID" ] && die "HWID пуст в settings.json"

SUB_URL="$(settings_get ".subscription.url")"
[ -z "$SUB_URL" ] && die "Пустой URL подписки в settings.json"

# Читаем User-Agent для подписки
SUB_USER_AGENT="$(settings_get ".subscription.user_agent")"
[ -z "$SUB_USER_AGENT" ] && SUB_USER_AGENT="OpenWrt-Xray/1.0"
echo "→ User-Agent: $SUB_USER_AGENT" >>"$LOG"

# Читаем фильтр remarks для JSON-формата
REMARKS_FILTER="$(settings_get ".subscription.remarks_filter")"
[ -n "$REMARKS_FILTER" ] && echo "→ Фильтр remarks: $REMARKS_FILTER" >>"$LOG"

# ============================
#   Обновление Xray
# ============================

# Проверяет и при необходимости обновляет /usr/bin/xray.
# Любая проблема (нет сети, нет релиза под архитектуру, не хватает места) — это
# осознанный пропуск: обновление geo-файлов и конфига должно продолжиться.
update_xray_binary() {
    local latest version_num current machine zip_url zip_dest sha_file
    local remote_sha local_sha free_tmp

    echo "→ Проверка обновлений Xray..." >>"$LOG"

    # Ожидание доступности GitHub API
    for i in $(seq 1 5); do
        curl -s --max-time 3 https://api.github.com >/dev/null 2>&1 && break
        sleep 2
    done

    latest=$(curl -fsS --user-agent "OpenWrt-Xray/1.0" --max-time 10 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest |
        jq -r '.tag_name // empty')
    if [ -z "$latest" ]; then
        echo "[!] Не удалось получить версию Xray — пропускаем обновление" >>"$LOG"
        return 0
    fi

    version_num="${latest#v}"
    current=""
    [ -x /usr/bin/xray ] && current=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')

    machine=$(resolve_xray_machine)
    if [ -z "$machine" ]; then
        # Без своего бинаря не трогаем установленный: иначе рабочий xray заменится
        echo "[!] Архитектура $(uname -m) не поддерживается релизами Xray — обновление бинаря пропущено" >>"$LOG"
        return 0
    fi

    zip_url="https://github.com/XTLS/Xray-core/releases/download/${latest}/Xray-linux-${machine}.zip"
    zip_dest="$TMP_DIR/xray.zip"
    sha_file="$STATE_DIR/xray.zip.sha256sum"

    if ! fetch_url "${zip_url}.dgst" "$STATE_DIR/xray.dgst"; then
        echo "[!] Не удалось скачать .dgst" >>"$LOG"
        return 0
    fi

    remote_sha=$(extract_sha256 "$STATE_DIR/xray.dgst")
    if [ -z "$remote_sha" ]; then
        echo "[!] Не удалось извлечь SHA из .dgst" >>"$LOG"
        return 0
    fi

    free_tmp=$(df /tmp | awk 'NR==2 {print $4}')
    if [ "$free_tmp" -lt 20480 ]; then
        echo "[!] Недостаточно места в /tmp (нужно минимум 20MB) — пропускаем" >>"$LOG"
        return 0
    fi

    if [ -f "$sha_file" ] && [ "$(cat "$sha_file")" = "$remote_sha" ] && [ "$current" = "$version_num" ]; then
        echo "✓ Xray ZIP не изменился, версия $current актуальна" >>"$LOG"
        return 0
    fi

    echo "→ Скачиваем Xray ZIP..." >>"$LOG"
    if ! fetch_url "$zip_url" "$zip_dest"; then
        echo "[!] Не удалось скачать Xray ZIP" >>"$LOG"
        return 0
    fi

    local_sha=$(sha256sum "$zip_dest" | awk '{print $1}')
    if [ "$local_sha" != "$remote_sha" ]; then
        echo "[X] SHA не совпадает для Xray ZIP" >>"$LOG"
        return 1
    fi

    echo "$remote_sha" >"$sha_file"
    unzip -q "$zip_dest" -d "$TMP_DIR"
    if [ ! -f "$TMP_DIR/xray" ]; then
        echo "[!] Не удалось распаковать Xray" >>"$LOG"
        return 1
    fi

    # Останавливаем Xray перед обновлением
    /etc/init.d/xray stop 2>/dev/null
    cp "$TMP_DIR/xray" /usr/bin/xray
    chmod 755 /usr/bin/xray
    echo "[+] Xray обновлён до $latest" >>"$LOG"
    return 0
}

update_xray_binary

# ============================
#   GEOIP / GEOSITE
# ============================

update_geo() {
    local URL="$1"
    local DEST="$2"
    local BASE=$(basename "$DEST")
    local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"
    local TMP_DEST="${TMP_DIR}/${BASE}"
    local TMP_SHA="${TMP_DIR}/${BASE}.sha256"

    echo "→ Обновление $BASE..." >>"$LOG"

    if [ -z "$URL" ]; then
        echo "[!] В settings.json не задан URL для $BASE (geo.geoip_url / geo.geosite_url) — пропускаем" >>"$LOG"
        return 1
    fi

    # Скачиваем SHA256
    if ! fetch_url "${URL}.sha256sum" "$TMP_SHA"; then
        echo "[!] Не удалось скачать sha256sum для $BASE (${URL}.sha256sum) — пропускаем" >>"$LOG"
        return 1
    fi

    REMOTE_SHA=$(cut -d' ' -f1 "$TMP_SHA")
    if [ -z "$REMOTE_SHA" ]; then
        echo "[!] Пустой sha256sum для $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    # Проверяем, нужно ли обновлять
    if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$DEST" ]; then
        echo "✓ $BASE не изменился" >>"$LOG"
        return 0
    fi

    # Скачиваем сам файл
    if ! fetch_url "$URL" "$TMP_DEST"; then
        echo "[!] Не удалось скачать $BASE — пропускаем" >>"$LOG"
        return 1
    fi

    # Проверяем SHA
    LOCAL_SHA=$(sha256sum "$TMP_DEST" | awk '{print $1}')
    if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
        echo "[X] SHA не совпадает для $BASE" >>"$LOG"
        rm -f "$TMP_DEST"
        return 1
    fi

    # Подмена через rename в каталоге назначения: /tmp — tmpfs, поэтому mv между ФС
    # копирует, и обрыв питания оставил бы обрезанный geo-файл.
    local DEST_NEW="${DEST}.new"
    local NEED_KB=$(($(wc -c <"$TMP_DEST") / 1024 + 1024))
    local FREE_KB_TARGET=$(df "$(dirname "$DEST")" | awk 'NR==2 {print $4}')
    if [ "${FREE_KB_TARGET:-0}" -lt "$NEED_KB" ]; then
        echo "[!] Мало места в $(dirname "$DEST") для $BASE: ${FREE_KB_TARGET}KB, нужно ${NEED_KB}KB — пропускаем" >>"$LOG"
        rm -f "$TMP_DEST"
        return 1
    fi
    if ! cp "$TMP_DEST" "$DEST_NEW"; then
        echo "[!] Не удалось скопировать $BASE в $DEST_NEW — пропускаем" >>"$LOG"
        rm -f "$DEST_NEW" "$TMP_DEST"
        return 1
    fi
    if [ "$(sha256sum "$DEST_NEW" | awk '{print $1}')" != "$REMOTE_SHA" ]; then
        echo "[X] SHA не совпадает для $DEST_NEW — $BASE не заменён" >>"$LOG"
        rm -f "$DEST_NEW" "$TMP_DEST"
        return 1
    fi
    mv "$DEST_NEW" "$DEST"
    rm -f "$TMP_DEST"
    echo "$REMOTE_SHA" >"$SHA_FILE"
    echo "[+] $BASE обновлён" >>"$LOG"
}

update_geo "$GEOIP_URL" "$GEOIP"
update_geo "$GEOSITE_URL" "$GEOSITE"

# ============================
#   Генерация config.json
# ============================

# Скачивает подписку, прогоняет парсер и генератор, проверяет результат ядром
# и подменяет /etc/xray/config.json. При любой ошибке прежний конфиг остаётся.
generate_config() {
    local ver model os parse_rc new_config

    echo "→ Генерация config.json (User-Agent: $SUB_USER_AGENT)..." >>"$LOG"

    # Системные заголовки для запроса подписки
    ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
    model=$(settings_get ".device_model" 2>/dev/null || echo "")
    os=$(settings_get ".device_os" 2>/dev/null || echo "")

    if ! curl -fsS -L \
        -H "User-Agent: $SUB_USER_AGENT" \
        -H "x-hwid: $HWID" \
        ${ver:+-H "X-Ver-Os: $ver"} \
        ${model:+-H "X-Device-Model: $model"} \
        ${os:+-H "X-Device-Os: $os"} \
        "$SUB_URL" -o "$TMP_DIR/sub.txt"; then
        echo "[!] Не удалось скачать подписку" >>"$LOG"
        return 1
    fi

    if head -n 1 "$TMP_DIR/sub.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        echo "[X] Подписка вернула HTML, а не данные" >>"$LOG"
        return 1
    fi

    # Единый пайплайн: парсер (JSON, с автоопределением по --ua) → генератор
    set -- --ua "$SUB_USER_AGENT"
    [ -n "$REMARKS_FILTER" ] && set -- "$@" --remarks "$REMARKS_FILTER"
    python3 "$PARSER" "$@" <"$TMP_DIR/sub.txt" >"$TMP_DIR/parsed.json" 2>>"$LOG"
    parse_rc=$?

    if [ "$parse_rc" -eq 2 ]; then
        echo "[X] Парсер не нашёл серверов и не увидел hole-сигнал — прежний config.json сохранён" >>"$LOG"
        return 1
    fi
    if [ "$parse_rc" -ne 0 ]; then
        echo "[X] Ошибка парсера подписки (код $parse_rc) — прежний config.json сохранён" >>"$LOG"
        return 1
    fi

    # Генерируем рядом с целевым файлом: подмена — rename в одной ФС, обрыв не
    # оставит половину config.json. Расширение .json обязательно: Xray выбирает
    # формат конфига по расширению, и на *.new `run -test` падает
    new_config="${CONFIG_JSON%.json}.new.json"
    rm -f "$new_config"
    if ! python3 "$GENERATOR" --format unified --output "$new_config" <"$TMP_DIR/parsed.json" 2>>"$LOG"; then
        rm -f "$new_config"
        echo "[X] Ошибка генератора конфига" >>"$LOG"
        return 1
    fi

    if ! xray run -test -config "$new_config" >>"$LOG" 2>&1; then
        echo "[X] Новый config.json невалиден" >>"$LOG"
        xray run -test -config "$new_config" 2>>"$LOG"
        rm -f "$new_config"
        return 1
    fi

    mv "$new_config" "$CONFIG_JSON"
    echo "[+] Новый config.json установлен" >>"$LOG"
    return 0
}

generate_config

# Очистка временных файлов
rm -f "$TMP_DIR/sub.txt" "$TMP_DIR/parsed.json" "$TMP_DIR/config.json"

# ============================
#   Финальная проверка config.json
# ============================

if [ -f "$CONFIG_JSON" ]; then
    if ! xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
        echo "[X] Итоговый config.json невалиден — отключаем Xray" >>"$LOG"
        /etc/init.d/xray stop 2>/dev/null
        exit 1
    fi
else
    echo "[X] config.json отсутствует — отключаем Xray" >>"$LOG"
    /etc/init.d/xray stop 2>/dev/null
    exit 1
fi

# ============================
#   Пересборка nftables правил
# ============================

echo "→ Обновление nftables правил..." >>"$LOG"
if /usr/share/xray/update-nft.sh >>"$LOG" 2>&1; then
    echo "[+] nftables правила обновлены" >>"$LOG"
else
    echo "[X] Ошибка при обновлении nftables" >>"$LOG"
    # Не останавливаем Xray, только логируем
fi

# ============================
#   Перезапуск Xray
# ============================

echo "→ Перезапуск Xray..." >>"$LOG"
if /etc/init.d/xray restart >>"$LOG" 2>&1; then
    echo "[+] Xray перезапущен успешно" >>"$LOG"
else
    echo "[!] Не удалось перезапустить Xray" >>"$LOG"
fi

echo "===== Готово =====" >>"$LOG"

# Очистка временных файлов
rm -rf "$TMP_DIR"

# Снятие блокировки
flock -u 200