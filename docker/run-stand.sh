#!/bin/sh
# Стенд XPowerSpirit-OpenWRT: парсер → генератор → проверка конфига ядром.
#
# Пресет журналирования берётся из LOG_PRESET (по умолчанию debug — на стенде нужен
# подробный журнал, на роутере стоит quiet). Пресет пишется в settings.json стенда,
# поэтому проверяется ровно тот путь, которым идёт генератор на устройстве.
set -eu

SRC=${SRC:-/src}
WORK=${WORK:-/work}
PRESET=${LOG_PRESET:-debug}
# Один и тот же HWID во всех прогонах: провайдер считает устройства по HWID,
# иначе каждый запуск занимал бы новый слот в подписке
HWID=${HWID:-0123456789abcdef0123456789abcdef}
SUB_URL=${SUB_URL:-}
REMARKS=${REMARKS:-}

export XRAY_LOCATION_ASSET=${XRAY_LOCATION_ASSET:-/usr/share/xray}

# Каталог журналов: Xray открывает их ещё на `run -test`, а на устройстве его создают
# установщик и init.d (строка `mkdir -p /tmp/log`)
mkdir -p /tmp/log "$WORK"
SETTINGS="$WORK/settings.json"
jq --arg p "$PRESET" --arg h "$HWID" --arg u "$SUB_URL" \
    '.log.preset = $p | .hwid = $h | .subscription.url = $u' \
    "$SRC/settings.default.json" >"$SETTINGS"
export XRAY_SETTINGS_FILE="$SETTINGS"

printf '=== Стенд XPowerSpirit-OpenWRT ===\n'
printf 'xray: %s\n' "$(xray version | head -1)"
printf 'пресет журналирования: %s\n' "$PRESET"
printf 'HWID: %s\n\n' "$HWID"

# Имя хоста подписки без токена: логи стенда не должны светить URL целиком
sub_host() { printf '%s' "$1" | awk -F/ '{print $3}'; }

# Реальная подписка: ровно тот путь, которым идёт update-xray.sh на устройстве
real_subscription() {
    url=$1
    printf -- '--- реальная подписка: %s ---\n' "$(sub_host "$url")"
    ua=$(jq -r '.subscription.user_agent' "$SETTINGS")
    printf 'User-Agent: %s, x-hwid: %s\n' "$ua" "$HWID"

    raw="$WORK/sub_real.txt"
    if ! curl -fsS -L --max-time 30 -H "User-Agent: $ua" -H "x-hwid: $HWID" -o "$raw" "$url"; then
        printf '[FAIL] не удалось скачать подписку\n'
        return 1
    fi
    if head -n 1 "$raw" 2>/dev/null | grep -qi '<html\|<!DOCTYPE'; then
        printf '[FAIL] подписка вернула HTML вместо данных\n'
        return 1
    fi
    printf 'получено: %s байт\n' "$(wc -c <"$raw")"

    set -- --ua "$ua"
    [ -n "$REMARKS" ] && set -- "$@" --remarks "$REMARKS"
    if ! python3 "$SRC/xray-sub-parser.py" "$@" <"$raw" >"$WORK/parsed_real.json"; then
        printf '[FAIL] парсер не смог разобрать подписку (код выше)\n'
        return 1
    fi
    python3 - "$WORK/parsed_real.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(f'  серверов: {len(data.get("outbounds", []))}, hole: {data.get("hole")}')
PY

    if ! python3 "$SRC/xray-generate-config.py" --output "$WORK/config_real.json" \
        <"$WORK/parsed_real.json"; then
        printf '[FAIL] генератор конфига\n'
        return 1
    fi
    if ! xray run -test -config "$WORK/config_real.json"; then
        printf '[FAIL] xray run -test: конфиг из подписки невалиден\n'
        return 1
    fi
    printf '[ OK ] конфиг из реальной подписки прошёл проверку ядром\n'
    printf 'секция log:\n'
    jq '.log' "$WORK/config_real.json"
}

# 1. Регрессия репозитория. Каталог tests/ локальный (в .gitignore и в архив не входит),
#    поэтому при отсутствии просто пропускаем.
if [ -f "$SRC/tests/run.sh" ]; then
    printf -- '--- tests/run.sh ---\n'
    sh "$SRC/tests/run.sh" || exit 1
    printf '\n'
else
    printf -- '[SKIP] tests/run.sh: каталог tests/ не смонтирован\n\n'
fi

# 2. Полный пайплайн на встроенной подписке
printf -- '--- демо-пайплайн на встроенной подписке ---\n'
cat >"$WORK/sub.txt" <<'SUBS'
vless://11111111-1111-1111-1111-111111111111@nl.example.com:443?type=tcp&security=tls&sni=nl.example.com#NL
vless://22222222-2222-2222-2222-222222222222@de.example.com:443?type=tcp&security=tls&sni=de.example.com#DE
SUBS

# UA определяет ожидаемый формат подписки: happ/singbox/karing/xpower — JSON,
# любой другой — Base64/VLESS. Для демо с vless:// берём нейтральный UA.
python3 "$SRC/xray-sub-parser.py" --ua "OpenWrt-Xray/1.0" <"$WORK/sub.txt" >"$WORK/parsed.json"
python3 "$SRC/xray-generate-config.py" --output "$WORK/config.json" <"$WORK/parsed.json"
xray run -test -config "$WORK/config.json"

printf '\nсекция log в сгенерированном config.json:\n'
jq '.log' "$WORK/config.json"

printf '\nжурнальные файлы после проверки ядром:\n'
ls -l /tmp/log/*.log 2>/dev/null || printf '  файлов нет — пресет без журналов\n'

if [ -n "$SUB_URL" ]; then
    printf '\n'
    real_subscription "$SUB_URL" || exit 1
else
    printf '\n[SKIP] реальная подписка: SUB_URL не задан\n'
fi

printf '\n=== Готово ===\n'
printf 'settings.json: %s\n' "$SETTINGS"
printf 'config.json:   %s\n' "$WORK/config.json"
case "$PRESET" in
debug) printf 'В пресете debug Xray пишет журнал доступа в /tmp/log/xray-access.log и ошибки в /tmp/log/xray-error.log\n' ;;
*) printf 'В пресете %s журналы Xray отключены (access/error = none)\n' "$PRESET" ;;
esac
