#!/bin/sh
# xray-sub-parser.sh
# Парсер одной VLESS-ссылки → JSON outbound
# Совместим с busybox ash (OpenWrt 25.12.x)

set -e

URL="$1"

if [ -z "$URL" ]; then
    echo "Usage: $0 vless://..."
    exit 1
fi

# -----------------------------
# Извлечение основных частей
# -----------------------------

USER=$(echo "$URL" | sed -n 's#vless://\([^@]*\)@.*#\1#p')
HOST=$(echo "$URL" | sed -n 's#.*@\(.*\):.*#\1#p')
PORT=$(echo "$URL" | sed -n 's#.*:\([0-9]*\).*#\1#p')

QUERY=$(echo "$URL" | sed -n 's#.*?\(.*\)#\1#p' | cut -d '#' -f1)

get_param() {
    echo "$QUERY" | tr '&' '\n' | grep "^$1=" | cut -d '=' -f2
}

TYPE=$(get_param type)
SECURITY=$(get_param security)
FLOW=$(get_param flow)
SNI=$(get_param sni)
FP=$(get_param fp)
PBK=$(get_param pbk)
SID=$(get_param sid)
SPX=$(get_param spx)
PATH=$(get_param path)
HOSTH=$(get_param host)
ALPN=$(get_param alpn)

# -----------------------------
# Вывод JSON outbound
# -----------------------------

cat <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "$HOST",
        "port": $PORT,
        "users": [
          {
            "id": "$USER",
            "encryption": "none",
            "flow": "$FLOW"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "$TYPE",
    "security": "$SECURITY",
    "realitySettings": {
      "serverName": "$SNI",
      "publicKey": "$PBK",
      "shortId": "$SID",
      "spiderX": "$SPX"
    },
    "tlsSettings": {
      "serverName": "$SNI",
      "alpn": ["$ALPN"],
      "fingerprint": "$FP"
    },
    "wsSettings": {
      "path": "$PATH",
      "headers": { "Host": "$HOSTH" }
    }
  }
}
EOF
