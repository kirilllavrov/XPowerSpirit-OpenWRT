#!/usr/bin/env python3
"""
Xray Subscription Parser

Разбирает JSON-подписку и отдаёт нормализованный список outbound'ов для
xray-generate-config.py.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import syslog

syslog.openlog("xray-parser")

TAG_PREFIX = "proxy-"

# Служебные outbound'ы подписки — не серверы. loopback возвращает трафик обратно
# в маршрутизацию (settings.inboundTag), в балансировщике ему не место.
SERVICE_PROTOCOLS = frozenset({"freedom", "blackhole", "dns", "loopback"})

# Признаки заглушки вместо сервера
PLACEHOLDER_ADDRESSES = frozenset({"0.0.0.0", "127.0.0.1", "::", "hole"})
PLACEHOLDER_PORT = 1
NULL_UUID = "00000000-0000-0000-0000-000000000000"

# Прежние имена транспортов → документированное имя поля method
NETWORK_TO_METHOD = {
    "tcp": "raw",
    "raw": "raw",
    "ws": "websocket",
    "websocket": "websocket",
    "grpc": "grpc",
    "httpupgrade": "httpupgrade",
    "xhttp": "xhttp",
    "splithttp": "xhttp",
    "mkcp": "mkcp",
    "kcp": "mkcp",
    "hysteria": "hysteria",
    "masque": "masque",
}

# Ключ настроек транспорта, который называется по имени транспорта
TRANSPORT_SETTINGS = {"raw": ("tcpSettings", "rawSettings")}


# -----------------------------
#   ВЫВОД
# -----------------------------
def log_error(msg: str) -> None:
    """Ошибка: syslog (на роутере это единственный постоянный журнал) и stderr"""
    syslog.syslog(syslog.LOG_ERR, msg)
    print(msg, file=sys.stderr)


def warn(msg: str) -> None:
    print(msg, file=sys.stderr)


# -----------------------------
#   НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def percent_decode(value: str) -> str:
    """
    Раскрывает %XX в UTF-8. Замена urllib.parse.unquote: модуль urllib в OpenWrt
    вынесен в пакет python3-urllib и в python3-light отсутствует, а тег нужен
    всегда. Знак «+» не превращается в пробел, как и в unquote (это unquote_plus).
    """
    if "%" not in value:
        return value
    raw = value.encode("utf-8", "surrogatepass")
    out = bytearray()
    i = 0
    while i < len(raw):
        if raw[i] == 0x25 and len(raw[i + 1:i + 3]) == 2:
            try:
                out.append(int(raw[i + 1:i + 3], 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(raw[i])
        i += 1
    return out.decode("utf-8", "replace")


def normalize_tag(tag: str) -> str:
    tag = percent_decode(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание (без эмодзи во избежание re.error)
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


def proxy_tag(name: str, fallback: str) -> str:
    """
    Тег outbound'а с обязательным префиксом: selector балансировщика и
    subjectSelector observatory сопоставляются по префиксу, поэтому тег вида «d»
    иначе подтянул бы служебные direct/dns-out.
    """
    base = normalize_tag(name) if name else ""
    if not base or base == "proxy":
        base = fallback
    return TAG_PREFIX + base


# -----------------------------
#   НОРМАЛИЗАЦИЯ OUTBOUND
# -----------------------------
def normalize_stream(stream: dict) -> None:
    """
    Приводит выбор транспорта к документированному виду: network → method.
    Если method уже есть, он не перезаписывается: угадывать, какой из двух
    селекторов верный, нельзя.
    """
    network = stream.pop("network", None)
    if network is not None:
        mapped = NETWORK_TO_METHOD.get(str(network))
        method = stream.get("method")
        if method:
            if mapped and mapped != method:
                warn(f"  [!] В подписке указаны и network={network!r}, и method={method!r} — "
                     f"оставлен method, как документированное поле")
        elif mapped:
            stream["method"] = mapped
        else:
            stream["network"] = network
            warn(f"  [!] Транспорт network={network!r} не имеет документированного имени "
                 f"в method — оставлен как есть")

    method = stream.get("method")
    if not method or method not in TRANSPORT_SETTINGS:
        return
    src, dst = TRANSPORT_SETTINGS[method]
    if src not in stream:
        return
    # Подписка может прислать method: "raw" вместе с tcpSettings — настройки RAW
    # ядро прочитало бы только из rawSettings и молча потеряло бы их
    if dst in stream:
        stream.pop(src)
    else:
        stream[dst] = stream.pop(src)


def normalize_reality(reality: dict) -> None:
    """
    publicKey — прежнее имя ключа REALITY, в документации поле называется password.
    Если пришли оба, побеждает password.
    """
    if "publicKey" not in reality:
        return
    legacy = reality.pop("publicKey")
    if not reality.get("password"):
        reality["password"] = legacy


def normalize_outbound(ob: dict) -> None:
    """Нормализует транспорт и REALITY на месте. sockopt и mux добавляет генератор."""
    stream = ob.get("streamSettings")
    if isinstance(stream, dict):
        normalize_stream(stream)
        reality = stream.get("realitySettings")
        if isinstance(reality, dict):
            normalize_reality(reality)


# -----------------------------
#   ПРИЗНАКИ УЗЛА
# -----------------------------
def is_hole(ob: dict) -> bool:
    """
    hole — сигнал провайдера «серверов нет» (кончилась подписка). Встречается и в
    vnext[0].address, и в settings.address для freedom-outbound.
    """
    settings = ob.get("settings")
    if not isinstance(settings, dict):
        return False
    vnext = settings.get("vnext")
    if isinstance(vnext, list) and vnext and isinstance(vnext[0], dict):
        return vnext[0].get("address") == "hole"
    return settings.get("address") == "hole"


def is_placeholder(ob: dict) -> bool:
    """Заглушка вместо сервера: нулевой адрес, порт 1, нулевой UUID"""
    settings = ob.get("settings")
    if not isinstance(settings, dict):
        return False
    vnext = settings.get("vnext")
    if not isinstance(vnext, list) or not vnext or not isinstance(vnext[0], dict):
        return False
    node = vnext[0]
    if node.get("address") in PLACEHOLDER_ADDRESSES:
        return True
    if str(node.get("port", "")) == str(PLACEHOLDER_PORT):
        return True
    users = node.get("users")
    if isinstance(users, list) and users and isinstance(users[0], dict):
        return users[0].get("id") == NULL_UUID
    return False


def is_usable_node(ob: dict) -> bool:
    """
    Проверяет обязательные поля сервера. Без них ядро отвергнет конфиг уже после
    записи, поэтому такой узел отбрасывается молча.
    """
    settings = ob.get("settings")
    if not isinstance(settings, dict):
        return True  # не vnext-подобный протокол — не наше дело
    vnext = settings.get("vnext")
    if not isinstance(vnext, list) or not vnext:
        return True
    node = vnext[0] if isinstance(vnext[0], dict) else {}
    if not str(node.get("address") or "").strip():
        return False
    try:
        port = int(node.get("port"))
    except (TypeError, ValueError):
        return False
    if not 1 <= port <= 65535:
        return False
    users = node.get("users")
    if not isinstance(users, list) or not users or not isinstance(users[0], dict):
        return False
    user = users[0]
    return bool(user.get("id") or user.get("password"))


# -----------------------------
#   ДЕДУПЛИКАЦИЯ СЕРВЕРОВ
# -----------------------------
def outbound_key(ob: dict) -> str:
    """Идентичность сервера: всё, кроме тега"""
    body = {k: v for k, v in ob.items() if k != "tag"}
    return json.dumps(body, sort_keys=True, ensure_ascii=False)


def dedup_outbounds(outbounds: list) -> list:
    """
    Убирает повторяющиеся серверы: профили подписки пересекаются, и один сервер
    приходит и в «Автовыборе», и в группе стран, и отдельной страной. Без дедупа
    балансировщик держал бы и пинговал его по нескольку раз — лишняя память на
    роутере и лишний трафик observatory.
    """
    seen = set()
    unique = []
    for ob in outbounds:
        key = outbound_key(ob)
        if key in seen:
            continue
        seen.add(key)
        unique.append(ob)

    dropped = len(outbounds) - len(unique)
    if dropped:
        warn(f"  → Удалено дубликатов серверов: {dropped}")
    return unique


# -----------------------------
#   ЗАГРУЗКА ПО URL
# -----------------------------
def try_download(data: str, user_agent: str = "", hwid: str = "") -> tuple[str, bool]:
    """
    Загружает данные по URL, если передан HTTP(S) URL.
    Возвращает (содержимое, успех).

    User-Agent обязателен для этого пути: провайдер отдаёт JSON только при
    правильном UA, иначе приходит HTML или другой формат. Штатный путь —
    готовый JSON в stdin (его скачивает установщик через curl с теми же
    заголовками), поэтому urllib обычно не нужен вовсе.
    """
    if not (data.startswith("http://") or data.startswith("https://")):
        return data, True

    if not user_agent:
        log_error("Загрузка подписки по URL требует User-Agent (--ua): без него "
                  "провайдер отдаёт не JSON. Установщик и update-xray.sh скачивают "
                  "подписку сами и передают её в stdin.")
        return "", False

    try:
        import urllib.request
    except ImportError:
        log_error("Для загрузки подписки по URL нужен пакет python3-urllib "
                  "(в python3-light модуля urllib нет). Передайте содержимое "
                  "подписки через stdin — установщик скачивает её через curl.")
        return "", False

    request = urllib.request.Request(data)
    request.add_header("User-Agent", user_agent)
    if hwid:
        # Провайдер привязывает подписку к устройству по этому заголовку
        request.add_header("x-hwid", hwid)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            content = response.read()
    except Exception as e:
        log_error(f"Failed to download subscription: {e}")
        return "", False

    lower = content.lower()
    if b"<html" in lower or b"<!doctype" in lower:
        log_error(f"Subscription returned HTML, not data: {data}")
        return "", False
    return content.decode("utf-8", errors="replace"), True


# -----------------------------
#   РАЗБОР ПОДПИСКИ
# -----------------------------
def load_profiles(raw_data: str) -> list:
    """Приводит подписку к списку профилей"""
    try:
        data = json.loads(raw_data)
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return []
    if isinstance(data, dict):
        return [data]
    if not isinstance(data, list):
        log_error("Unexpected JSON structure (expected list or dict)")
        return []
    return [p for p in data if isinstance(p, dict)]


def collect_profile(profile: dict, seen_tags: set) -> tuple[list, bool]:
    """
    Достаёт узлы одного профиля: отбрасывает hole-сигнал, служебные outbound'ы,
    заглушки и узлы без обязательных полей; нормализует транспорт и ставит тег.
    Возвращает (outbound'ы, был ли hole).
    """
    remarks = str(profile.get("remarks") or "")
    # Имя профиля в теге: на роутере единственный журнал с именами узлов — это
    # access-лог Xray, поэтому в теге должно быть видно, откуда взят сервер
    profile_slug = normalize_tag(remarks)
    if not profile_slug or profile_slug == "proxy":
        profile_slug = "profile"

    nodes = []
    hole = False
    index = 0

    for ob in profile.get("outbounds") or []:
        if not isinstance(ob, dict):
            continue
        if is_hole(ob):
            hole = True
            continue
        if str(ob.get("protocol") or "") in SERVICE_PROTOCOLS:
            continue
        if is_placeholder(ob):
            addr = ((ob.get("settings") or {}).get("vnext") or [{}])[0].get("address", "")
            warn(f"  → Пропускаем заглушку: {addr}")
            continue
        if not is_usable_node(ob):
            continue

        normalize_outbound(ob)

        index += 1
        tag = proxy_tag(f"{profile_slug}-{index}", "node")
        counter = 2
        while tag in seen_tags:
            tag = normalize_tag(f"{tag}-{counter}")
            counter += 1
        ob["tag"] = tag
        seen_tags.add(tag)
        nodes.append(ob)

    return nodes, hole


def split_filters(value: str) -> list:
    """Разбивает фильтр remarks на части: «Франция, Германия» → два фильтра.
    Несколько профилей нужны, когда провайдер раскладывает страны по отдельным
    группам: для пула стриминга одного сервера мало."""
    parts = [chunk.strip().lower() for chunk in str(value or "").split(",")]
    return [part for part in parts if part]


def parse_subscription(raw_data: str, remarks_filter: str = '',
                       fallback_all: bool = False,
                       remarks_streaming: str = '') -> dict:
    """
    Разбирает подписку и возвращает {"hole": bool, "outbounds": [...]}.

    fallback_all: если профиль по remarks не найден, разобрать все профили вместо
    отказа. Роутер обновляется без человека: конфиг с лишними серверами лучше, чем
    тихо остановившиеся обновления из-за переименования профиля у провайдера.

    remarks_streaming: второй профиль для пула игр и стриминга. В подписке
    российские входные узлы отправляют трафик дальше на европейские, поэтому
    для стриминга берётся группа стран напрямую. Профиль необязателен: нет
    группы — пул соберётся из основного профиля.
    """
    profiles = load_profiles(raw_data)
    if not profiles:
        return {"hole": False, "outbounds": []}

    if len(profiles) > 1 and not remarks_filter:
        warn(f"  [!] В подписке {len(profiles)} профилей, фильтр remarks не задан — "
             f"серверы всех профилей объединяются")

    hole = False
    nodes = []
    seen_tags = set()
    found_profile = False

    for profile in profiles:
        if remarks_filter and remarks_filter.lower() not in str(profile.get("remarks") or "").lower():
            warn(f"  → Пропускаем профиль: {profile.get('remarks', '')}")
            continue

        found_profile = True
        warn(f"  → Используем профиль: {profile.get('remarks', '')}")
        profile_nodes, profile_hole = collect_profile(profile, seen_tags)
        nodes.extend(profile_nodes)
        hole = hole or profile_hole

    if remarks_filter and not found_profile:
        warn(f"  [X] Профиль с remarks '{remarks_filter}' не найден!")
        warn("  → Доступные профили:")
        for profile in profiles:
            warn(f"      - {profile.get('remarks', '')}")
        if fallback_all:
            warn("  [!] fallback_all: берём все профили вместо отказа")
            return parse_subscription(raw_data, '', False)

    result = {"hole": hole, "outbounds": dedup_outbounds(nodes)}

    # Отдельный профиль для пула игр и стриминга. Теги узлов уже содержат имя
    # профиля (proxy_tag), поэтому две группы в одном конфиге не конфликтуют.
    # Фильтров может быть несколько через запятую: у провайдера страны бывают
    # разложены по отдельным профилям, а пулу нужен не один сервер
    filters = split_filters(remarks_streaming)
    if filters:
        matched = [p for p in profiles
                   if any(f in str(p.get("remarks") or "").lower() for f in filters)]
        if not matched:
            warn(f"  [!] Профили стриминга '{', '.join(filters)}' не найдены — "
                 f"пул соберётся из основного профиля")
        else:
            stream_nodes = []
            for profile in matched:
                profile_nodes, _ = collect_profile(profile, seen_tags)
                stream_nodes.extend(profile_nodes)
                warn(f"  → Пул стриминга: {profile.get('remarks', '')} "
                     f"({len(profile_nodes)} прокси)")
            stream_nodes = dedup_outbounds(stream_nodes)
            names = ", ".join(str(p.get("remarks", "")) for p in matched)
            if stream_nodes:
                result["streaming"] = {"remarks": names, "outbounds": stream_nodes}

    return result


# -----------------------------
#   CLI
# -----------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Xray subscription parser (unified)")
    parser.add_argument('--ua', default='',
                        help='User-Agent подписки: обязателен при загрузке по URL, '
                             'без него провайдер отдаёт не JSON')
    parser.add_argument('--hwid', default='',
                        help='Отпечаток устройства (заголовок x-hwid) для загрузки по URL')
    parser.add_argument('--remarks', default='', help='Фильтр профилей по remarks (подстрока)')
    parser.add_argument('--remarks-streaming', default='',
                        help='Профили для пула игр и стриминга (подстроки remarks '
                             'через запятую). Пусто — пул берётся из основного профиля')
    parser.add_argument('--fallback-all', action='store_true',
                        help='Если профиль не найден — разобрать все профили вместо отказа')
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        log_error("Empty input")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    data, ok = try_download(raw, args.ua, args.hwid)
    if not ok or not data:
        log_error("Failed to download subscription")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    warn("  → Разбор JSON-подписки")
    result = parse_subscription(data, args.remarks, args.fallback_all,
                                args.remarks_streaming)
    print(json.dumps(result, indent=2, ensure_ascii=False))

    # hole — осознанный сигнал провайдера (DIRECT), пустой результат без hole —
    # сбой: профиль не найден или все серверы оказались заглушками. Вызывающая
    # сторона в этом случае оставляет прежний config.json
    if not result["hole"] and not result["outbounds"]:
        log_error("No outbounds parsed and no hole signal — refusing to emit empty result")
        sys.exit(2)


if __name__ == "__main__":
    main()
