# XPowerSpirit-OpenWRT

Комплексное решение для настройки прокси-сервера Xray с TProxy на OpenWrt. Проект включает автоматическую установку Xray, настройку гостевой сети, управление подписками, генерацию конфигурации и автоматическое обновление.

## 📋 Содержание

- [Возможности](#-возможности)
- [Архитектура проекта](#-архитектура-проекта)
- [Требования](#-требования)
- [Быстрый старт](#-быстрый-старт)
- [Детальное описание скриптов](#-детальное-описание-скриптов)
  - [install-openwrt-xray.sh](#install-openwrtxraysh)
  - [setup-wifi-network.sh](#setup-wifi-networksh)
  - [update-xray.sh](#update-xraysh)
  - [update-nft.sh](#update-nftsh)
  - [diagnose-xray-tproxy.sh](#diagnose-xray-tproxysh)
  - [xray-sub-parser.py](#xray-sub-parserpy)
  - [xray-generate-config.py](#xray-generate-configpy)
- [Структура файлов](#-структура-файлов)
- [Примеры использования](#-примеры-использования)
- [Troubleshooting](#-troubleshooting)

---

## ✨ Возможности

- **Автоматическая установка Xray** — загрузка последней версии с GitHub с проверкой целостности (SHA256)
- **TProxy через nftables** — прозрачная проксификация TCP/UDP трафика без необходимости настройки клиентов
- **Гостевая сеть** — изолированная Wi-Fi сеть с ограничением скорости (SQM)
- **Работа с подписками** — парсинг VLESS-ссылок из URL подписки с поддержкой Reality, WebSocket, gRPC, HTTP, XHTTP
- **Умная генерация конфигурации** — выбор лучшего сервера, маршрутизация по гео-базам (RU/частный трафик напрямую)
- **Автообновление** — ежедневное обновление Xray, geoip/geosite и конфигурации по расписанию
- **Hotplug-обновление** — автоматическое обновление после восстановления WAN-соединения
- **Глубокая диагностика** — проверка всех компонентов системы в одном скрипте
- **Безопасность** — WPA2+WPA3 (sae-mixed), PMF, изоляция клиентов гостевой сети

---

## 🏗 Архитектура проекта

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenWrt Router                          │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐ │
│  │ Home Wi-Fi  │    │ Guest Wi-Fi │    │   WAN (Internet)│ │
│  │ (LAN)       │    │ (br-guest)  │    │                 │ │
│  └──────┬──────┘    └──────┬──────┘    └────────┬────────┘ │
│         │                  │                     │          │
│         │                  ▼                     │          │
│         │          ┌───────────────┐             │          │
│         │          │  nftables     │◄────────────┤          │
│         │          │  TProxy :12345│             │          │
│         │          └───────┬───────┘             │          │
│         │                  │                     │          │
│         │                  ▼                     │          │
│         │          ┌───────────────┐             │          │
│         └─────────►│   Xray Core   │◄────────────┘          │
│                    │  (TProxy +    │                         │
│                    │   DNS 5053)   │                         │
│                    └───────────────┘                         │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Управление и обновления                  │  │
│  │  • update-xray.sh (cron: 2:30 nightly + hotplug)     │  │
│  │  • xray-sub-parser.py → xray-generate-config.py      │  │
│  │  • diagnose-xray-tproxy.sh                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Поток трафика

1. **Клиент → Гостевая сеть**: Трафик попадает в цепочку `prerouting` nftables
2. **nftables**: Отфильтровывает локальные адреса, DNS, исключения; остальное направляет на `127.0.0.1:12345`
3. **Xray TProxy**: Принимает трафик, выполняет DNS-over-HTTPS через встроенный DNS-резолвер
4. **Маршрутизация**:
   - `geoip:ru`, `geoip:private` → напрямую (`direct`)
   - Остальной трафик → прокси (`proxy`)

---

## 📦 Требования

### Аппаратные

- Устройство с OpenWrt 25.12.x или совместимой версией
- Минимум 20 MB свободного места в `/tmp`
- Поддержка nftables (ядро 4.19+)

### Программные зависимости

```bash
apk update
apk add curl ca-certificates python3 kmod-nft-tproxy kmod-nft-socket \
        unzip sqm-scripts jq wget nftables iptables
```

### Опционально (для расширенной функциональности)

- `luci-app-sqm` — веб-интерфейс для управления SQM

---

## 🚀 Быстрый старт

### 1. Установка зависимостей

```bash
apk update
apk add curl ca-certificates python3 kmod-nft-tproxy kmod-nft-socket unzip sqm-scripts jq wget
```

### 2. Загрузка установщика

```bash
cd /tmp
wget https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/install-openwrt-xray.sh
chmod +x install-openwrt-xray.sh
```

### 3. Запуск установки

```bash
./install-openwrt-xray.sh --sub=https://your-subscription-url.com
```

**Параметры установки:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--sub=URL` | URL подписки VLESS (обязательно) | — |
| `--guest-ip=IP` | IP-адрес шлюза гостевой сети | `192.168.2.1` |
| `--guest-dl=Kbps` | Лимит скачивания для гостей | `5120` (5 Mbps) |
| `--guest-ul=Kbps` | Лимит загрузки для гостей | `5120` (5 Mbps) |

### 4. Настройка Wi-Fi (опционально)

```bash
wget https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/setup-wifi-network.sh
chmod +x setup-wifi-network.sh

./setup-wifi-network.sh \
  --ssid=Home-WiFi \
  --pass=MySecurePass123 \
  --ssid-guest=Guest-WiFi \
  --pass-guest=GuestPass456
```

---

## 📜 Детальное описание скриптов

### install-openwrt-xray.sh

**Назначение:** Полный цикл установки и настройки Xray TProxy на OpenWrt.

**Что делает:**

1. **Настройка времени** — устанавливает таймзону `Europe/Moscow` (MSK-3)
2. **Сохранение подписки** — записывает URL в `/etc/xray/subscription.url`
3. **Гостевая сеть** — создаёт:
   - Bridge `br-guest`
   - Интерфейс `guest` с DHCP (диапазон `.100-.250`, аренда 12ч)
   - Firewall-зону с изоляцией от LAN
   - Правила для DNS/DHCP
   - Форвардинг в WAN
4. **SQM QoS** — ограничивает скорость гостевой сети (по умолчанию 5 Mbps up/down)
5. **Установка Xray**:
   - Загружает последнюю версию с GitHub
   - Проверяет SHA256 через `.dgst` файл
   - Кэширует ZIP при повторной установке
6. **Загрузка вспомогательных скриптов** в `/usr/share/xray/`:
   - `xray-generate-config.py`
   - `xray-sub-parser.py`
   - `update-xray.sh`
   - `update-nft.sh`
7. **Настройка DNS** — перенаправляет dnsmasq на `127.0.0.1:5053` и `127.0.0.1:5054`
8. **Init-скрипт** — создаёт `/etc/init.d/xray` с автозапуском
9. **Маршрутизация** — добавляет таблицу `xray` (ID 100) в `/etc/iproute2/rt_tables`
10. **Sysctl** — включает `route_localnet` и `ip_forward`
11. **Гео-базы** — загружает `geoip.dat` и `geosite.dat` с проверкой SHA256
12. **HWID** — генерирует уникальный идентификатор устройства HWID
13. **Генерация config.json** — парсит подписку и создаёт конфигурацию
14. **Cron** — добавляет задачу на обновление в 2:30 ночи
15. **Hotplug** — настраивает автообновление при подъёме WAN-интерфейса

**Логирование:** Все этапы записываются в `/tmp/xray_install.log`

---

### setup-wifi-network.sh

**Назначение:** Настройка двухдиапазонного Wi-Fi с разделением на домашнюю и гостевую сети.

**Особенности:**

- **Безопасность:** WPA2+WPA3 mixed mode (`sae-mixed`) с обязательным PMF
- **HE160** — поддержка ширины канала 160 MHz на 5 GHz
- **Изоляция клиентов** — в гостевой сети клиенты не видят друг друга
- **Time Advertisement** — трансляция времени для клиентов
- **Country RU** — оптимизировано для России

**Параметры:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--ssid=NAME` | SSID домашней сети | `Home-WiFi` |
| `--pass=PASS` | Пароль домашней сети | `HomeSecure123!` |
| `--ssid-guest=NAME` | SSID гостевой сети | `Guest-WiFi` |
| `--pass-guest=PASS` | Пароль гостевой сети | `GuestSecure123!` |

**Валидация:**

- SSID: 1-32 символа
- Пароль: 8-63 символа

**Логирование:** `/tmp/setup-wifi.log`

---

### update-xray.sh

**Назначение:** Автоматическое обновление Xray, гео-баз и конфигурации.

**Выполняет:**

1. **Проверка HWID и подписки** — читает `/etc/xray/hwid` и `/etc/xray/subscription.url`
2. **Обновление Xray**:
   - Сверяет SHA256 текущей и новой версии
   - Скачивает только если есть изменения
   - Проверяет целостность после загрузки
3. **Обновление geoip/geosite**:
   - Загружает с CDN kirilllavrov/geoip-builder и geosite-builder
   - Кэширует SHA256 в `/etc/xray/state/`
4. **Пересборка config.json**:
   - Загружает подписку с заголовком `x-hwid: <uuid>`
   - Парсит через `xray-sub-parser.py`
   - Генерирует конфиг через `xray-generate-config.py`
   - Проверяет валидность через `xray run -test`
   - Имеет 2 попытки при ошибке
5. **Пересборка nftables** — вызывает `update-nft.sh`
6. **Перезапуск Xray** — применяет новые настройки

**Отказоустойчивость:** При неудаче всех попыток останавливает Xray (не оставляет нерабочий конфиг)

**Логирование:** `/tmp/log/xray-update.log`

**Запуск:** Вручную или автоматически:

- Cron: `30 2 * * *` (ежедневно в 2:30)
- Hotplug: при событии `ifup wan`

---

### update-nft.sh

**Назначение:** Применение правил nftables для TProxy.

**Алгоритм:**

1. **Очистка** — удаляет старые правила и таблицу маршрутов 100
2. **Policy Routing**:

   ```bash
   ip rule add fwmark 1 table 100
   ip route add local 0.0.0.0/0 dev lo table 100
   ```

3. **Извлечение IP серверов** — парсит `config.json` для исключения их из TProxy
4. **Создание таблицы `inet xray`**:
   - Исключения: localhost, RFC1918, link-local, multicast, резервные адреса
   - Исключение IP серверов подписки
   - Исключение DHCP (порты 67-68)
   - Исключение Mark 0xff (трафик самого Xray)
   - TProxy для TCP/UDP с LAN-интерфейса на `127.0.0.1:12345`

**Автоопределение LAN:** Если `br-lan` отсутствует, автоматически определяет первый non-WAN интерфейс.

---

### diagnose-xray-tproxy.sh

**Назначение:** Комплексная диагностика работы Xray TProxy.

**Проверяет 10 ключевых точек:**

| # | Компонент | Что проверяется |
|---|-----------|-----------------|
| 1 | Процесс Xray | Запущен ли `xray` |
| 2 | Порты | Слушается ли порт 12345 |
| 3 | Конфигурация | Наличие `tproxy` и `mark: 255` в `config.json` |
| 4 | nftables | Таблица `ip xray`, исключение DNS (порт 53), hook prerouting |
| 5 | Интеграция fw4 | Jump в цепочку `xray_tproxy` из fw4 |
| 6 | Маршрутизация | `ip rule` с fwmark 1, таблица `xray` |
| 7 | dnsmasq | Перенаправление на `127.0.0.1#1053` |
| 8 | Логи Xray | Последние 3 ошибки из `/tmp/log/xray-error.log` |
| 9 | Доступность сервера | HTTPS/ICMP проверка сервера из конфига |
| 10 | DNS-тесты | Ответы от `127.0.0.1` и `1.1.1.1` |

**Авто-рекомендации:** Скрипт выдаёт конкретные команды для исправления найденных проблем.

**Пример вывода:**

```
[FAIL] DNS (порт 53) НЕ исключён! ГЛАВНАЯ ПРИЧИНА: 'сайты не грузятся'
🔧 РЕКОМЕНДАЦИИ:
[FIX DNS] Выполни:
nft delete table ip xray; /etc/init.d/xray-tproxy-rules restart
```

**Тест клиента:** В конце выводится команда для проверки с клиента:

```bash
curl -v --interface 192.168.1.138 http://ipinfo.io/ip
```

---

### xray-sub-parser.py

**Назначение:** Парсинг URL подписки и преобразование VLESS-ссылок в JSON-аутбаунды для Xray.

**Поддерживаемые протоколы:**

- VLESS over TCP
- VLESS over WebSocket (WS)
- VLESS over gRPC
- VLESS over HTTP/HTTP2
- VLESS over XHTTP (с поддержкой `extra` JSON)

**Поддерживаемые режимы безопасности:**

- None (без шифрования)
- TLS (с SNI, ALPN, fingerprint, allowInsecure)
- Reality (с publicKey, shortId, spiderX)

**Функции:**

1. **Нормализация тегов** — очистка названий серверов от спецсимволов, замена пробелов на `_`
2. **Загрузка URL** — автоматическое скачивание, если входные данные — HTTP(S) URL
3. **Base64-декодирование** — умное определение, нужно ли декодировать
4. **Парсинг query-параметров**:
   - `encryption`, `flow`, `type` (транспорт)
   - `security`, `sni`, `fp`, `alpn`, `allowInsecure`
   - `pbk`, `sid`, `spx` (Reality)
   - `path`, `host`, `serviceName`, `mode`, `extra` (транспорт)

**Входные данные:** Чтение из stdin (URL подписки или base64-строка)

**Выходные данные:** JSON-массив аутбаундов формата Xray

**Пример использования:**

```bash
cat subscription.txt | python3 xray-sub-parser.py > outbounds.json
```

**Пример выхода:**

```json
[
  {
    "tag": "proxy-vless-0",
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "example.com",
        "port": 443,
        "users": [{"id": "uuid...", "encryption": "none", "flow": "xtls-rprx-vision"}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "example.com",
        "publicKey": "...",
        "shortId": "...",
        "fingerprint": "chrome"
      }
    }
  }
]
```

---

### xray-generate-config.py

**Назначение:** Генерация полного `config.json` для Xray на основе распарсенных аутбаундов.

**Входные данные:** JSON-массив аутбаундов из `xray-sub-parser.py` (через stdin)

**Выходные данные:** Полный конфиг Xray с inbound, outbound, routing, DNS

**Ключевые функции:**

1. **Выбор лучшего сервера**:
   - Фильтрация заглушек (UUID `0000...`, адрес `0.0.0.0`, порт `1`)
   - Приоритет доменов из whitelist (`router.freenternet.top`)
   - Выбор первого доступного сервера

2. **Базовая конфигурация:**
   - **Логирование:** access/error логи в `/tmp/log/`
   - **DNS:**
     - Cloudflare (`1.1.1.1`), Google (`8.8.8.8`)
     - DoH: `cloudflare-dns.com`, `dns.google`, `dns.nextdns.io` (для ads)
     - Стратегия: `UseIPv4`, кэш включён, serveStale
   - **Inbound:**
     - `tproxy-in`: порт 12345, dokodemo-door, TProxy sockopt
     - `dns-in`: порт 5053, forward на `8.8.8.8:53`
     - `dns-in-alt`: порт 5054, forward на `1.1.1.1:53`

3. **Правила маршрутизации:**
   - DNS-трафик → `direct`
   - `geoip:ru`, `geoip:private` → `direct`
   - `geosite:private`, `geosite:category-browser`, `geosite:category-cdn-ru`, `geosite:category-mobile`, `geosite:category-ru` → `direct`
   - `geosite:category-streaming`, `geosite:category-games` → `proxy`
   - Остальной TCP/UDP → `proxy`

4. **Stream settings:**
   - `mark: 255` — исключение трафика Xray из TProxy
   - `tcpKeepAliveInterval: 30`
   - `tcpNoDelay: true`
   - Mux отключён

**Режим без серверов:** Если все сервера — заглушки, создаётся DIRECT-конфиг (весь трафик напрямую).

**Пример использования:**

```bash
python3 xray-sub-parser.py < subscription.url | \
python3 xray-generate-config.py --output /etc/xray/config.json
```

---

## 📁 Структура файлов

```
/etc/xray/
├── config.json           # Активная конфигурация Xray
├── subscription.url      # URL подписки
├── hwid                  # Уникальный ID устройства (UUID)
└── state/
    ├── xray.zip.sha256sum
    ├── geoip.dat.sha256sum
    └── geosite.dat.sha256sum

/usr/share/xray/
├── xray-generate-config.py
├── xray-sub-parser.py
├── update-xray.sh
├── update-nft.sh
└── geoip.dat             # Гео-база IP-адресов
└── geosite.dat           # Гео-база доменов

/etc/init.d/xray          # Init-скрипт для управления службой
/etc/hotplug.d/iface/99-xray-autoupdate  # Автообновление при ifup wan

/tmp/log/
├── xray-access.log       # Логи доступа
├── xray-error.log        # Логи ошибок
└── xray-update.log       # Логи обновлений
```

---

## 💡 Примеры использования

### Обновление подписки вручную

```bash
# Перечитать подписку и перегенерировать конфиг
HWID=$(cat /etc/xray/hwid)
SUB_URL=$(cat /etc/xray/subscription.url)

curl -s -L -H "x-hwid: $HWID" "$SUB_URL" | \
  python3 /usr/share/xray/xray-sub-parser.py | \
  python3 /usr/share/xray/xray-generate-config.py --output /etc/xray/config.json

# Проверить и перезапустить
xray run -test -config /etc/xray/config.json && service xray restart
```

### Проверка статуса

```bash
# Статус службы
service xray status

# Просмотр логов
tail -f /tmp/log/xray-error.log

# Диагностика
/usr/share/xray/diagnose-xray-tproxy.sh
```

### Изменение лимитов скорости для гостей

```bash
# Изменить SQM лимиты
uci set sqm.guest.download='10240'  # 10 Mbps
uci set sqm.guest.upload='5120'     # 5 Mbps
uci commit sqm
service sqm restart
```

### Добавление своего домена в whitelist

Отредактировать `/usr/share/xray/xray-generate-config.py`:

```python
DOMAIN_WHITELIST = [
    "router.freenternet.top",
    "your-custom-domain.com"  # Добавить сюда
]
```

Затем перегенерировать конфиг.

---

## 🔧 Troubleshooting

### Сайты не грузятся, но Xray запущен

1. **Проверьте исключение DNS в nftables:**

   ```bash
   nft list chain ip xray xray_tproxy | grep 53
   ```

   Должно быть правило с `return` для порта 53.

2. **Проверьте dnsmasq:**

   ```bash
   uci show dhcp.@dnsmasq[0].server
   ```

   Должно быть: `127.0.0.1#5053` и `127.0.0.1#5054`

3. **Запустите диагностику:**

   ```bash
   /usr/share/xray/diagnose-xray-tproxy.sh
   ```

### Ошибка: " Недостаточно места в /tmp"

Очистите временные файлы:

```bash
rm -rf /tmp/xray_*
rm -f /tmp/*.log
```

### Конфиг не проходит валидацию

Проверьте логи парсера:

```bash
curl -s -L -H "x-hwid: $(cat /etc/xray/hwid)" "$(cat /etc/xray/subscription.url)" | \
  python3 /usr/share/xray/xray-sub-parser.py 2>&1 | tee /tmp/debug.json
```

### Geo-файлы не загружаются

Проверьте доступность CDN:

```bash
curl -I https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat
```

Если недоступно — попробуйте альтернативный источник или обновите позже.

### Гостевая сеть не работает

1. Проверьте, создан ли интерфейс:

   ```bash
   uci show network.guest
   ```

2. Проверьте firewall:

   ```bash
   uci show firewall.guest
   ```

3. Перезапустите службы:

   ```bash
   service network restart
   service firewall restart
   service dnsmasq restart
   ```

---

## 📄 Лицензия

Проект распространяется под лицензией MIT. См. файл [LICENSE](LICENSE).

## 👤 Автор

- GitHub: [@kirilllavrov](https://github.com/kirilllavrov)
- Репозиторий: [XPowerSpirit-OpenWRT](https://github.com/kirilllavrov/XPowerSpirit-OpenWRT)

## 🤝 Вклад в проект

Pull requests приветствуются! Для серьёзных изменений сначала создайте issue для обсуждения.

## 📮 Контакты

По вопросам и предложениям обращайтесь через GitHub Issues.
