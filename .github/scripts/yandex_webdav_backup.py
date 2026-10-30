#!/usr/bin/env python3
"""Односторонняя выгрузка архива на Яндекс Диск по WebDAV.

Направление только GitHub -> Яндекс Диск: скрипт создаёт каталоги (MKCOL),
загружает файл (PUT), проверяет размер (PROPFIND) и удаляет старые архивы (DELETE).
Скачивания и обратной синхронизации нет.

Зависимостей нет — только стандартная библиотека, поэтому в workflow не нужен pip.
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

DAV_NS = "{DAV:}"
DEFAULT_BASE_URL = "https://webdav.yandex.ru"
PROPFIND_BODY = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    "<d:resourcetype/><d:getcontentlength/>"
    "</d:prop></d:propfind>"
).encode("utf-8")


class DavError(RuntimeError):
    """Ошибка обращения к WebDAV."""


class YandexWebDav:
    def __init__(self, base_url: str, user: str, password: str, timeout: int = 300, attempts: int = 4):
        self.base_url = base_url.rstrip("/")
        token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
        self.auth = f"Basic {token}"
        self.timeout = timeout
        self.attempts = attempts

    def _url(self, remote_path: str) -> str:
        segments = [urllib.parse.quote(part, safe="") for part in remote_path.strip("/").split("/") if part]
        return self.base_url + "/" + "/".join(segments)

    def _attempt(self, method: str, remote_path: str, data, headers):
        payload = data() if callable(data) else data
        request = urllib.request.Request(self._url(remote_path), data=payload, method=method)
        request.add_header("Authorization", self.auth)
        request.add_header("User-Agent", "github-yandex-webdav-backup/1.0")
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
        finally:
            if callable(data) and hasattr(payload, "close"):
                payload.close()

    def _call(self, method: str, remote_path: str, data=None, headers=None, ok=(200,)):
        ok = tuple(ok)
        last = ""
        for attempt in range(1, self.attempts + 1):
            try:
                status, body = self._attempt(method, remote_path, data, headers)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last = f"{method} {remote_path}: сеть недоступна ({error})"
                if attempt == self.attempts:
                    raise DavError(last) from error
                time.sleep(2 ** attempt)
                continue

            if status in ok:
                return status, body

            detail = body[:400].decode("utf-8", "replace").strip()
            last = f"{method} {remote_path}: HTTP {status} {detail}"
            if status in (401, 403):
                raise DavError(
                    last
                    + "\nПроверьте YANDEX_WEBDAV_USER и YANDEX_WEBDAV_PASSWORD:"
                    " нужен пароль приложения Яндекс ID или OAuth-токен, а не основной пароль."
                )
            if status == 507:
                raise DavError(last + "\nНа Яндекс Диске не хватает места.")
            if status < 500 and status != 429:
                raise DavError(last)
            if attempt == self.attempts:
                raise DavError(last)
            time.sleep(2 ** attempt)
        raise DavError(last or f"{method} {remote_path}: неизвестная ошибка")

    def ensure_dir(self, remote_dir: str) -> None:
        current = ""
        for segment in [part for part in remote_dir.strip("/").split("/") if part]:
            current = f"{current}/{segment}"
            self._call("MKCOL", current, ok=(200, 201, 204, 405))

    def put_file(self, remote_path: str, local_path: str) -> int:
        size = os.path.getsize(local_path)
        headers = {"Content-Length": str(size), "Content-Type": "application/octet-stream"}
        self._call("PUT", remote_path, data=lambda: open(local_path, "rb"), headers=headers, ok=(200, 201, 202, 204))
        return size

    def _parse_propfind(self, body: bytes):
        entries = []
        for node in ET.fromstring(body).findall(f"{DAV_NS}response"):
            href = node.findtext(f"{DAV_NS}href") or ""
            name = urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1])
            prop = node.find(f"{DAV_NS}propstat/{DAV_NS}prop")
            resource_type = prop.find(f"{DAV_NS}resourcetype") if prop is not None else None
            is_dir = resource_type is not None and resource_type.find(f"{DAV_NS}collection") is not None
            length = node.findtext(f"{DAV_NS}propstat/{DAV_NS}prop/{DAV_NS}getcontentlength")
            entries.append(
                {"name": name, "is_dir": is_dir, "size": int(length) if length and length.isdigit() else None}
            )
        return entries

    def list_dir(self, remote_dir: str):
        headers = {"Depth": "1", "Content-Type": "application/xml; charset=utf-8"}
        _, body = self._call("PROPFIND", remote_dir, data=PROPFIND_BODY, headers=headers, ok=(207,))
        return [entry for entry in self._parse_propfind(body) if not entry["is_dir"]]

    def stat_size(self, remote_path: str):
        headers = {"Depth": "0", "Content-Type": "application/xml; charset=utf-8"}
        _, body = self._call("PROPFIND", remote_path, data=PROPFIND_BODY, headers=headers, ok=(207,))
        entries = self._parse_propfind(body)
        return entries[0]["size"] if entries else None

    def verify_size(self, remote_path: str, expected: int, attempts: int = 6, delay: int = 2) -> None:
        for attempt in range(1, attempts + 1):
            size = self.stat_size(remote_path)
            if size == expected:
                return
            if attempt == attempts:
                raise DavError(f"{remote_path}: размер на Диске {size} не совпадает с локальным {expected}")
            time.sleep(delay)

    def delete(self, remote_path: str) -> None:
        self._call("DELETE", remote_path, ok=(200, 202, 204, 404))


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Выгрузка архива на Яндекс Диск по WebDAV (одно направление).")
    parser.add_argument("--file", required=True, help="локальный файл архива")
    parser.add_argument("--remote-dir", required=True, help="каталог на Диске, например /GitHubBackup/repo")
    parser.add_argument("--keep", type=int, default=14, help="сколько последних архивов оставить (0 — не удалять)")
    parser.add_argument(
        "--retention-prefix",
        default="",
        help="учитывать при ротации только файлы с этим префиксом имени",
    )
    parser.add_argument(
        "--latest-name",
        default="latest.zip",
        help="дополнительная копия с фиксированным именем (пустая строка — не создавать)",
    )
    parser.add_argument("--dry-run", action="store_true", help="только показать план, без обращения к Диску")
    parser.add_argument("--base-url", default=os.environ.get("YANDEX_WEBDAV_URL") or DEFAULT_BASE_URL)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    local_path = os.path.abspath(args.file)
    if not os.path.isfile(local_path):
        print(f"файл не найден: {local_path}", file=sys.stderr)
        return 1

    remote_dir = "/" + args.remote_dir.strip("/")
    remote_path = f"{remote_dir}/{os.path.basename(local_path)}"
    size = os.path.getsize(local_path)

    if args.dry_run:
        print(f"[dry-run] выгрузил бы {local_path} ({size} байт) в {remote_path}")
        if args.latest_name:
            print(f"[dry-run] и копию {remote_dir}/{args.latest_name}")
        print(f"[dry-run] оставил бы {args.keep} последних архивов в {remote_dir}")
        return 0

    user = os.environ.get("YANDEX_WEBDAV_USER", "")
    password = os.environ.get("YANDEX_WEBDAV_PASSWORD", "")
    if not user or not password:
        print("не заданы YANDEX_WEBDAV_USER / YANDEX_WEBDAV_PASSWORD", file=sys.stderr)
        return 1

    dav = YandexWebDav(args.base_url, user, password)

    dav.ensure_dir(remote_dir)
    uploaded = dav.put_file(remote_path, local_path)
    dav.verify_size(remote_path, uploaded)
    print(f"загружено: {remote_path} ({uploaded} байт)")

    if args.latest_name:
        latest_path = f"{remote_dir}/{args.latest_name}"
        dav.put_file(latest_path, local_path)
        dav.verify_size(latest_path, uploaded)
        print(f"обновлена копия: {latest_path}")

    remaining = 0
    if args.keep > 0:
        archives = [
            entry["name"]
            for entry in dav.list_dir(remote_dir)
            if entry["name"] != args.latest_name
            and entry["name"].startswith(args.retention_prefix)
            and (entry["name"].endswith(".zip") or entry["name"].endswith(".zip.gpg"))
        ]
        archives.sort()
        stale = archives[:-args.keep] if len(archives) > args.keep else []
        for name in stale:
            dav.delete(f"{remote_dir}/{name}")
            print(f"удалён старый архив: {name}")
        remaining = len(archives) - len(stale)
        print(f"архивов на Диске после ротации: {remaining}")

    print(f"итог: {remote_path}; всего архивов: {remaining}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except DavError as error:
        print(f"ошибка WebDAV: {error}", file=sys.stderr)
        sys.exit(1)
