#!/usr/bin/env python3
"""
Общие данные и примитивы настроек XPowerSpirit.

Модуль существует ради одного: порт TProxy, метки и подсети bypass читает не
только генератор config.json, но и update_nft.py. Рассогласование между ними
не даёт ошибки — трафик просто уходит мимо прокси, поэтому значения и проверки
живут в одном месте.

Значения по умолчанию — не в коде, а в settings.default.json: он лежит рядом со
скриптами и из него же установщик создаёт settings.json. Если файла нет, дефолтов
нет — это ошибка с инструкцией, а не повод для второй копии чисел в коде.
"""
from __future__ import annotations

import ipaddress
import json
import os

# Путь по умолчанию; конкретный скрипт может переопределить через XRAY_SETTINGS_FILE
DEFAULT_SETTINGS_FILE = "/etc/xray/settings.json"

# Эталон настроек на устройстве: из него создаётся settings.json, из него же
# берутся значения по умолчанию. Переопределяется через XRAY_SETTINGS_DEFAULTS
DEFAULT_SETTINGS_DEFAULTS = "/usr/share/xray/settings.default.json"

# Откуда взять эталон, если файла нет
SETTINGS_DEFAULT_URL = ("https://raw.githubusercontent.com/kirilllavrov/"
                        "XPowerSpirit-OpenWRT/main/settings.default.json")


# Фактический путь настроек подставляет загрузчик: в тестах и на стенде он
# отличается от /etc/xray/settings.json, а путь должен быть в тексте ошибки
_settings_file = DEFAULT_SETTINGS_FILE


def set_settings_file(path: str) -> None:
    """Запоминает путь к settings.json для сообщений об ошибках"""
    global _settings_file
    _settings_file = path or DEFAULT_SETTINGS_FILE


def settings_file() -> str:
    return _settings_file


class SettingsError(Exception):
    """Ошибка в settings.json: текст уже содержит путь параметра"""


_defaults_file = os.environ.get("XRAY_SETTINGS_DEFAULTS") or DEFAULT_SETTINGS_DEFAULTS
_defaults_cache = None


def defaults_file() -> str:
    return _defaults_file


def set_defaults_file(path: str) -> None:
    """Переопределяет путь к эталону (тесты и стенд)"""
    global _defaults_file, _defaults_cache
    _defaults_file = path or DEFAULT_SETTINGS_DEFAULTS
    _defaults_cache = None


def load_defaults() -> dict:
    """Читает эталон настроек: единственный источник значений по умолчанию"""
    global _defaults_cache
    if _defaults_cache is not None:
        return _defaults_cache
    try:
        with open(_defaults_file, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        raise SettingsError(
            f"Не найден эталон настроек {_defaults_file} — в нём значения по умолчанию "
            f"для tproxy и routing.\n"
            f"Восстановить: curl -fsSL {SETTINGS_DEFAULT_URL} -o {_defaults_file}\n"
            f"Или обновить скрипты проекта: sh /usr/share/xray/update-scripts.sh"
        )
    except (OSError, ValueError) as error:
        raise SettingsError(f"Не удалось прочитать эталон {_defaults_file}: {error}")
    if not isinstance(data, dict):
        raise SettingsError(f"{_defaults_file}: ожидался объект JSON верхнего уровня")
    _defaults_cache = data
    return data


def defaults_section(name: str) -> dict:
    """Секция эталона; пустой объект, если секции нет"""
    section = load_defaults().get(name)
    return section if isinstance(section, dict) else {}


def tproxy_defaults() -> dict:
    """Параметры TProxy по умолчанию из эталона, проверенные по типам"""
    raw = defaults_section("tproxy")
    if not raw:
        raise SettingsError(f"В {_defaults_file} нет секции tproxy — неоткуда взять порт и метки")
    result = {}
    for key, (minimum, maximum) in (
        ("port", (1, 65535)),
        ("dns_port", (1, 65535)),
        ("mark", (1, None)),
        ("fwmark", (1, None)),
        ("route_table", (1, None)),
    ):
        if key not in raw:
            raise SettingsError(f"В {_defaults_file} → tproxy: нет ключа {key}")
        result[key] = field("int", minimum=minimum, maximum=maximum).check(
            f"tproxy.{key}", raw[key])
    return result


def bypass_cidrs_defaults() -> list:
    """Подсети bypass по умолчанию из эталона"""
    raw = defaults_section("routing").get("bypass_cidrs")
    if not raw:
        raise SettingsError(f"В {_defaults_file} → routing: нет ключа bypass_cidrs")
    return field("cidr_list").check("routing.bypass_cidrs", raw)


# Режимы установки: основной роутер или шлюз за основным роутером. Режим меняет
# только сеть и правила nftables — config.json в обоих режимах одинаковый.
MODES = ("router", "gateway")


def mode_defaults() -> str:
    """Режим установки по умолчанию (из эталона)"""
    if "mode" not in load_defaults():
        raise SettingsError(
            f"В эталоне {_defaults_file} → mode: нет ключа\n"
            f"Восстановить: curl -fsSL {SETTINGS_DEFAULT_URL} -o {_defaults_file}\n"
            f"Или обновить скрипты проекта: sh /usr/share/xray/update-scripts.sh"
        )
    return field("str", enum=MODES).check("mode", load_defaults()["mode"])


def proxy_router_traffic_default() -> bool:
    """Проксировать ли трафик самого устройства по умолчанию (из эталона)"""
    raw = defaults_section("tproxy").get("proxy_router_traffic")
    if raw is None:
        raise SettingsError(
            f"В эталоне {_defaults_file} → tproxy: нет ключа proxy_router_traffic\n"
            f"Обновите эталон: sh /usr/share/xray/update-scripts.sh"
        )
    return field("bool").check("tproxy.proxy_router_traffic", raw)


class Field:
    """
    Описание одного параметра. check() возвращает нормализованное значение или
    бросает SettingsError с путём параметра — поэтому одинаковые проверки не
    копируются по функциям загрузки.
    """

    __slots__ = ("kind", "default", "minimum", "maximum", "enum", "item")

    def __init__(self, kind: str, default=None, *, minimum=None, maximum=None,
                 enum=None, item=None):
        self.kind = kind
        self.default = default
        self.minimum = minimum
        self.maximum = maximum
        self.enum = enum
        self.item = item

    def check(self, path: str, value):
        def fail(problem: str):
            raise SettingsError(f"В {_settings_file} → {path}: {problem}")

        kind = self.kind
        if kind == "int":
            if not isinstance(value, int) or isinstance(value, bool):
                fail("ожидалось целое число")
            if self.minimum is not None and value < self.minimum:
                fail(f"значение {value} меньше допустимого {self.minimum}")
            if self.maximum is not None and value > self.maximum:
                fail(f"значение {value} больше допустимого {self.maximum}")
            return value
        if kind == "bool":
            if not isinstance(value, bool):
                fail("ожидалось true или false")
            return value
        if kind == "str":
            if not isinstance(value, str):
                fail("ожидалась строка")
            if self.enum is not None and value not in self.enum:
                raise SettingsError(
                    f"В {_settings_file} → {path}: недопустимое значение {value!r}\n"
                    f"Документированные значения: {', '.join(self.enum)}"
                )
            return value
        if kind == "str_list":
            if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                fail("ожидался массив строк")
            if self.enum is not None:
                bad = [v for v in value if v not in self.enum]
                if bad:
                    raise SettingsError(
                        f"В {_settings_file} → {path}: недопустимые значения "
                        f"{', '.join(map(str, bad))}\n"
                        f"Документированные значения: {', '.join(self.enum)}"
                    )
            return list(value)
        if kind == "cidr_list":
            if not isinstance(value, list) or not value:
                fail("ожидался непустой массив подсетей")
            result = []
            for cidr in value:
                try:
                    result.append(str(ipaddress.ip_network(str(cidr), strict=False)))
                except ValueError:
                    fail(f"не подсеть {cidr!r}")
            return result
        raise AssertionError(f"неизвестный тип поля: {kind}")


def field(kind: str, default=None, **kwargs) -> Field:
    return Field(kind, default, **kwargs)
