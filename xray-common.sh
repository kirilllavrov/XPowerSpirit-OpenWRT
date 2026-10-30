#!/bin/sh
# shellcheck disable=SC1087 # $key[] внутри jq-программы — не shell-массив
# Общие функции скриптов XPowerSpirit-OpenWRT на роутере.
#
# Подключение:
#   . /usr/share/xray/xray-common.sh
#
# Вызывающий скрипт должен задать до первого вызова:
#   SETTINGS_JSON — путь к /etc/xray/settings.json (settings_get, settings_set)
#   LOG           — журнал скрипта (rotate_log; необязателен)
#
# Зависимости: jq, uname, /etc/openwrt_release (переопределяется XRAY_RELEASE_FILE).

# =============================================
#   ЕДИНЫЙ JSON-КОНФИГ (settings.json)
# =============================================

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

settings_set() {
    local key="$1"
    local val="$2"
    local tmp="${SETTINGS_JSON}.tmp"
    mkdir -p "$(dirname "$SETTINGS_JSON")"
    [ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
    rm -f "$tmp"
    if echo "$val" | grep -qE '^[0-9]+$'; then
        jq --argjson v "$val" "$key = \$v" "$SETTINGS_JSON" >"$tmp" 2>/dev/null
    else
        jq --arg v "$val" "$key = \$v" "$SETTINGS_JSON" >"$tmp" 2>/dev/null
    fi
    # jq мог отсутствовать или упасть: пустой/битый результат не должен затирать
    # настройки — иначе на устройстве остаётся settings.json нулевой длины
    if [ ! -s "$tmp" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$SETTINGS_JSON"
    chmod 600 "$SETTINGS_JSON"
}

# =============================================
#   АРХИТЕКТУРА XRAY
# =============================================

# Определение суффикса релизного ZIP Xray под архитектуру устройства.
# DISTRIB_ARCH из /etc/openwrt_release надёжнее uname: uname -m отдаёт "mips"
# и для big-endian, и для little-endian MIPS, а armv6l/armv5l не отличить от armv7l.
XRAY_RELEASE_FILE="${XRAY_RELEASE_FILE:-/etc/openwrt_release}"

detect_xray_machine() {
    local os_arch=""
    if [ -f "$XRAY_RELEASE_FILE" ]; then
        os_arch=$(. "$XRAY_RELEASE_FILE" 2>/dev/null; echo "$DISTRIB_ARCH")
    fi
    case "$os_arch" in
    aarch64*) echo "arm64-v8a" ;;
    arm_arm1176*) echo "arm32-v6" ;;
    arm_arm926* | arm_arm1136* | arm_xscale* | arm_fa526*) echo "arm32-v5" ;;
    arm_*) echo "arm32-v7a" ;;
    mips64el_*) echo "mips64le" ;;
    mips64_*) echo "mips64" ;;
    mipsel_*) echo "mips32le" ;;
    mips_*) echo "mips32" ;;
    riscv64*) echo "riscv64" ;;
    loongarch64*) echo "loong64" ;;
    powerpc64le*) echo "ppc64le" ;;
    powerpc64*) echo "ppc64" ;;
    s390x*) echo "s390x" ;;
    i386 | i486 | i586 | i686) echo "32" ;;
    x86_64) echo "64" ;;
    esac
}

# Итоговое имя платформы; пустая строка — архитектура не поддерживается
resolve_xray_machine() {
    local m
    m=$(detect_xray_machine)
    if [ -z "$m" ]; then
        case "$(uname -m)" in
        x86_64 | amd64) m="64" ;;
        i?86) m="32" ;;
        aarch64 | arm64) m="arm64-v8a" ;;
        armv8l | armv7l) m="arm32-v7a" ;;
        armv6l) m="arm32-v6" ;;
        armv5l | armv5tel) m="arm32-v5" ;;
        mipsel) m="mips32le" ;;
        mips) m="mips32" ;;
        mips64el) m="mips64le" ;;
        mips64) m="mips64" ;;
        riscv64) m="riscv64" ;;
        loongarch64) m="loong64" ;;
        ppc64le) m="ppc64le" ;;
        ppc64) m="ppc64" ;;
        s390x) m="s390x" ;;
        esac
    fi
    echo "$m"
}

# =============================================
#   ЗАГРУЗКА
# =============================================

# SHA2-256 из .dgst-файла релиза Xray
extract_sha256() {
    grep '^SHA2-256' "$1" |
        sed 's/.*= *//' |
        tr -cd '0-9a-fA-F' |
        cut -c1-64
}

# =============================================
#   РОТАЦИЯ ЖУРНАЛОВ
# =============================================

# rotate_log <файл> [макс. размер в байтах, по умолчанию 1MB]
# Журнал обнуляется при превышении порога; факт пишется в $LOG, если он задан.
rotate_log() {
    local file="$1"
    local max_size="${2:-1048576}"
    [ -f "$file" ] || return
    local size
    size=$(stat -c%s "$file" 2>/dev/null) || size=$(wc -c <"$file")
    if [ "${size:-0}" -gt "$max_size" ]; then
        : >"$file"
        if [ -n "${LOG:-}" ]; then
            echo "[*] Лог очищен: $file" >>"$LOG"
        fi
    fi
}
