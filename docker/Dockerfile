# Стенд XPowerSpirit-OpenWRT: python3, jq, curl и настоящий Xray с гео-базами.
# Нужен, чтобы прогонять парсер/генератор и проверять конфиг ядром (`xray run -test`)
# без роутера и без износа flash. Сам TProxy/nftables в контейнере не эмулируется.
FROM alpine:3.22

ARG XRAY_VERSION=latest

RUN apk add --no-cache python3 jq curl unzip ca-certificates tzdata

RUN set -eux; \
    ver="${XRAY_VERSION}"; \
    if [ "$ver" = "latest" ]; then \
        ver=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
              | jq -r '.tag_name'); \
    fi; \
    curl -fsSLo /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${ver}/Xray-linux-64.zip"; \
    unzip -q /tmp/xray.zip -d /usr/local/bin xray; \
    chmod +x /usr/local/bin/xray; \
    mkdir -p /usr/share/xray; \
    curl -fsSLo /usr/share/xray/geoip.dat \
        "https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat"; \
    curl -fsSLo /usr/share/xray/geosite.dat \
        "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"; \
    rm -f /tmp/xray.zip; \
    xray version

ENV XRAY_LOCATION_ASSET=/usr/share/xray
WORKDIR /work

CMD ["/src/docker/run-stand.sh"]
