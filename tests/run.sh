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

# Правила роутинга живут только в settings.json — тесты берут эталон из репозитория
XRAY_SETTINGS_FILE="$TMP/settings.json"
cp "$ROOT/settings.default.json" "$XRAY_SETTINGS_FILE"
export XRAY_SETTINGS_FILE

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

# Категория проверки IP: правило есть всегда, категория живёт в геофайле
python3 "$GENERATOR" --output "$TMP/config_ipcheck.json" <"$TMP/unified.json" 2>/dev/null
assert_py "
import json, sys
rules = json.load(open(sys.argv[1]))['routing']['rules']
idx = next((i for i, r in enumerate(rules)
            if any('category-ipcheck' in d for d in r.get('domain', []))), None)
if idx is None:
    sys.exit(1)
# Правила с inboundTag видят только DNS-запросы встроенного резолвера
# и не могут перехватить обычный трафик к сервисам проверки IP.
if any((r.get('outboundTag') == 'block' or 'balancerTag' in r)
       and 'inboundTag' not in r for r in rules[:idx]):
    sys.exit(1)
sys.exit(0 if rules[idx]['outboundTag'] == 'direct' else 1)" \
    "$TMP/config_ipcheck.json" "генератор: geosite:category-ipcheck → direct раньше block/balancer"

# Категория проверки IP должна работать в ОБОИХ режимах: в bs-профиле
# direct_domains не используется, поэтому правило вынесено отдельно
mkdir -p "$TMP/asset2"
python3 - "$TMP/asset2" <<'PY2'
import sys, pathlib

def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | 0x80]) if n else bytes([b])
        if not n:
            return out

def ld(f, p):
    return varint((f << 3) | 2) + varint(len(p)) + p

def en(f, v):
    return varint((f << 3) | 0) + varint(v)

def entry(code, payloads):
    return ld(1, ld(1, code.encode()) + b"".join(ld(2, x) for x in payloads) + ld(4, code.encode()))

d = pathlib.Path(sys.argv[1])
site = lambda v: en(1, 2) + ld(2, v.encode())
cats = {
    "CATEGORY-IPCHECK": ["ifconfig.me"], "CATEGORY-ADS": ["ads.example"],
    "PRIVATE": ["localhost"], "CATEGORY-BROWSER": ["b.example"],
    "CATEGORY-CDN-RU": ["c.example"], "CATEGORY-MOBILE": ["m.example"],
    "CATEGORY-RU": ["r.example"], "CATEGORY-STREAMING": ["s.example"],
    "CATEGORY-GAMES": ["g.example"], "CATEGORY-WHITELIST": ["gosuslugi.ru"],
}
(d / "geosite.dat").write_bytes(b"".join(entry(c, [site(v) for v in vals]) for c, vals in cats.items()))
# коды в geoip.dat тоже в верхнем регистре
net = lambda a, m: ld(1, a.encode()) + en(2, m)
(d / "geoip.dat").write_bytes(
    entry("WHITELIST", [net("5.255.255.0", 24)]) + entry("RU", [net("5.0.0.0", 8)])
    + entry("PRIVATE", [net("10.0.0.0", 8)]))
PY2

for mode in normal bs; do
    XRAY_LOCATION_ASSET="$TMP/asset2" python3 "$GENERATOR" --mode "$mode" \
        --output "$TMP/config_$mode.json" <"$TMP/unified.json" 2>/dev/null
    assert_rc "$?" 0 "генератор: режим $mode собирается (категории в геофайлах найдены)"
    assert_py "
import json, sys
rules = json.load(open(sys.argv[1]))['routing']['rules']
sys.exit(0 if any('geosite:category-ipcheck' in d
                  for r in rules for d in r.get('domain', [])) else 1)" \
        "$TMP/config_$mode.json" "генератор: в режиме $mode ipcheck → direct"
done

# Без routing в settings.json генератор обязан отказаться, а не собрать конфиг без правил
jq 'del(.routing)' "$TMP/settings.json" >"$TMP/settings_norouting.json"
XRAY_SETTINGS_FILE="$TMP/settings_norouting.json" python3 "$GENERATOR" \
    --output "$TMP/cfg_norouting.json" <"$TMP/unified.json" >/dev/null 2>&1
assert_rc "$?" 1 "генератор: без routing в settings.json — отказ (код 1)"

jq 'del(.routing.direct_ips)' "$TMP/settings.json" >"$TMP/settings_partial.json"
XRAY_SETTINGS_FILE="$TMP/settings_partial.json" python3 "$GENERATOR" \
    --output "$TMP/cfg_partial.json" <"$TMP/unified.json" >/dev/null 2>&1
assert_rc "$?" 1 "генератор: нет обязательного ключа direct_ips — отказ (код 1)"

# -------------------------------------------- режимы normal / bs (белые списки)

python3 "$GENERATOR" --mode normal --output "$TMP/cfg_normal.json" <"$TMP/unified.json" 2>/dev/null
assert_rc "$?" 0 "normal: профиль собран"

assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
b = {x['tag']: x['fallbackTag'] for x in c['routing']['balancers']}
domains = [d for r in c['routing']['rules'] for d in (r.get('domain') or [])]
sys.exit(0 if b.get('balancer') == 'direct' and b.get('balancer-dns') == 'direct'
         and 'geosite:category-whitelist' not in domains else 1)" \
    "$TMP/cfg_normal.json" "normal: без БС-правил, fallback балансировщика direct"

# Без категорий в геофайлах bs-профиль собирать нельзя — отказ с кодом 3.
# Каталог ресурсов задаём пустой: иначе тест зависит от геофайлов на машине.
mkdir -p "$TMP/asset-none"
XRAY_LOCATION_ASSET="$TMP/asset-none" python3 "$GENERATOR" --mode bs \
    --output "$TMP/cfg_bs_none.json" <"$TMP/unified.json" 2>"$TMP/e_bs"
assert_rc "$?" 3 "bs: отказ, если категорий БС нет в геофайлах"

# Фальшивые геофайлы с нужными категориями
mkdir -p "$TMP/assets"
printf 'CATEGORY-WHITELIST CATEGORY-ADS CATEGORY-IPCHECK geolocation-!cn' >"$TMP/assets/geosite.dat"
printf 'whitelist ru private cn ir' >"$TMP/assets/geoip.dat"

# bs-профиль собирается только из узлов bypass-*: остальные в БС бесполезны
cat >"$TMP/bypass.json" <<'JSON'
{"hole": false, "outbounds": [
  {"tag": "proxy-AUTO", "protocol": "vless",
   "settings": {"vnext": [{"address": "auto.example.com", "port": 443,
                           "users": [{"id": "11111111-1111-1111-1111-111111111111", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "auto.example.com"}}},
  {"tag": "proxy-bypass-1", "protocol": "vless",
   "settings": {"vnext": [{"address": "b1.example.com", "port": 443,
                           "users": [{"id": "22222222-2222-2222-2222-222222222222", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "reality",
                      "realitySettings": {"serverName": "www.vk.com", "password": "k", "shortId": "ab", "fingerprint": "chrome"}}},
  {"tag": "proxy-bypass-2", "protocol": "vless",
   "settings": {"vnext": [{"address": "b2.example.com", "port": 443,
                           "users": [{"id": "33333333-3333-3333-3333-333333333333", "encryption": "none"}]}]},
   "streamSettings": {"network": "tcp", "security": "reality",
                      "realitySettings": {"serverName": "yandex.ru", "password": "k", "shortId": "ab", "fingerprint": "chrome"}}}
]}
JSON

XRAY_LOCATION_ASSET="$TMP/assets" python3 "$GENERATOR" --mode bs --output "$TMP/cfg_bs.json" \
    <"$TMP/bypass.json" 2>/dev/null
assert_rc "$?" 0 "bs: профиль собран при наличии категорий"

assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
tags = [o['tag'] for o in c['outbounds'] if o.get('protocol') == 'vless']
sys.exit(0 if tags == ['proxy-bypass-1', 'proxy-bypass-2'] else 1)" \
    "$TMP/cfg_bs.json" "bs: в профиль попадают только узлы bypass-*"

assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
b = {x['tag']: x['fallbackTag'] for x in c['routing']['balancers']}
rules = c['routing']['rules']
bs_dom = [i for i, r in enumerate(rules)
          if r.get('domain') == ['geosite:category-whitelist'] and r.get('outboundTag') == 'direct']
bs_ip = [i for i, r in enumerate(rules)
         if r.get('ip') == ['geoip:whitelist'] and r.get('outboundTag') == 'direct']
catch = rules[-1]
sys.exit(0 if b.get('balancer') == 'block' and b.get('balancer-dns') == 'direct'
         and bs_dom and bs_ip and catch.get('balancerTag') == 'balancer'
         and bs_dom[0] < len(rules) - 1 else 1)" \
    "$TMP/cfg_bs.json" "bs: БС-домены и адреса -> direct, остальное -> balancer"

assert_py "
import json, sys
rules = json.load(open(sys.argv[1]))['routing']['rules']
dns_rule = [i for i, r in enumerate(rules) if r.get('inboundTag') == ['dns-inbuilt']]
first_domain = min(i for i, r in enumerate(rules) if 'domain' in r)
sys.exit(0 if dns_rule and dns_rule[0] < first_domain else 1)" \
    "$TMP/cfg_bs.json" "bs: правило dns-inbuilt раньше domain-правил"

assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
s = c['dns']['servers']
sys.exit(0 if len(s) == 3
         and s[0]['address'].startswith('https+local://')
         and s[0].get('domains') == ['geosite:category-whitelist']
         and 'expectedIPs' not in s[0]
         and s[1]['address'].startswith('https://')
         and c['dns']['disableFallbackIfMatch'] is False else 1)" \
    "$TMP/cfg_bs.json" "bs: DNS БС-доменов напрямую, остального — через прокси"

# Отбор пробой: генератор берёт только теги из bs-nodes.json
printf '{"selected":[{"tag":"proxy-bypass-2"}]}' >"$TMP/nodes.json"
XRAY_LOCATION_ASSET="$TMP/assets" python3 "$GENERATOR" --mode bs --nodes "$TMP/nodes.json" \
    --output "$TMP/cfg_bs_sel.json" <"$TMP/bypass.json" 2>/dev/null
assert_rc "$?" 0 "bs: профиль с --nodes собран"
assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
tags = [o['tag'] for o in c['outbounds'] if o.get('protocol') == 'vless']
sys.exit(0 if tags == ['proxy-bypass-2'] else 1)" \
    "$TMP/cfg_bs_sel.json" "bs: --nodes ограничивает набор узлов"

# Нет bypass-узлов — профиль собирается без прокси и без балансировщика
XRAY_LOCATION_ASSET="$TMP/assets" python3 "$GENERATOR" --mode bs \
    --output "$TMP/cfg_bs_noproxy.json" <"$TMP/unified.json" 2>/dev/null
assert_rc "$?" 0 "bs: без bypass-узлов профиль собирается"
assert_py "
import json, sys
c = json.load(open(sys.argv[1]))
rules = c['routing']['rules']
sys.exit(0 if not c['routing'].get('balancers')
         and rules[-1].get('outboundTag') == 'block'
         and any(r.get('domain') == ['geosite:category-whitelist'] for r in rules) else 1)" \
    "$TMP/cfg_bs_noproxy.json" "bs: без bypass-узлов не-БС трафик блокируется"

# ------------------------------------------------------------- bs-probe.py

PROBE="$ROOT/bs-probe.py"
mkdir -p "$TMP/www"
echo ok >"$TMP/www/index.html"
cat >"$TMP/probe_settings.json" <<'JSON'
{"bs":{"probe_external":[{"host":"127.0.0.1","port":18080,"path":"/","tls":false}],
       "probe_bs":[{"host":"127.0.0.1","port":18081,"path":"/","tls":false}]}}
JSON

run_probe() {
    BS_PROBE_SETTINGS="$TMP/probe_settings.json" python3 "$PROBE" --no-mark --timeout 1 "$@" >/dev/null 2>&1
}

python3 -m http.server 18080 --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
SRV=$!
sleep 1
run_probe
assert_rc "$?" 0 "bs-probe: внешняя проба прошла -> normal"
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

python3 -m http.server 18081 --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
SRV=$!
sleep 1
run_probe
assert_rc "$?" 1 "bs-probe: внешняя недоступна, БС доступна -> bs"
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

run_probe
assert_rc "$?" 2 "bs-probe: ничего не доступно -> unknown"

# Отбор bypass-узлов и журнал рабочих серверов
cat >"$TMP/nodes_src.json" <<'JSON'
{"outbounds": [
  {"tag": "proxy-bypass-live", "protocol": "vless",
   "settings": {"vnext": [{"address": "127.0.0.1", "port": 18082,
                           "users": [{"id": "x", "encryption": "none"}]}]},
   "streamSettings": {"security": "none"}},
  {"tag": "proxy-bypass-dead", "protocol": "vless",
   "settings": {"vnext": [{"address": "127.0.0.1", "port": 18083,
                           "users": [{"id": "x", "encryption": "none"}]}]},
   "streamSettings": {"security": "none"}},
  {"tag": "proxy-AUTO", "protocol": "vless",
   "settings": {"vnext": [{"address": "127.0.0.1", "port": 18082,
                           "users": [{"id": "x", "encryption": "none"}]}]},
   "streamSettings": {"security": "none"}}
]}
JSON

python3 -m http.server 18082 --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
SRV=$!
sleep 1
python3 "$PROBE" --select-nodes --no-mark --from "$TMP/nodes_src.json" \
    --out "$TMP/bs-nodes.json" --ledger "$TMP/bs-good.json" --want 1 \
    --timeout 1 --workers 2 --network test >/dev/null 2>&1
assert_rc "$?" 0 "bs-probe: найден рабочий bypass-узел"
kill "$SRV" 2>/dev/null
wait "$SRV" 2>/dev/null

assert_py "
import json, sys
d = json.load(open(sys.argv[1]))
sel = [x['tag'] for x in d['selected']]
sys.exit(0 if sel == ['proxy-bypass-live'] else 1)" \
    "$TMP/bs-nodes.json" "bs-probe: в selected только рабочий узел (AUTO отфильтрован)"

assert_py "
import json, sys
d = json.load(open(sys.argv[1]))
nodes = (d['networks'].get('test') or {}).get('nodes', [])
sys.exit(0 if nodes and nodes[0]['key'].startswith('127.0.0.1:18082|') else 1)" \
    "$TMP/bs-good.json" "bs-probe: рабочий узел записан в журнал по endpoint+SNI"

# ------------------------------------------------- определение архитектуры

# Функция живёт внутри установщика — извлекаем её для проверки
sed -n '/^# Определение суффикса релизного ZIP/,/^# Парсер аргументов/p' \
    "$ROOT/install-openwrt-xray.sh" >"$TMP/arch_fn.sh"

check_arch() { # ожидаемое  DISTRIB_ARCH
    printf "DISTRIB_ARCH='%s'\n" "$2" >"$TMP/fake_release"
    got=$(XRAY_RELEASE_FILE="$TMP/fake_release" sh -c '. "$1"; detect_xray_machine' _ "$TMP/arch_fn.sh")
    if [ "$got" = "$1" ]; then
        ok "архитектура $2 → $got"
    else
        fail "архитектура $2: ожидалось '$1', получено '$got'"
    fi
}

check_arch arm64-v8a  aarch64_cortex-a53
check_arch arm32-v7a  arm_cortex-a7_neon-vfpv4
check_arch arm32-v7a  arm_cortex-a15_neon-vfpv4
check_arch arm32-v6   arm_arm1176jzf-s_vfp
check_arch arm32-v5   arm_xscale
check_arch mips32     mips_24kc
check_arch mips32le   mipsel_24kc
check_arch mips64     mips64_octeonplus
check_arch mips64le   mips64el_mips64r2
check_arch riscv64    riscv64_riscv64
check_arch loong64    loongarch64_generic
check_arch 64         x86_64
check_arch 32         i386

# Неизвестная архитектура не должна молча превращаться в x86-64
printf "DISTRIB_ARCH='sparc_v9'\n" >"$TMP/fake_release"
got=$(XRAY_RELEASE_FILE="$TMP/fake_release" sh -c '. "$1"; detect_xray_machine' _ "$TMP/arch_fn.sh")
if [ -z "$got" ]; then
    ok "неизвестная архитектура даёт пустой результат (установщик падает, а не ставит x86-64)"
else
    fail "неизвестная архитектура вернула '$got' вместо пустого значения"
fi

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
