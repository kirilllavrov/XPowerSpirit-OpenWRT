# XPowerSpirit-OpenWRT
## Полная установка Xray + nftables TProxy + подписка + геофайлы + update
### Зависимые пакеты
```bash
apk update
apk add curl ca-certificates python3 kmod-nft-tproxy kmod-nft-socket unzip https-dns-proxy
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
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/install-openwrt-xray.sh | sh
```