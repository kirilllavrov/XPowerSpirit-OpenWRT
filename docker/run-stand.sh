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

export XRAY_LOCATION_ASSET=${XRAY_LOCATION_ASSET:-/usr/share/xray}

# Каталог журналов: Xray открывает их ещё на `run -test`, а на устройстве его создают
# установщик и init.d (строка `mkdir -p /tmp/log`)
mkdir -p /tmp/log "$WORK"
SETTINGS="$WORK/settings.json"
jq --arg p "$PRESET" '.log.preset = $p' "$SRC/settings.default.json" >"$SETTINGS"
export XRAY_SETTINGS_FILE="$SETTINGS"

printf '=== Стенд XPowerSpirit-OpenWRT ===\n'
printf 'xray: %s\n' "$(xray version | head -1)"
printf 'пресет журналирования: %s\n\n' "$PRESET"

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
printf -- '--- пайплайн: подписка → парсер → генератор → xray run -test ---\n'
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

printf '\n=== Готово ===\n'
printf 'settings.json: %s\n' "$SETTINGS"
printf 'config.json:   %s\n' "$WORK/config.json"
case "$PRESET" in
debug) printf 'В пресете debug Xray пишет журнал доступа в /tmp/log/xray-access.log и ошибки в /tmp/log/xray-error.log\n' ;;
*) printf 'В пресете %s журналы Xray отключены (access/error = none)\n' "$PRESET" ;;
esac
