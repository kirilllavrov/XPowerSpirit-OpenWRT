# XPowerSpirit-OpenWRT

## Полная установка Xray + nftables TProxy + подписка + геофайлы + update

### Зависимые пакеты

```bash
apk update
apk add curl ca-certificates python3 kmod-nft-tproxy kmod-nft-socket unzip sqm-scripts jq
```

#### Установка Xray на OpenWRT

```bash
wget https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/install-openwrt-xray.sh
```

```bash
chmod +x install-openwrt-xray.sh
```

```bash
./install-openwrt-xray.sh
```

```bash
./setup-wifi-network.sh \
  --ssid=Home-WiFi \
  --pass=MyPass123 \
  --ssid-guest=Guest-WiFi \
  --pass-guest=MyPass123 \
  --dl-guest=20000 \
  --ul-guest=10000

```
