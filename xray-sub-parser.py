#!/usr/bin/env python3
import sys
import base64
import json
import urllib.parse as urlparse
import urllib.request
import re


# -----------------------------
# Утилиты
# -----------------------------

def normalize_tag(tag: str) -> str:
    tag = urlparse.unquote(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-🇦-🇿🇦-🇿]", "", tag)
    return tag or "proxy"


def try_download(url: str) -> str:
    """Если строка похожа на URL — скачиваем."""
    if url.startswith("http://") or url.startswith("https://"):
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return r.read().decode("utf-8", errors="ignore")
        except Exception:
            return url
    return url


def try_base64_decode(data: str) -> str:
    """Пробуем декодировать base64, если это подписка."""
    data = data.strip()

    # Если уже содержит vless:// — это не base64
    if "vless://" in data:
        return data

    try:
        decoded = base64.b64decode(data, validate=True).decode("utf-8", errors="ignore")
        if "vless://" in decoded:
            return decoded
    except Exception:
        pass

    return data


# -----------------------------
# Парсер VLESS
# -----------------------------

def parse_vless_uri(uri: str):
    parsed = urlparse.urlparse(uri)

    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443

    # tag
    fragment = parsed.fragment or ""
    tag = normalize_tag(fragment) if fragment else "proxy"

    # query
    q = urlparse.parse_qs(parsed.query)

    def get_param(key, default=None):
        v = q.get(key)
        return v[0] if v else default

    uuid = user
    encryption = get_param("encryption", "none")
    flow = get_param("flow", None)

    network = get_param("type", "tcp").lower()
    if network in ("h2", "http2"):
        network = "http"
    if network not in ("tcp", "ws", "grpc", "http", "xhttp"):
        network = "tcp"

    security = get_param("security", "none").lower()
    if security in ("tls", "xtls"):
        security_mode = "tls"
    elif security == "reality":
        security_mode = "reality"
    else:
        security_mode = "none"

    sni = get_param("sni", None)
    fp = get_param("fp", None)
    alpn_raw = get_param("alpn", None)
    alpn = [x.strip() for x in alpn_raw.split(",")] if alpn_raw else None
    allow_insecure = get_param("allowInsecure", "0") in ("1", "true", "yes")

    pbk = get_param("pbk", None)
    sid = get_param("sid", None)
    spx = get_param("spx", None)

    path = get_param("path", "/")
    host_header = get_param("host", None)
    grpc_service = get_param("serviceName", None)
    xhttp_mode = get_param("mode", None)

    extra_raw = get_param("extra", None)
    extra_json = None
    if extra_raw:
        try:
            extra_json = json.loads(extra_raw)
        except Exception:
            extra_json = {"raw": extra_raw}

    # -----------------------------
    # Формируем outbound
    # -----------------------------

    user_obj = {"id": uuid, "encryption": encryption}
    if flow:
        user_obj["flow"] = flow

    settings = {
        "vnext": [
            {
                "address": host,
                "port": port,
                "users": [user_obj]
            }
        ]
    }

    stream = {"network": network}

    # TLS
    if security_mode == "tls":
        stream["security"] = "tls"
        tls = {}
        if sni: tls["serverName"] = sni
        if alpn: tls["alpn"] = alpn
        if fp: tls["fingerprint"] = fp
        if allow_insecure: tls["allowInsecure"] = True
        if tls: stream["tlsSettings"] = tls

    # REALITY
    elif security_mode == "reality":
        stream["security"] = "reality"
        reality = {}
        if sni: reality["serverName"] = sni
        if pbk: reality["publicKey"] = pbk
        if sid: reality["shortId"] = sid
        if spx: reality["spiderX"] = spx
        if fp: reality["fingerprint"] = fp
        if allow_insecure: reality["allowInsecure"] = True
        stream["realitySettings"] = reality

    # WS
    if network == "ws":
        ws = {"path": path}
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws

    # gRPC
    elif network == "grpc":
        grpc = {}
        if grpc_service:
            grpc["serviceName"] = grpc_service
        stream["grpcSettings"] = grpc

    # HTTP/2
    elif network == "http":
        http = {"path": path}
        if host_header:
            http["host"] = [host_header]
        stream["httpSettings"] = http

    # XHTTP
    elif network == "xhttp":
        xhttp = {"path": path}
        if host_header:
            xhttp["host"] = [host_header]
        if xhttp_mode:
            xhttp["mode"] = xhttp_mode
        if extra_json:
            xhttp["extra"] = extra_json
        stream["xhttpSettings"] = xhttp

    outbound = {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream
    }

    return outbound


# -----------------------------
# MAIN
# -----------------------------

def main():
    raw = sys.stdin.read().strip()

    if not raw:
        print("{}")
        return

    # 1) Если это URL → скачиваем
    data = try_download(raw)

    # 2) Если это base64 → декодируем
    data = try_base64_decode(data)

    # 3) Ищем первую vless:// строку
    lines = [l.strip() for l in data.splitlines() if "vless://" in l]

    if not lines:
        print("{}")
        return

    # Берём первый сервер
    uri = lines[0]

    outbound = parse_vless_uri(uri)
    if not outbound:
        print("{}")
        return

    print(json.dumps(outbound, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
