# XPowerSpirit-OpenWRT

## Полная установка Xray + nftables TProxy + подписка + геофайлы + update

### Зависимые пакеты

```bash
apk update
apk add curl ca-certificates python3 kmod-nft-tproxy kmod-nft-socket unzip
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
./setup-guest-network.sh --ssid=Guest-WiFi --pass=MyPass123 --dl=20000 --ul=10000
```
