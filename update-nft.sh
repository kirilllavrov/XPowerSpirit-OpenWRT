#!/bin/sh
# shellcheck disable=SC1090 # библиотека подключается по пути из переменной (переопределяется в тестах)
# OpenWrt — обновление nftables правил для Xray TProxy
#
# Параметры (port, метки, таблица, подсети bypass, блокировка QUIC) берутся из
# settings.json → tproxy и routing: те же значения генерирует config.json, и
# рассогласование порта или метки даёт трафик «в никуда» без ошибок в журнале.
#
# --dry-run — напечатать правила, ничего не применяя (используется в тестах).

CONF="${XRAY_CONFIG_JSON:-/etc/xray/config.json}"
SETTINGS_JSON="${XRAY_SETTINGS_JSON:-/etc/xray/settings.json}"
STATE_FILE="${XRAY_TPROXY_STATE:-/etc/xray/state/tproxy.state}"
RT_TABLES_TMP="${XRAY_RT_TABLES_TMP:-/tmp/rt_tables.xray}"
COMMON_SH="${XRAY_COMMON_SH:-/usr/share/xray/xray-common.sh}"

DRY_RUN=0
case "${1:-}" in
--dry-run) DRY_RUN=1 ;;
"") ;;
*)
    echo "Использование: $0 [--dry-run]" >&2
    exit 1
    ;;
esac

# Значения по умолчанию: скрипт вызывается из init.d на загрузке, когда
# settings.json или библиотека могут быть ещё недоступны
TPROXY_PORT=12345
TPROXY_MARK=2
TPROXY_FWMARK=1
ROUTE_TABLE=100
BLOCK_QUIC=1
BYPASS_CIDRS="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

if [ -f "$COMMON_SH" ] && [ -f "$SETTINGS_JSON" ]; then
    . "$COMMON_SH"
    TPROXY_PORT=$(settings_get_default ".tproxy.port" "$TPROXY_PORT")
    TPROXY_MARK=$(settings_get_default ".tproxy.mark" "$TPROXY_MARK")
    TPROXY_FWMARK=$(settings_get_default ".tproxy.fwmark" "$TPROXY_FWMARK")
    ROUTE_TABLE=$(settings_get_default ".tproxy.route_table" "$ROUTE_TABLE")
    BLOCK_QUIC=$(settings_get_default ".routing.block_quic" "$BLOCK_QUIC")
    _cidrs=$(settings_get ".routing.bypass_cidrs" 2>/dev/null | tr '\n' ' ')
    [ -n "$_cidrs" ] && BYPASS_CIDRS="$_cidrs"
elif [ -f "$SETTINGS_JSON" ]; then
    logger -t update-nft "нет $COMMON_SH — параметры TProxy взяты по умолчанию"
fi

# nft-набор подсетей bypass
BYPASS_SET=""
for _c in $BYPASS_CIDRS; do
    BYPASS_SET="$BYPASS_SET${BYPASS_SET:+, }$_c"
done

# Значения уходят прямо в nft/ip: нечисловое значение из подправленного вручную
# settings.json привело бы к битым правилам вместо понятной ошибки
for _v in "$TPROXY_PORT" "$TPROXY_MARK" "$TPROXY_FWMARK" "$ROUTE_TABLE"; do
    case "$_v" in
    '' | *[!0-9]*)
        echo "[X] Некорректное значение TProxy в $SETTINGS_JSON: '$_v'" >&2
        exit 1
        ;;
    esac
done

if [ "$DRY_RUN" = 1 ]; then
    NFT() { echo "nft $*"; }
    # В dry-run ничего не удаляется: `while IP rule del` должен завершиться
    # на первой итерации, иначе получится бесконечный цикл
    IP() {
        echo "ip $*"
        case "$*" in
        "rule del "*) return 1 ;;
        esac
        return 0
    }
else
    NFT() { nft "$@"; }
    IP() { ip "$@"; }
fi

# Откат при неудаче: иначе маркировка трафика роутера остаётся без TProxy-правил
# (пакет уходит в table $ROUTE_TABLE → lo и теряется), и роутер остаётся без интернета.
fail() {
    logger -t update-nft "$1"
    echo "[X] $1" >&2
    NFT delete table inet xray_self 2>/dev/null
    NFT flush chain inet fw4 xray_tproxy 2>/dev/null
    NFT delete chain inet fw4 xray_tproxy 2>/dev/null
    while IP rule del fwmark "$TPROXY_FWMARK" table "$ROUTE_TABLE" 2>/dev/null; do :; done
    IP route flush table "$ROUTE_TABLE" 2>/dev/null
    echo "[X] Правила TProxy откатены, трафик идёт напрямую" >&2
    exit 1
}

# Автоопределение LAN интерфейса
if ip link show br-lan >/dev/null 2>&1; then
    LAN_IF="br-lan"
else
    # Fallback: читаем из UCI
    LAN_IF=$(uci -q get network.lan.device || uci -q get network.lan.ifname || echo "br-lan")
    # Если UCI вернул несколько интерфейсов (bridge), берём первый
    LAN_IF="${LAN_IF%% *}"
fi

if [ "$DRY_RUN" = 0 ] && { [ -z "$LAN_IF" ] || ! ip link show "$LAN_IF" >/dev/null 2>&1; }; then
    fail "LAN-интерфейс '${LAN_IF:-<пусто>}' не существует"
fi

# Автоопределение Guest интерфейса
if ip link show br-guest >/dev/null 2>&1; then
    GUEST_IF="br-guest"
else
    GUEST_IF=$(uci -q get network.guest.device || uci -q get network.guest.ifname || echo "")
    GUEST_IF="${GUEST_IF%% *}"
fi

# Автоопределение IoT интерфейса
if ip link show br-iot >/dev/null 2>&1; then
    IOT_IF="br-iot"
else
    IOT_IF=$(uci -q get network.iot.device || uci -q get network.iot.ifname || echo "")
    IOT_IF="${IOT_IF%% *}"
fi

extract_server_ips() {
    python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    addrs = set()
    for ob in cfg.get("outbounds", []):
        for vnext in ob.get("settings", {}).get("vnext", []):
            addr = vnext.get("address")
            if isinstance(addr, str) and "." in addr and addr not in ["hole", "0.0.0.0", "127.0.0.1"]:
                addrs.add(addr)
    for a in sorted(addrs):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

# IP DNS-серверов из config.json (dns.hosts и литеральные адреса в dns.servers):
# нужны, чтобы запросы DoH уходили мимо TProxy и не зацикливались
extract_dns_ips() {
    python3 -c '
import json, sys
def is_ipv4(a):
    if not isinstance(a, str) or a.count(".") != 3:
        return False
    return all(p.isdigit() and 0 <= int(p) <= 255 for p in a.split("."))
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    dns = cfg.get("dns") or {}
    ips = set()
    for value in (dns.get("hosts") or {}).values():
        for a in (value if isinstance(value, list) else [value]):
            if is_ipv4(a):
                ips.add(a)
    for server in (dns.get("servers") or []):
        addr = server.get("address") if isinstance(server, dict) else server
        if is_ipv4(addr):
            ips.add(addr)
    for a in sorted(ips):
        print(a)
except:
    pass
' "$CONF" 2>/dev/null
}

setup_network() {
    # busybox в OpenWrt не имеет paste — собираем список вручную
    DNS_SET=$(extract_dns_ips | tr '\n' ',')
    DNS_SET=${DNS_SET%,}
    if [ -z "$DNS_SET" ]; then
        logger -t update-nft "DNS bypass list is empty — check dns.hosts/servers in config.json"
    fi

    # Правила прежней конфигурации: при смене tproxy.fwmark / tproxy.route_table
    # старые ip rule и таблица маршрутизации остались бы висеть в системе
    if [ -f "$STATE_FILE" ]; then
        _old_fwmark=""
        _old_table=""
        read -r _old_fwmark _old_table <"$STATE_FILE" 2>/dev/null || true
        if [ -n "$_old_fwmark" ] && [ -n "$_old_table" ] &&
            { [ "$_old_fwmark" != "$TPROXY_FWMARK" ] || [ "$_old_table" != "$ROUTE_TABLE" ]; }; then
            while IP rule del fwmark "$_old_fwmark" table "$_old_table" 2>/dev/null; do :; done
            IP route flush table "$_old_table" 2>/dev/null
            logger -t update-nft "сняты правила прежней конфигурации: fwmark $_old_fwmark → table $_old_table"
        fi
    fi

    # Policy routing
    while IP rule del fwmark "$TPROXY_FWMARK" table "$ROUTE_TABLE" 2>/dev/null; do :; done
    IP route flush table "$ROUTE_TABLE" 2>/dev/null
    IP rule add fwmark "$TPROXY_FWMARK" table "$ROUTE_TABLE"
    IP route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE"

    # Запоминаем применённые значения, чтобы при следующем запуске снять их,
    # если настройки поменяются
    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
        echo "$TPROXY_FWMARK $ROUTE_TABLE" >"$STATE_FILE" 2>/dev/null

        # Имя xray в rt_tables: без него `ip rule show` печатает номер таблицы
        # вместо имени, а после смены номера старое имя осталось бы висеть
        if [ -f /etc/iproute2/rt_tables ] &&
            ! grep -q "^$ROUTE_TABLE[[:space:]]\+xray$" /etc/iproute2/rt_tables 2>/dev/null; then
            grep -v '[[:space:]]xray$' /etc/iproute2/rt_tables >"$RT_TABLES_TMP" 2>/dev/null
            echo "$ROUTE_TABLE xray" >>"$RT_TABLES_TMP"
            mv "$RT_TABLES_TMP" /etc/iproute2/rt_tables
        fi
    fi

    # Создаём цепочку xray_tproxy (PREROUTING)
    if ! NFT list chain inet fw4 xray_tproxy 2>/dev/null | grep -q "chain xray_tproxy"; then
        NFT add chain inet fw4 xray_tproxy
        NFT add rule inet fw4 prerouting jump xray_tproxy
    else
        NFT flush chain inet fw4 xray_tproxy
    fi

    # Убираем устаревшую интеграцию: jump из fw4 output в xray_output.
    # Цепочка fw4 имеет type filter — mark, выставленный там, не влияет на
    # маршрутизацию, поэтому трафик роутера шёл мимо прокси.
    _h=$(NFT -a list chain inet fw4 output 2>/dev/null | grep 'jump xray_output' | sed 's/.*handle //' | head -1)
    [ -n "$_h" ] && NFT delete rule inet fw4 output handle "$_h" 2>/dev/null
    NFT flush chain inet fw4 xray_output 2>/dev/null
    NFT delete chain inet fw4 xray_output 2>/dev/null

    # ========== PREROUTING (xray_tproxy) ==========

    # Если пакет уже отмаркирован Xray (mark $TPROXY_MARK) — пропускаем (защита от петель)
    NFT add rule inet fw4 xray_tproxy meta mark "$TPROXY_MARK" return

    # Базовые bypass
    NFT add rule inet fw4 xray_tproxy ip daddr { $BYPASS_SET } return
    if [ -n "$DNS_SET" ]; then
        NFT add rule inet fw4 xray_tproxy ip daddr { $DNS_SET } return
    fi

    # DHCP — НЕ ТРОГАЕМ
    NFT add rule inet fw4 xray_tproxy udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            NFT add rule inet fw4 xray_tproxy ip daddr $ip return
        fi
    done

    # Гостевая сеть (если существует)
    if [ -n "$GUEST_IF" ] && ip link show "$GUEST_IF" >/dev/null 2>&1; then
        NFT add rule inet fw4 xray_tproxy iifname "$GUEST_IF" return
    fi

    # IoT сеть (если существует)
    if [ -n "$IOT_IF" ] && ip link show "$IOT_IF" >/dev/null 2>&1; then
        NFT add rule inet fw4 xray_tproxy iifname "$IOT_IF" return
    fi

    # Блокировка QUIC (UDP/443) — ДО TProxy, иначе пакет уйдёт в Xray до проверки.
    # Тот же переключатель (routing.block_quic) убирает правило и из config.json.
    [ "$BLOCK_QUIC" = "1" ] && NFT add rule inet fw4 xray_tproxy iifname "$LAN_IF" udp dport 443 drop

    # TProxy для LAN (сохраняем оригинальный mark 0x1 для policy routing)
    NFT add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto tcp tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_FWMARK" accept
    NFT add rule inet fw4 xray_tproxy iifname "$LAN_IF" meta l4proto udp tproxy ip to 127.0.0.1:"$TPROXY_PORT" meta mark set "$TPROXY_FWMARK" accept

    # TProxy для трафика самого роутера (перенаправлен из OUTPUT с mark 0x1 через lo)
    # Эти правила не имеют iifname — сработают для пакетов, уже отмаркированных OUTPUT chain
    NFT add rule inet fw4 xray_tproxy meta mark "$TPROXY_FWMARK" meta l4proto tcp tproxy ip to 127.0.0.1:"$TPROXY_PORT" accept
    NFT add rule inet fw4 xray_tproxy meta mark "$TPROXY_FWMARK" meta l4proto udp tproxy ip to 127.0.0.1:"$TPROXY_PORT" accept

    # ========== OUTPUT (трафик самого роутера) ==========
    # Отдельная таблица с type route hook output priority mangle — как в официальном
    # руководстве по TProxy. В цепочке fw4 (type filter) mark не влияет на
    # маршрутизацию, и трафик роутера уходил мимо прокси.
    NFT delete table inet xray_self 2>/dev/null
    NFT add table inet xray_self
    NFT "add chain inet xray_self output { type route hook output priority mangle; policy accept; }"

    # Loop prevention: пакеты с mark $TPROXY_MARK (от Xray outbound) — пропускаем
    NFT add rule inet xray_self output meta mark "$TPROXY_MARK" return

    # Базовые bypass (локальные сети)
    NFT add rule inet xray_self output ip daddr { $BYPASS_SET } return
    if [ -n "$DNS_SET" ]; then
        NFT add rule inet xray_self output ip daddr { $DNS_SET } return
    fi
    NFT add rule inet xray_self output udp dport { 67, 68 } return

    # Bypass для прокси-серверов
    for ip in $(extract_server_ips); do
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            NFT add rule inet xray_self output ip daddr $ip return
        fi
    done

    # Помечаем mark 1: правило fwmark 1 → table 100 (local default dev lo)
    # возвращает пакет в prerouting, где его ловит TProxy
    NFT add rule inet xray_self output meta l4proto tcp meta mark set "$TPROXY_FWMARK"
    NFT add rule inet xray_self output meta l4proto udp meta mark set "$TPROXY_FWMARK"

    # Проверяем, что ключевые правила реально применились: иначе init.d сочтёт
    # правила готовыми и запустит Xray без TProxy (прокси молча не работает)
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi

    _chain=$(nft list chain inet fw4 xray_tproxy 2>/dev/null)
    for _pat in "tproxy ip to 127.0.0.1:$TPROXY_PORT"; do
        if ! echo "$_chain" | grep -qF "$_pat"; then
            fail "В цепочке xray_tproxy нет правила: $_pat"
        fi
    done
    if [ "$BLOCK_QUIC" = "1" ] && ! echo "$_chain" | grep -qF "udp dport 443 drop"; then
        fail "В цепочке xray_tproxy нет правила: udp dport 443 drop"
    fi
    if ! echo "$_chain" | grep -qE "mark (0x0*$TPROXY_MARK|$TPROXY_MARK) return"; then
        fail "В цепочке xray_tproxy нет защиты от петель (mark $TPROXY_MARK return)"
    fi
    if [ -n "$DNS_SET" ]; then
        _dns_first=${DNS_SET%%,*}
        if ! echo "$_chain" | grep -qF "$_dns_first"; then
            fail "В цепочке xray_tproxy нет bypass для DNS-серверов ($_dns_first)"
        fi
    fi

    _self=$(nft list chain inet xray_self output 2>/dev/null)
    # nft печатает метку в hex с ведущими нулями: 0x00000001
    _fwmark_hex=$(printf '0x%08x' "$TPROXY_FWMARK")
    if ! echo "$_self" | grep -qF "mark set $_fwmark_hex"; then
        fail "В цепочке xray_self нет правила маркировки (mark set $TPROXY_FWMARK)"
    fi
    if ! echo "$_self" | grep -qE "type route hook output priority mangle"; then
        fail "Цепочка xray_self должна быть type route hook output priority mangle"
    fi

    logger -t update-nft "Xray TProxy rules applied"
}

setup_network