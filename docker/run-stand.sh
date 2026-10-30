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

# Runtime-проверка: `xray run -test` разбирает конфиг, но не запускает его.
# Здесь Xray реально стартует, и мы проверяем, что он жив, слушает 12345
# и не пишет [Error] в журнал.
runtime_smoke() {
    cfg=$1
    secs=${RUNTIME_SECONDS:-6}
    if [ "$secs" = "0" ]; then
        printf '[SKIP] runtime: RUNTIME_SECONDS=0\n'
        return 0
    fi

    printf -- '--- runtime: запуск Xray на %s с ---\n' "$secs"
    xray run -config "$cfg" >"$WORK/run.log" 2>&1 &
    pid=$!
    sleep "$secs"

    # Порт проверяем до остановки процесса: после kill сокет уже закрыт.
    # tproxy-inbound биндится на 0.0.0.0:12345 (0x3039) и виден в dual-stack таблицах.
    listening=0
    if grep -qi ':3039' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null; then
        listening=1
    fi

    alive=0
    kill -0 "$pid" 2>/dev/null && alive=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    errors=$(grep -c '\[Error\]' /tmp/log/xray-error.log 2>/dev/null || true)

    if [ "$alive" = 1 ] && [ "$listening" = 1 ] && [ "${errors:-0}" = 0 ]; then
        printf '[ OK ] Xray запустился, порт 12345 слушается, [Error] в журнале нет\n'
        return 0
    fi

    printf '[FAIL] Xray: жив=%s, порт 12345=%s, строк [Error]=%s\n' \
        "$alive" "$listening" "${errors:-0}"
    printf -- '--- сокеты (tcp6, первые 3 строки) ---\n'
    head -3 /proc/net/tcp6 2>/dev/null || true
    printf -- '--- run.log ---\n'
    head -20 "$WORK/run.log"
    grep '\[Error\]' /tmp/log/xray-error.log 2>/dev/null | head -10 || true
    return 1
}

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

    # Структурные проверки, которых нет в `xray run -test`: дубли тегов ломают
    # балансировщик (он выбирает по тегу), а селектор с несуществующим тегом
    # молча оставляет балансировщик без серверов.
    if ! python3 - "$WORK/config_real.json" <<'PY'; then
import json, sys

cfg = json.load(open(sys.argv[1]))
tags = [o.get("tag") for o in cfg.get("outbounds", [])]
dups = sorted({t for t in tags if tags.count(t) > 1})
balancers = (cfg.get("routing") or {}).get("balancers") or []
selector = balancers[0].get("selector") if balancers else []
missing = [s for s in selector if s not in tags]

print(f"  outbounds: {len(tags)}, дубликатов тегов: {len(dups)}")
print(f"  селектор балансировщика: {len(selector)}, нет среди outbounds: {len(missing)}")
if dups:
    print("  дубли: " + ", ".join(dups[:5]))
if missing:
    print("  нет в outbounds: " + ", ".join(missing[:5]))
sys.exit(0 if not dups and not missing else 1)
PY
        printf '[FAIL] структурная проверка конфига\n'
        return 1
    fi
    printf '[ OK ] структура конфига: теги уникальны, селектор ссылается на существующие\n'

    runtime_smoke "$WORK/config_real.json" || return 1
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
[{"remarks": "Demo", "outbounds": [
  {"tag": "nl", "protocol": "vless",
   "settings": {"vnext": [{"address": "nl.example.com", "port": 443,
                           "users": [{"id": "11111111-1111-1111-1111-111111111111", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "nl.example.com"}}},
  {"tag": "de", "protocol": "vless",
   "settings": {"vnext": [{"address": "de.example.com", "port": 443,
                           "users": [{"id": "22222222-2222-2222-2222-222222222222", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "de.example.com"}}}
]}]
SUBS

# Подписка всегда JSON; UA нужен только для запроса у провайдера.
python3 "$SRC/xray-sub-parser.py" --ua "XPower/1.2" <"$WORK/sub.txt" >"$WORK/parsed.json"
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
    printf '\n[SKIP] реальная подписка: SUB_URL не задан (вместе с ней пропускается runtime-проверка)\n'
fi

printf '\n=== Готово ===\n'
printf 'settings.json: %s\n' "$SETTINGS"
printf 'config.json:   %s\n' "$WORK/config.json"
case "$PRESET" in
debug) printf 'В пресете debug Xray пишет журнал доступа в /tmp/log/xray-access.log и ошибки в /tmp/log/xray-error.log\n' ;;
*) printf 'В пресете %s журналы Xray отключены (access/error = none)\n' "$PRESET" ;;
esac
