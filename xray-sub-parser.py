#!/usr/bin/env python3
"""
Xray Subscription Parser

Подписка приходит только в JSON (Happ/Sing-box/Karing/XPower): список профилей
с remarks и outbounds.

Вход: JSON подписки в stdin (или HTTP(S) URL — тогда скачивается сам).
Выход: {"hole": bool, "outbounds": [...]}.

--ua обязателен: с ним подписка запрашивается у провайдера. На разбор формата
User-Agent больше не влияет — формат всегда JSON.
"""
from __future__ import annotations

import sys
import json
import urllib.parse as urlparse
import urllib.request
import re
import argparse
import syslog

syslog.openlog("xray-parser")


# -----------------------------
# ЛОГИРОВАНИЕ ОШИБОК
# -----------------------------
def log_error(msg: str) -> None:
    """Отправляет сообщение об ошибке в syslog и в stderr"""
    syslog.syslog(syslog.LOG_ERR, msg)
    print(msg, file=sys.stderr)


# -----------------------------
# НОРМАЛИЗАЦИЯ ТЕГОВ
# -----------------------------
def normalize_tag(tag: str) -> str:
    tag = urlparse.unquote(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание (без эмодзи во избежание re.error)
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


# selector балансировщика и subjectSelector observatory сопоставляются с тегами
# по префиксу, поэтому теги прокси получают собственный префикс и не могут
# случайно захватить служебные outbound (direct/block/dns-out)
TAG_PREFIX = "proxy-"


def proxy_tag(name: str, fallback: str) -> str:
    """Тег outbound-а из подписки с гарантированным префиксом"""
    base = normalize_tag(name) if name else ""
    if not base or base == "proxy":
        base = fallback
    return TAG_PREFIX + base


# -----------------------------
# ДЕДУПЛИКАЦИЯ СЕРВЕРОВ
# -----------------------------
def outbound_key(ob: dict) -> str:
    """Идентичность сервера: адрес, порт, пользователь, транспорт — без учёта тега"""
    body = {k: v for k, v in ob.items() if k != "tag"}
    return json.dumps(body, sort_keys=True, ensure_ascii=False)


def dedup_outbounds(outbounds: list) -> list:
    """
    Убирает повторяющиеся серверы. Профили подписки пересекаются: один и тот же
    сервер приходит в «Автовыборе», в группе стран и в отдельной стране. Без
    дедупликации балансировщик держит и пингует каждый такой сервер по нескольку
    раз — лишняя память на роутере и лишний трафик observatory.
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
        print(f"  → Удалено дубликатов серверов: {dropped}", file=sys.stderr)
    return unique


# -----------------------------
# ЗАГРУЗКА URL
# -----------------------------
def try_download(data: str) -> tuple[str, bool]:
    """
    Загружает данные по URL, если передан HTTP/HTTPS URL.
    Возвращает (содержимое, успех).
    """
    if not (data.startswith("http://") or data.startswith("https://")):
        return data, True

    try:
        with urllib.request.urlopen(data, timeout=10) as r:
            content = r.read()

            # Проверяем, что это не HTML ошибка
            content_lower = content.lower()
            if b"<html" in content_lower or b"<!doctype" in content_lower:
                log_error(f"Subscription returned HTML, not data: {data}")
                return "", False

            return content.decode("utf-8", errors="replace"), True
    except Exception as e:
        log_error(f"Failed to download subscription: {e}")
        return "", False


# ============================================
#   РАЗБОР ПОДПИСКИ (JSON)
# ============================================

def is_hole(ob: dict) -> bool:
    """Проверяет, является ли outbound сигналом hole (окончание подписки)"""
    try:
        settings = ob.get("settings") or {}
        vnext = settings.get("vnext") or []
        if vnext:
            return vnext[0].get("address", "") == "hole"
        # Встречается и форма {"protocol": "freedom", "settings": {"address": "hole"}}
        return settings.get("address", "") == "hole"
    except Exception:
        return False


def is_placeholder(ob: dict) -> bool:
    """
    Проверяет, является ли outbound заглушкой.
    Критерии: address=0.0.0.0/127.0.0.1/hole, port=1, UUID=000...
    """
    try:
        vnext = ob.get("settings", {}).get("vnext", [{}])[0]
        addr = vnext.get("address", "")
        if addr in ("0.0.0.0", "127.0.0.1", "hole"):
            return True
        if str(vnext.get("port", 0)) == "1":
            return True
        uid = vnext.get("users", [{}])[0].get("id", "")
        if uid == "00000000-0000-0000-0000-000000000000":
            return True
    except Exception:
        pass
    return False


def parse_json_subscription(raw_data: str, remarks_filter: str = '') -> dict:
    """
    Парсит JSON-подписку (Happ/Sing-box/XPower формат).
    Возвращает {"hole": bool, "outbounds": [сырые outbounds из подписки]}.
    """
    try:
        data = json.loads(raw_data)
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return {"hole": False, "outbounds": []}

    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        log_error("Unexpected JSON structure (expected list or dict)")
        return {"hole": False, "outbounds": []}

    if len(data) > 1 and not remarks_filter:
        print(f"  [!] В подписке {len(data)} профилей, фильтр remarks не задан — "
              f"серверы всех профилей объединяются", file=sys.stderr)

    # Один проход: hole, фильтрация, извлечение
    hole = False
    all_outbounds = []
    seen_tags = set()
    found_profile = False

    for config in data:
        config_remarks = config.get("remarks", "")

        if remarks_filter:
            if remarks_filter.lower() not in config_remarks.lower():
                print(f"  → Пропускаем профиль: {config_remarks}", file=sys.stderr)
                continue

        found_profile = True
        print(f"  → Используем профиль: {config_remarks}", file=sys.stderr)

        for ob in config.get("outbounds", []):
            # Проверка hole (сигнал окончания подписки)
            if is_hole(ob):
                hole = True
                continue

            # Пропускаем служебные outbounds
            protocol = ob.get("protocol", "")
            # loopback — не сервер, а внутренняя петля: его settings.inboundTag
            # возвращает трафик в маршрутизацию, в балансировщике ему не место
            if protocol in ("freedom", "blackhole", "dns", "loopback"):
                continue

            # Пропускаем заглушки (невалидные серверы)
            if is_placeholder(ob):
                try:
                    addr = ob.get("settings", {}).get("vnext", [{}])[0].get("address", "")
                    print(f"  → Пропускаем заглушку: {addr}", file=sys.stderr)
                except Exception:
                    pass
                continue

            # Нормализуем тег
            tag = proxy_tag(ob.get("tag", ""), "node")
            counter = 2
            base_tag = tag
            while tag in seen_tags:
                tag = normalize_tag(f"{base_tag}-{counter}")
                counter += 1
            ob["tag"] = tag
            seen_tags.add(tag)

            all_outbounds.append(ob)

    if remarks_filter and not found_profile:
        print(f"  [X] Профиль с remarks '{remarks_filter}' не найден!", file=sys.stderr)
        print(f"  → Доступные профили:", file=sys.stderr)
        for config in data:
            print(f"      - {config.get('remarks', '')}", file=sys.stderr)

    return {"hole": hole, "outbounds": dedup_outbounds(all_outbounds)}


def unified_main():
    """
    Читает подписку, разбирает JSON и выводит {"hole": bool, "outbounds": [...]}.
    """
    parser = argparse.ArgumentParser(description='Xray subscription parser (unified)')
    parser.add_argument('--ua', required=True, help='User-Agent for subscription request (format is always JSON)')
    parser.add_argument('--remarks', default='', help='Filter profiles by remarks substring')
    args = parser.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        log_error("Empty input")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    # Загружаем по URL, если нужно
    data, success = try_download(raw)
    if not success or not data:
        log_error("Failed to download subscription")
        print(json.dumps({"hole": False, "outbounds": []}))
        sys.exit(1)

    print("  → Разбор JSON-подписки", file=sys.stderr)
    result = parse_json_subscription(data, args.remarks)

    print(json.dumps(result, indent=2, ensure_ascii=False))

    # hole — осознанный сигнал провайдера (DIRECT), пустой результат без hole — сбой:
    # не найден профиль по remarks или все серверы оказались заглушками.
    if not result["hole"] and not result["outbounds"]:
        log_error("No outbounds parsed and no hole signal — refusing to emit empty result")
        sys.exit(2)


if __name__ == "__main__":
    unified_main()
