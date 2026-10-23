#!/bin/sh
# OpenWrt — переключение профиля Xray между normal и режимом белых списков (БС).
#
# Сторож опрашивает доступность напрямую (bs-probe.py ставит SO_MARK=2, поэтому
# пакеты обходят TProxy): если внешняя проба не проходит, а БС-проба (ya.ru/vk.com)
# проходит — оператор включил белые списки, и активным становится config.bs.json.
#
# Профили готовит update-xray.sh (или установщик), сторож только переключает их:
#   /etc/xray/config.normal.json  — обычная маршрутизация
#   /etc/xray/config.bs.json      — домены/адреса БС напрямую, остальное в прокси
# Активный профиль копируется в /etc/xray/config.json.

SETTINGS_JSON="/etc/xray/settings.json"
CONFIG="/etc/xray/config.json"
STATE_DIR="/etc/xray/state"
MODE_FILE="$STATE_DIR/mode"
STATE_FILE="$STATE_DIR/watchdog"
PROBE="/usr/share/xray/bs-probe.py"
LOG="/tmp/log/xray-mode.log"
LOCK_FILE="/var/lock/xray-mode.lock"
UPDATE_LOCK="/var/lock/xray-update.lock"
XRAY_BIN="${XRAY_BIN:-/usr/bin/xray}"
ASSET_DIR="${XRAY_LOCATION_ASSET:-/usr/share/xray}"

mkdir -p /tmp/log "$STATE_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"
}

die() {
    log "[X] $1"
    echo "[X] $1" >&2
    exit 1
}

rotate_log() {
    [ -f "$LOG" ] || return
    local size
    size=$(stat -c%s "$LOG" 2>/dev/null || wc -c <"$LOG")
    [ "$size" -gt 262144 ] && : >"$LOG"
}

settings_get() {
    local key="$1"
    [ -f "$SETTINGS_JSON" ] || return 1
    jq -r "
        if $key | type == \"boolean\" then
            if $key then \"1\" else \"0\" end
        elif $key | type == \"array\" then
            $key[]
        else
            $key // empty
        end
    " "$SETTINGS_JSON" 2>/dev/null
}

setting_num() {
    local key="$1" def="$2" val
    val=$(settings_get "$key" 2>/dev/null)
    case "$val" in
    '' | *[!0-9]*) echo "$def" ;;
    *) echo "$val" ;;
    esac
}

# ---------------------------------------------------------------- состояние

state_get() {
    local key="$1" def="$2" val
    val=$(grep -m1 "^$key=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-)
    echo "${val:-$def}"
}

state_set() {
    local key="$1" val="$2"
    local tmp="${STATE_FILE}.tmp"
    { grep -v "^$key=" "$STATE_FILE" 2>/dev/null; echo "$key=$val"; } >"$tmp"
    mv "$tmp" "$STATE_FILE"
}

reset_counters() {
    state_set candidate ""
    state_set streak 0
}

active_mode() {
    local mode
    mode=$(cat "$MODE_FILE" 2>/dev/null)
    [ -n "$mode" ] || mode="normal"
    echo "$mode"
}

profile_for() {
    echo "/etc/xray/config.$1.json"
}

# ---------------------------------------------------------------- проверки

xray_healthy() {
    pidof xray >/dev/null 2>&1 || return 1
    nft list chain inet fw4 xray_tproxy >/dev/null 2>&1 || return 1
    [ -s "$CONFIG" ] || return 1
    return 0
}

probe_state() {
    [ -x "$PROBE" ] || [ -f "$PROBE" ] || return 1
    python3 "$PROBE" --json 2>>"$LOG" | jq -r '.state // "unknown"' 2>/dev/null
}

# ---------------------------------------------------------------- переключение

switch_to() {
    local new="$1" profile
    profile=$(profile_for "$new")

    if [ ! -s "$profile" ]; then
        log "[!] Профиль $profile отсутствует — переключение в '$new' невозможно"
        return 1
    fi

    # Не мешаем update-xray.sh: он держит этот же файл блокировки
    exec 201>"$UPDATE_LOCK"
    if ! flock -n 201; then
        log "[!] Идёт обновление (update-xray.sh) — переключение отложено"
        exec 201>&-
        return 1
    fi

    local tmp="/tmp/xray-config.new"
    cp "$profile" "$tmp" || {
        log "[X] Не удалось скопировать $profile"
        flock -u 201
        exec 201>&-
        return 1
    }

    # Новый профиль ставим только после успешной проверки ядром
    if ! XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$tmp" >>"$LOG" 2>&1; then
        log "[X] Профиль $profile не прошёл xray run -test — остаёмся в '$(active_mode)'"
        rm -f "$tmp"
        flock -u 201
        exec 201>&-
        return 1
    fi

    mv "$tmp" "$CONFIG" || {
        log "[X] Не удалось заменить $CONFIG"
        flock -u 201
        exec 201>&-
        return 1
    }
    echo "$new" >"$MODE_FILE"
    state_set last_switch "$(date +%s)"
    reset_counters

    log "[+] Профиль переключён на '$new'"
    /etc/init.d/xray restart >>"$LOG" 2>&1 || log "[!] Не удалось перезапустить Xray"
    log "[i] Активный режим: $(active_mode)"

    flock -u 201
    exec 201>&-
    return 0
}

force_mode() {
    local target="$1"
    case "$target" in
    normal | bs) ;;
    *) die "Неизвестный режим '$target' (ожидается normal или bs)" ;;
    esac
    log "[i] Принудительное переключение в '$target'"
    switch_to "$target" || exit 1
}

# ---------------------------------------------------------------- один цикл

# Интервал до следующего цикла; iteration() не пишет в stdout (его занимает
# probe_state), поэтому результат передаётся через эту переменную.
SLEEP_FOR=60

iteration() {
    local confirm back_confirm dwell interval now last_attempt

    confirm=$(setting_num ".bs.confirmations" 3)
    back_confirm=$(setting_num ".bs.back_confirmations" 2)
    dwell=$(setting_num ".bs.min_dwell" 600)
    interval=$(setting_num ".bs.interval" 60)
    [ "$interval" -lt 30 ] && interval=30
    SLEEP_FOR=$interval

    # Сломанный Xray — это не БС: лечим перезапуском, а не переключением профиля
    if ! xray_healthy; then
        log "[!] Xray не запущен или правила TProxy отсутствуют — перезапуск"
        /etc/init.d/xray restart >>"$LOG" 2>&1
        return 0
    fi

    local state candidate streak current need
    state=$(probe_state)
    if [ -z "$state" ]; then
        log "[!] Не удалось выполнить bs-probe.py"
        return 0
    fi

    current=$(active_mode)
    if [ "$state" = "unknown" ]; then
        # Нет ни внешней сети, ни БС-ресурсов: линк не поднят или что-то сломано
        reset_counters
        return 0
    fi

    if [ "$state" = "$current" ]; then
        reset_counters
        return 0
    fi

    candidate=$(state_get candidate "")
    streak=$(state_get streak 0)
    if [ "$state" = "$candidate" ]; then
        streak=$((streak + 1))
    else
        candidate="$state"
        streak=1
        state_set candidate "$candidate"
    fi
    state_set streak "$streak"

    need=$confirm
    [ "$state" = "normal" ] && need=$back_confirm

    if [ "$streak" -lt "$need" ]; then
        return 0
    fi

    now=$(date +%s)
    if [ $((now - $(state_get last_switch 0))) -lt "$dwell" ]; then
        return 0
    fi

    # Не спамим попытками перезаписи, если профиль сломан
    last_attempt=$(state_get last_attempt 0)
    if [ $((now - last_attempt)) -lt 300 ]; then
        return 0
    fi
    state_set last_attempt "$now"

    switch_to "$state" || true
    return 0
}

# ---------------------------------------------------------------- main

MODE="auto"

while [ $# -gt 0 ]; do
    case "$1" in
    --force) MODE="${2:-}"; shift 2 ;;
    --force=*) MODE="${1#*=}"; shift ;;
    --reset)
        reset_counters
        log "[i] Счётчики подтверждений сброшены"
        exit 0
        ;;
    --once)
        MODE="once"
        shift
        ;;
    *)
        echo "Использование: $0 [--once] [--reset] [--force normal|bs]" >&2
        exit 1
        ;;
    esac
done

rotate_log

if [ "$MODE" = "once" ]; then
    iteration
    echo "state=$(probe_state) mode=$(active_mode)"
    exit 0
fi

if [ "$MODE" != "auto" ]; then
    force_mode "$MODE"
    exit 0
fi

# Один экземпляр сторожа
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Сторож уже запущен" >&2
    exit 1
fi

trap 'log "[i] Сторож остановлен"; exit 0' TERM INT

log "[i] Сторож запущен, режим: $(active_mode)"

while :; do
    iteration
    sleep "${SLEEP_FOR:-60}"
    rotate_log
done
