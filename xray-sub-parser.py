#!/usr/bin/env python3
import sys
import base64
import json
import urllib.parse as urlparse
import urllib.request
import re


def normalize_tag(tag: str) -> str:
    tag = urlparse.unquote(tag)
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-🇦-🇿🇦-🇿]", "", tag)
    return tag or "proxy"


def try_download(url: str) -> str:
    if url.startswith("http://") or url.startswith("https://"):
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                return r.read().decode("utf-8", errors="ignore")
        except Exception:
            return url
    return url


def try_base64_decode(data: str) -> str:
    data = data.strip()
    try:
        decoded = base64.b64decode(data, validate=True).decode("utf-8", errors="ignore")
        return decoded
    except Exception:
        return data


def parse_vless_uri(uri: str):
    parsed = urlparse.urlparse(uri)
    if parsed.scheme.lower() != "vless":
        return None

    user = parsed.username or ""
    host = parsed.hostname or ""
    port = parsed.port or 443

    fragment = parsed.fragment or ""
    tag = normalize_tag(fragment) if fragment else "proxy"

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

    if security_mode == "tls":
        stream["security"] = "tls"
        tls = {}
        if sni: tls["serverName"] = sni
        if alpn: tls["alpn"] = alpn
        if fp: tls["fingerprint"] = fp
        if allow_insecure: tls["allowInsecure"] = True
        if tls: stream["tlsSettings"] = tls

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

    if network == "ws":
        ws = {"path": path}
        if host_header:
            ws["headers"] = {"Host": host_header}
        stream["wsSettings"] = ws

    elif network == "grpc":
        grpc = {}
        if grpc_service:
            grpc["serviceName"] = grpc_service
        stream["grpcSettings"] = grpc

    elif network == "http":
        http = {"path": path}
        if host_header:
            http["host"] = [host_header]
        stream["httpSettings"] = http

    elif network == "xhttp":
        xhttp = {"path": path}
        if host_header:
            xhttp["host"] = [host_header]
        if xhttp_mode:
            xhttp["mode"] = xhttp_mode
        if extra_json:
            xhttp["extra"] = extra_json
        stream["xhttpSettings"] = xhttp

    return {
        "tag": tag,
        "protocol": "vless",
        "settings": settings,
        "streamSettings": stream
    }


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        print("[]")
        return

    data = try_download(raw)
    data = try_base64_decode(data)

    lines = [l.strip() for l in data.splitlines() if "vless://" in l]

    outbounds = []
    for line in lines:
        ob = parse_vless_uri(line)
        if ob:
            outbounds.append(ob)

    print(json.dumps(outbounds, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
