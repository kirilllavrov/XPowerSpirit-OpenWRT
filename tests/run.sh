#!/bin/sh
# Прогон парсера и генератора на синтетических фикстурах — без устройства и без сети.
# Проверяет коды возврата, режим hole и защиту от префиксных коллизий тегов.
# Если найден бинарь xray, дополнительно валидирует сгенерированные конфиги.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARSER="$ROOT/xray-sub-parser.py"
GENERATOR="$ROOT/xray-generate-config.py"
TMP=$(mktemp -d /tmp/xray-tests.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

XRAY_BIN=${XRAY_BIN:-$(command -v xray 2>/dev/null || true)}
ASSET_DIR=${XRAY_LOCATION_ASSET:-}
if [ -z "$ASSET_DIR" ]; then
    for d in /usr/share/xray /usr/local/share/xray; do
        [ -f "$d/geoip.dat" ] && ASSET_DIR="$d" && break
    done
fi

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '[ OK ] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

assert_rc() {
    if [ "$1" = "$2" ]; then ok "$3 (rc=$1)"; else fail "$3: ожидался rc=$2, получен $1"; fi
}

assert_py() { # python-выражение над файлом
    if python3 -c "$1" "$2" 2>/dev/null; then ok "$3"; else fail "$3"; fi
}

# ---------------------------------------------------------------- фикстуры

mk_base64() {
    python3 - "$TMP/sub.b64" <<'PY'
import base64, sys
nodes = "\n".join([
    "vless://11111111-1111-1111-1111-111111111111@nl.example.com:443"
    "?type=ws&security=tls&sni=nl.example.com&path=%2Fws&host=nl.example.com#NL",
    "vless://22222222-2222-2222-2222-222222222222@hole:1?type=tcp&security=none#hole",
    "vless://00000000-0000-0000-0000-000000000000@1.2.3.4:443?type=tcp&security=none#stub",
])
open(sys.argv[1], "w").write(base64.b64encode(nodes.encode()).decode())
PY
}

mk_json_tags() {
    python3 - "$TMP/sub_tags.json" <<'PY'
import json, sys

def node(tag, host, uid):
    return {
        "tag": tag, "protocol": "vless",
        "settings": {"vnext": [{"address": host, "port": 443,
                                "users": [{"id": uid, "encryption": "none"}]}]},
        "streamSettings": {"network": "tcp", "security": "tls",
                           "tlsSettings": {"serverName": host}},
    }

data = [{"remarks": "Main", "outbounds": [
    node("d", "d.example.com", "11111111-1111-1111-1111-111111111111"),
    node("direct", "x.example.com", "22222222-2222-2222-2222-222222222222"),
    node("proxy", "y.example.com", "33333333-3333-3333-3333-333333333333"),
]}]
json.dump(data, open(sys.argv[1], "w"))
PY
}

mk_json_hole_freedom() {
    cat >"$TMP/sub_hole_freedom.json" <<'JSON'
[{"remarks": "Expired", "outbounds": [
    {"tag": "HOLE_SIGNAL", "protocol": "freedom", "settings": {"address": "hole"}}
]}]
JSON
}

mk_json_remarks() {
    cat >"$TMP/sub_remarks.json" <<'JSON'
[{"remarks": "Main", "outbounds": []}]
JSON
}

mk_unified() {
    cat >"$TMP/unified.json" <<'JSON'
{"hole": false, "outbounds": [
  {"tag": "proxy-a", "protocol": "vless",
   "settings": {"vnext": [{"address": "a.example.com", "port": 443,
                           "users": [{"id": "11111111-1111-1111-1111-111111111111", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "a.example.com"}}}
]}
JSON
    cat >"$TMP/unified_hole.json" <<'JSON'
{"hole": true, "outbounds": []}
JSON
}

# ---------------------------------------------------------------- прогоны

mk_base64
python3 "$PARSER" --ua "OpenWrt-Xray/1.0" <"$TMP/sub.b64" >"$TMP/p1.json" 2>"$TMP/e1"
assert_rc "$?" 0 "base64: разбор прошёл"
assert_py "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d['hole'] and len(d['outbounds'])==1 else 1)" \
    "$TMP/p1.json" "base64: hole найден, заглушка отброшена"

python3 "$PARSER" --ua "XPower/1.0" <"$TMP/sub.b64" >"$TMP/p2.json" 2>"$TMP/e2"
assert_rc "$?" 2 "JSON-UA на base64: отказ вместо пустого результата"

mk_json_tags
python3 "$PARSER" --ua "happ/3.21" <"$TMP/sub_tags.json" >"$TMP/p3.json" 2>"$TMP/e3"
assert_rc "$?" 0 "JSON: разбор прошёл"
assert_py "
import json, sys
tags = [o['tag'] for o in json.load(open(sys.argv[1]))['outbounds']]
sys.exit(0 if tags and all(t.startswith('proxy-') for t in tags) else 1)" \
    "$TMP/p3.json" "JSON: теги получили префикс proxy-"

mk_json_hole_freedom
python3 "$PARSER" --ua "happ/3.21" <"$TMP/sub_hole_freedom.json" >"$TMP/p4.json" 2>"$TMP/e4"
assert_rc "$?" 0 "hole через freedom: разбор прошёл"
assert_py "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['hole'] else 1)" \
    "$TMP/p4.json" "hole через freedom распознан"

mk_json_remarks
python3 "$PARSER" --ua "happ/3.21" --remarks nosuch <"$TMP/sub_remarks.json" >"$TMP/p5.json" 2>"$TMP/e5"
assert_rc "$?" 2 "ненайденный remarks: отказ"

mk_unified
python3 "$PARSER" --ua "happ/3.21" <"$TMP/sub_tags.json" >"$TMP/p6.json" 2>/dev/null
python3 "$GENERATOR" --output "$TMP/config.json" <"$TMP/p6.json" 2>/dev/null
assert_rc "$?" 0 "генератор: конфиг с прокси создан"
assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
sel = c['routing']['balancers'][0]['selector']
reserved = ['direct', 'block', 'dns-out']
coll = [s for s in sel for r in reserved if r.startswith(s) or s.startswith(r)]
sys.exit(0 if sel and not coll else 1)" "$TMP/config.json" "генератор: selector без коллизий со служебными тегами"

python3 "$GENERATOR" --output "$TMP/config_hole.json" <"$TMP/unified_hole.json" 2>/dev/null
assert_rc "$?" 0 "генератор: hole-конфиг создан"
assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
tags = [o['tag'] for o in c['outbounds']]
sys.exit(0 if 'balancers' not in c.get('routing', {}) and tags == ['direct', 'block', 'dns-out'] else 1)" \
    "$TMP/config_hole.json" "генератор: hole-конфиг без балансировщика"

python3 "$GENERATOR" --output "$TMP/config2.json" <"$TMP/unified.json" 2>/dev/null
assert_rc "$?" 0 "генератор: унифицированный вход"

# ------------------------------------------------------- валидация ядром

if [ -n "$XRAY_BIN" ] && [ -n "$ASSET_DIR" ]; then
    for cfg in "$TMP/config.json" "$TMP/config_hole.json"; do
        if XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -config "$cfg" >/dev/null 2>&1; then
            ok "xray run -test: $(basename "$cfg")"
        else
            fail "xray run -test: $(basename "$cfg")"
        fi
    done
else
    printf '[SKIP] xray run -test: не найден бинарь xray или geo-файлы\n'
fi

# ---------------------------------------------------------------- итог

printf '\nпройдено: %s, провалено: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
