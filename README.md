# XPowerSpirit-OpenWRT

Комплексное решение для настройки прокси-сервера Xray с TProxy на OpenWrt. Проект включает автоматическую установку Xray, настройку гостевой сети, управление подписками, генерацию конфигурации и автоматическое обновление.

> **Связанные проекты (не зависимость):** OpenWrt-пакеты (LuCI веб-интерфейс + CLI `xray-status`) живут в отдельном репозитории [XPowerSpirit-WebUI](https://github.com/kirilllavrov/XPowerSpirit-WebUI). Этот проект устанавливается и работает полностью без него.
>
> **Документация по конфигурации Xray:** [xray-config-reference.md](./xray-config-reference.md) — справочник по базовой конфигурации, сверенный с официальной русской документацией; [xray-config-links.md](./xray-config-links.md) — карта официальных ссылок (Xray, nftables).

## 📋 Содержание

- [Возможности](#-возможности)
- [Архитектура проекта](#-архитектура-проекта)
- [Требования](#-требования)
- [Быстрый старт](#-быстрый-старт)
- [Детальное описание скриптов](#-детальное-описание-скриптов)
  - [install-openwrt-xray.sh](#install-openwrtxraysh)
  - [setup-led-status.sh](#setup-led-statussh)
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

- **Автоматическая установка Xray** — загрузка последнего релиза с GitHub с проверкой SHA2-256 (по `.dgst`)
- **TProxy через nftables** — прозрачная проксификация TCP/UDP: `prerouting` для LAN и `output` для трафика самого роутера
- **Работа с подписками** — два формата: Base64 (VLESS URI) и JSON (Happ/Sing-box/Karing/XPower); транспорты TCP, WebSocket, gRPC, HTTP, XHTTP; TLS и Reality
- **Балансировка** — все серверы подписки идут через `balancer` (стратегия `leastLoad`) с `burstObservatory`, fallback — `direct`
- **Умная маршрутизация** — гео-базы RU/private напрямую, блокировка рекламы и QUIC, DoH-домены в обход прокси
- **Автообновление** — ежедневное обновление Xray, geoip/geosite и конфигурации по расписанию (cron)
- **Hotplug-обновление** — автоматическое обновление после восстановления WAN-соединения
- **Безопасность WiFi** — WPA2+WPA3 (sae-mixed, PMF optional), изоляция клиентов гостевой/IoT сетей
- **Гостевая и IoT сети** — изолированные сегменты с ограничением скорости (SQM)
- **Глубокая диагностика** — проверка всех компонентов системы в одном скрипте

---

## 🏗 Архитектура проекта

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenWrt Router                          │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │ Home Wi-Fi  │    │ Guest Wi-Fi │    │ WAN (Internet)  │  │
│  │ (LAN)       │    │ (br-guest)  │    │                 │  │
│  └──────┬──────┘    └──────┬──────┘    └────────┬────────┘  │
│         │                  │                    │           │
│         │                  ▼                    │           │
│         │          ┌───────────────┐            │           │
│         │          │  nftables     │◄───────────┤           │
│         │          │  TProxy :12345│            │           │
│         │          └───────┬───────┘            │           │
│         │                  │                    │           │
│         │                  ▼                    │           │
│         │          ┌───────────────┐            │           │
│         └─────────►│   Xray Core   │◄───────────┘           │
│                    │  (TProxy +    │                        │
│                    │   DNS 5353)   │                        │
│                    └───────────────┘                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Управление и обновления                 │   │
│  │  • update-xray.sh (cron: 2:30 nightly + hotplug)     │   │
│  │  • xray-sub-parser.py → xray-generate-config.py      │   │
│  │  • diagnose-xray-tproxy.sh                           │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Поток трафика

1. **Клиент LAN** → трафик попадает в цепочку `prerouting` (fw4) → `jump xray_tproxy`
2. **Трафик самого роутера** → отдельная таблица `inet xray_self` с цепочкой `type route hook output priority mangle`: пакет помечается `meta mark set 1` и через policy routing (таблица 100) возвращается в `prerouting`, где попадает под TProxy. Тип цепочки `route` обязателен — в цепочке `type filter` (как `fw4 output`) mark не влияет на маршрутизацию
3. **nftables**: bypass локальных адресов, DNS-резолверов, DHCP, IP прокси-серверов; полный bypass интерфейсов `br-guest` и `br-iot`; блокировка QUIC (UDP/443) с LAN **до** TProxy; остальное — `tproxy ip to 127.0.0.1:12345` c `meta mark set 0x1`
4. **Защита от петель**: Xray-аутбаунды ставят `sockopt.mark = 2`, а обе цепочки начинаются с `meta mark 2 return`
5. **Xray TProxy** (inbound `tunnel`, он же `dokodemo-door`, `tproxy`, сниффинг http/tls в режиме `routeOnly`): прозрачно перехватывает трафик; DNS от dnsmasq (`127.0.0.1:5353`) уходит в встроенный DNS (DoH)
6. **Маршрутизация**:
   - `geoip:ru`, `geoip:private` → напрямую (`direct`)
   - `geosite:private`, `geosite:category-browser`, `geosite:category-cdn-ru`, `geosite:category-mobile`, `geosite:category-ru` → напрямую
   - `geosite:category-ads` → `block`, QUIC (UDP/443) → `block`, NTP (UDP/123) → `direct`
   - `geosite:category-streaming`, `geosite:category-games` и весь остальной TCP/UDP → `balancer` (leastLoad, fallback `direct`)

---

## 📦 Требования

### Аппаратные

- Устройство с OpenWrt 25.12.x или совместимой версией
- Firewall `fw4` (nftables, таблица `inet fw4`) — правила TProxy добавляются именно в неё
- Минимум 20 MB свободного места в `/tmp` и 10 MB в `/`
- Поддержка nftables TProxy в ядре (`kmod-nft-tproxy`, `kmod-nft-socket`)

### Поддерживаемые архитектуры

Платформа Xray определяется по `DISTRIB_ARCH` из `/etc/openwrt_release`, при его отсутствии — по `uname -m`:

| `DISTRIB_ARCH` | Архитектура устройства | Ассет Xray |
|---|---|---|
| `x86_64` | x86-64 | `Xray-linux-64.zip` |
| `i386`, `i486`, `i586`, `i686` | x86-32 | `Xray-linux-32.zip` |
| `aarch64_*` | ARM64 (Cortex-A53/A72, MT7981/MT7986, IPQ807x…) | `Xray-linux-arm64-v8a.zip` |
| `arm_cortex-a5/a7/a8/a9/a15/a53/a72/a76*` | ARMv7 | `Xray-linux-arm32-v7a.zip` |
| `arm_arm1176*` | ARMv6 (BCM2835 и подобные) | `Xray-linux-arm32-v6.zip` |
| `arm_xscale*`, `arm_arm926*`, `arm_arm1136*`, `arm_fa526*` | ARMv5 | `Xray-linux-arm32-v5.zip` |
| `mips_*` | MIPS big-endian (ath79 и др.) | `Xray-linux-mips32.zip` |
| `mipsel_*` | MIPS little-endian (MT7620/7621, ramips) | `Xray-linux-mips32le.zip` |
| `mips64_*` / `mips64el_*` | MIPS64 | `Xray-linux-mips64.zip` / `mips64le` |
| `riscv64_*`, `loongarch64_*` | RISC-V / LoongArch | `Xray-linux-riscv64.zip` / `loong64` |

Неизвестная архитектура — установка останавливается с сообщением, а не подставляет x86-64.
`update-xray.sh` в этом случае не трогает уже установленный бинарь.

> Важно: `uname -m` отдаёт `mips` и для big-endian, и для little-endian MIPS, поэтому определять
> архитектуру по нему нельзя — используется `DISTRIB_ARCH`.

### Программные зависимости

Скрипт установки **не устанавливает пакеты** — их нужно поставить заранее (`opkg install` или `apk add`):

```bash
curl ca-certificates nftables kmod-nft-tproxy kmod-nft-socket python3 resolveip unzip sqm-scripts jq
```

### Опционально (для расширенной функциональности)

- `luci-app-sqm` — веб-интерфейс для управления SQM

---

## 🚀 Быстрый старт

### 1. Загрузка и минимальная установка

```bash
cd /tmp
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/install-openwrt-xray.sh | sh -s -- \
  --sub=https://your-subscription-url.com \
  --guest=1
```

**Параметры установки:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--sub=URL` | URL подписки (обязательно) | — |
| `--sub-ua=STRING` | User-Agent для запроса подписки (он же определяет формат подписки) | `XPower/1.0` (из `settings.default.json`) |
| `--remarks=STRING` | Фильтр профиля по remarks (только для JSON-подписок) | — |
| `--lan-ip=IP` | IP-адрес роутера в LAN | `192.168.1.1` |
| `--guest=1` | Включить гостевую сеть + SQM | `0` |
| `--guest-ip=IP` | IP-адрес шлюза гостевой сети | `192.168.2.1` |
| `--guest-dl=Kbps` | Лимит скачивания для гостей | `5120` (5 Mbps) |
| `--guest-ul=Kbps` | Лимит загрузки для гостей | `5120` (5 Mbps) |
| `--iot=1` | Включить IoT-сеть + SQM | `0` |
| `--iot-ip=IP` | IP-адрес шлюза IoT-сети | `192.168.3.1` |
| `--iot-dl=Kbps` | Лимит скачивания для IoT | `10240` (10 Mbps) |
| `--iot-ul=Kbps` | Лимит загрузки для IoT | `10240` (10 Mbps) |
| `--dwl=DOMAIN` | Домен для whitelist (`subscription.domain_whitelist`) | — |

> `--guest-dl=0 --guest-ul=0` (аналогично для IoT) отключает SQM — скорость не ограничивается.
> Значения `--guest-*`/`--iot-*`/`--lan-ip` применяются напрямую в UCI и в `settings.json` не сохраняются.

### 2. Настройка Wi-Fi (опционально)

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/setup-wifi-network.sh | sh -s -- \
  --ssid=Home-WiFi \
  --pass=MySecurePass123 \
  --ssid-guest=Guest-WiFi \
  --pass-guest=GuestPass456 \
  --ssid-iot=IoT-WiFi \
  --pass-iot=IoTPass789
```

### 3. Настройка LED-индикации

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/setup-led-status.sh | sh
```

---

## 📜 Детальное описание скриптов

### install-openwrt-xray.sh

**Назначение:** Полный цикл установки и настройки Xray TProxy на OpenWrt.

**Что делает:**

1. **Настройка времени** — таймзона `Europe/Moscow` (MSK-3), синхронизация NTP (`ru.pool.ntp.org`, fallback `time.google.com`)
2. **Загрузка скриптов** — скачивает `xray-generate-config.py`, `xray-sub-parser.py`, `update-xray.sh`, `update-nft.sh` в `/usr/share/xray/`
3. **Сохранение настроек** — записывает URL подписки, User-Agent, фильтр remarks, модель/версию ОС, HWID и домен в whitelist в единый JSON-файл `/etc/xray/settings.json` (файл инициализируется из `settings.default.json` в репозитории, если его ещё нет)
4. **LAN и IPv6** — задаёт `--lan-ip` (по умолчанию `192.168.1.1/24`), диапазон DHCP `.100-.250`, отключает IPv6 на LAN/WAN, останавливает и отключает `odhcpd`
5. **Гостевая сеть (опционально, `--guest=1`)**:
   - Bridge `br-guest`, интерфейс `guest` с DHCP (`.100-.250`, аренда 12ч)
   - Firewall-зона `guest` (`input/forward REJECT`, masq) с изоляцией от LAN
   - Правила для DNS/DHCP, форвардинг в WAN
   - SQM (`cake` / `piece_of_cake.qos`) с лимитами `--guest-dl`/`--guest-ul`
6. **IoT-сеть (опционально, `--iot=1`)** — то же самое для `br-iot` с лимитами `--iot-dl`/`--iot-ul`
7. **Установка Xray**:
   - Загружает последний релиз с GitHub (архитектура определяется по `uname -m`)
   - Проверяет SHA2-256 через `.dgst` файл
   - Пропускает установку, если версия уже актуальна; кэширует ZIP по SHA
8. **Настройка DNS** — dnsmasq без `resolv`-файла, `strictorder`, кэш 1000 записей, TTL 300–600, серверы `127.0.0.1#5353` (Xray) + fallback `77.88.8.8`
9. **Init-скрипт** — `/etc/init.d/xray` (`procd`): ожидание сети, синхронизация времени, проверка geo-файлов и конфига, применение nftables-правил, `respawn 3600 5 5`
10. **Маршрутизация** — таблица `xray` (ID 100) в `/etc/iproute2/rt_tables`
11. **Sysctl** — `route_localnet`, `ip_forward` (+ `/etc/sysctl.d/99-xray.conf`)
12. **Гео-базы** — `geoip.dat` / `geosite.dat` с проверкой SHA256
13. **HWID** — уникальный ID устройства (`/proc/sys/kernel/random/uuid` без дефисов)
14. **Генерация config.json** — единый пайплайн: `xray-sub-parser.py --ua <UA>` (автоопределение формата подписки) → `xray-generate-config.py --format unified`
15. **Проверка конфига** — `xray run -test -config /etc/xray/config.json`
16. **Cron** — автообновление в 2:30 (`30 2 * * *`)
17. **Hotplug** — автообновление при подъёме WAN (`ifup wan`), но только после успешной проверки интернета
18. **Перезагрузка** — по завершении установки роутер перезагружается

**Логирование:** Все этапы записываются в `/tmp/xray_install.log`

---

### setup-led-status.sh

**Назначение:** Настройка LED-индикации статуса интернета и активности Xray.

**Поддерживаемые устройства:** Проверено на Cudy WR3000S v1. Скрипт требует наличия `/sys/class/leds/white:wps` и `/sys/class/leds/white:wan-online`, иначе завершается с ошибкой.

**Функционал:**

0. **Очистка** — удаляет **все** существующие LED-конфигурации (`system.@led`) перед настройкой
1. **LED Xray_Status (white:wps)**:
   - Мигает при сетевом трафике через loopback (`lo`)
   - Триггер: `netdev`, устройство `lo`, режим: `tx rx`, интервал: 100 мс
   - Индикация активной проксификации

2. **LED Интернет (white:wan-online)**:
   - Горит при доступности интернета (`default-on`), гаснет (`none`) при отсутствии
   - Проверка через `curl https://www.google.com/gen_204` каждые 1 минуту (cron + `/etc/init.d/cron restart`)
   - Скрипт проверки: `/usr/share/xray/net-check.sh`

**Результат:**

- `white:wps` — мигает при трафике Xray
- `white:wan-online` — горит при наличии интернета

---

### setup-wifi-network.sh

**Назначение:** Настройка двухдиапазонного Wi-Fi с разделением на домашнюю, гостевую и IoT-сети.

**Особенности:**

- **Безопасность:** WPA2+WPA3 mixed mode (`sae-mixed`). PMF задаётся параметром `ieee80211w='1'` — это **optional**, а не required
- **Изоляция клиентов** — в гостевой и IoT сетях клиенты не видят друг друга (`isolate=1`, `bridge_isolate=1`)
- **Country RU** — `country='RU'`, `country_ie='1'`
- **Radio** — `channel='auto'`, `legacy_rates='0'`, `cell_density='2'`, `wmm='1'`, `disassoc_low_ack='0'`; `htmode` = `HT20` для 2.4 GHz и `HE80` для 5 GHz, `band` определяется по имени radio (`radio0` → `2g`, остальные → `5g`)
- **Существующие Wi-Fi интерфейсы удаляются** (`wireless.@wifi-iface`) перед настройкой

**Параметры:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--ssid=NAME` | SSID домашней сети | `Home-WiFi` |
| `--pass=PASS` | Пароль домашней сети | `HomeSecure123!` |
| `--ssid-guest=NAME` | SSID гостевой сети | `Guest-WiFi` |
| `--pass-guest=PASS` | Пароль гостевой сети | `GuestSecure123!` |
| `--ssid-iot=NAME` | SSID IoT-сети | `IoT-WiFi` |
| `--pass-iot=PASS` | Пароль IoT-сети | `IoTSecure123!` |

**Условия настройки сетей:**

- **Home** — создаётся всегда (по одному `wifi-iface` на radio, сеть `lan`)
- **Guest** — только если существует `network.guest` (создаётся установщиком с `--guest=1`)
- **IoT** — только если существует `network.iot` (создаётся установщиком с `--iot=1`)

**Валидация:**

- SSID: 1-32 символа
- Пароль: 8-63 символа

**Логирование:** `/tmp/setup-wifi.log`

---

### update-xray.sh

**Назначение:** Автоматическое обновление Xray, гео-баз и конфигурации.

**Выполняет:**

0. **Блокировка от параллельного запуска** — `/var/lock/xray-update.lock` (`flock -n`)
1. **Ротация логов** — обнуляет `xray-access.log` при > 512 KB, `xray-error.log` и `xray-update.log` при > 256 KB
2. **Проверка места** — требует минимум 10 MB свободного в `/`, иначе выход с ошибкой
3. **Проверка HWID и подписки** — читает все настройки из единого `/etc/xray/settings.json`; останавливается, если `hwid` или `subscription.url` пусты
4. **Обновление Xray**:
   - Скачивает `.dgst` с GitHub, сверяет SHA2-256
   - Скачивает ZIP только если SHA изменился (кэш в `/etc/xray/state/xray.zip.sha256sum`) и в `/tmp` есть 20 MB
   - Останавливает Xray, обновляет `/usr/bin/xray`, проверяет SHA скачанного ZIP
5. **Обновление geoip/geosite**:
   - Загружает `geoip.dat` / `geosite.dat` по URL из `settings.json → geo.*`
   - Сверяет с `.sha256sum`, кэширует SHA в `/etc/xray/state/`
   - Атомарное обновление (`mv`)
6. **Пересборка config.json** — единый пайплайн:

   ```bash
   curl (User-Agent + x-hwid + X-Ver-Os/X-Device-Model/X-Device-Os) → sub.txt
   xray-sub-parser.py --ua <UA> [--remarks <фильтр>] → {"hole":…, "outbounds":[…]}
   xray-generate-config.py --format unified --output config.json
   xray run -test -config config.json
   ```

   **Формат подписки определяется по User-Agent** (см. [xray-sub-parser.py](#xray-sub-parserpy)):
   - `*happ*`, `*singbox*`, `*karing*`, `*sfa*`, `*sfi*`, `*sfm*`, `*sft*`, `*xpower*` → **JSON** (Happ/Sing-box/XPower)
   - Любой другой → **Base64/VLESS**

   Фильтр профилей (`--remarks`) берётся из `settings.json → subscription.remarks_filter` и применяется только к JSON-подпискам.

   Новый конфиг устанавливается только после успешной проверки `xray run -test`.

7. **Пересборка nftables** — вызывает `update-nft.sh` (ошибка только логируется, Xray не останавливается)
8. **Перезапуск Xray** — перезапускает `/etc/init.d/xray` с новым конфигом

**Отказоустойчивость:** Если новый конфиг невалиден — остаётся прежний `config.json`, и Xray перезапускается с ним. Если итоговый конфиг отсутствует или невалиден — Xray останавливается.

**Логирование:** `/tmp/log/xray-update.log`, диагностика парсера/генератора — туда же (`2>>`)

**Запуск:** Вручную или автоматически:

- Cron: `30 2 * * *` (ежедневно в 2:30)
- Hotplug: при событии `ifup wan` (после того как интернет станет доступен)

---

### update-nft.sh

**Назначение:** Применение правил nftables для TProxy (интеграция с fw4 OpenWrt).

**Алгоритм:**

1. **Автоопределение интерфейсов** — `br-lan` (fallback: `network.lan`), `br-guest` (fallback: `network.guest`), `br-iot` (fallback: `network.iot`)
2. **Извлечение IP серверов и DNS** — Python-парсер `config.json` собирает `vnext[].address` из всех outbound-ов (пропуская `hole`, `0.0.0.0`, `127.0.0.1` и имена без точки) и IP из `dns.hosts`/`dns.servers`; при неудачном применении правил скрипт завершается с ошибкой
3. **Policy Routing** (идемпотентно — старые правила удаляются):
   - `ip rule add fwmark 1 table 100`
   - `ip route add local 0.0.0.0/0 dev lo table 100`
4. **Создание/очистка цепочек** `inet fw4 xray_tproxy` (вызов из `prerouting`) и таблицы `inet xray_self` (`type route hook output priority mangle`); при повторном запуске цепочка `xray_tproxy` очищается (`flush`), jump-правило не дублируется, таблица `xray_self` пересоздаётся. Устаревшая схема с `fw4 xray_output` удаляется автоматически

5. **PREROUTING (`xray_tproxy`)** — порядок правил важен:
   - `meta mark 2 return` — защита от петель (Xray-аутбаунды маркируют свои пакеты `mark = 2`)
   - Bypass локальных адресов: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`
   - Bypass DNS-резолверов: `77.88.8.8`, `77.88.8.1`, `1.1.1.1`, `1.0.0.1`, `45.90.28.0`, `45.90.30.0`
   - Bypass DHCP (UDP 67/68)
   - Bypass IP прокси-серверов из `config.json`
   - Bypass `br-guest` и `br-iot` (если интерфейсы существуют) — их трафик не проксируется
   - **Блокировка QUIC** — `iifname <LAN> udp dport 443 drop` (до TProxy)
   - **TProxy для LAN** — `iifname <LAN>` TCP/UDP → `tproxy ip to 127.0.0.1:12345 meta mark set 0x1 accept`
   - **TProxy для трафика роутера** — правила без `iifname` для пакетов с `meta mark 0x1`, возвращённых из `xray_self` через таблицу 100

6. **OUTPUT (`inet xray_self`, `type route hook output priority mangle`)** — трафик самого роутера:
   - `meta mark 2 return`
   - Те же bypass-правила (локальные сети, DNS, DHCP, IP прокси-серверов)
   - `meta l4proto tcp/udp meta mark set 1` — маркировка, по которой пакет через policy routing возвращается в `prerouting` и попадает под TProxy

7. **Завершение** — запись в syslog (`logger -t update-nft`)

> Явного правила bypass для порта 53 нет: DNS-запросы клиентов адресованы роутеру (`192.168.0.0/16`) и отсекаются bypass-правилом локальных адресов, а внешние резолверы исключены списком IP.

---

### diagnose-xray-tproxy.sh

**Назначение:** Комплексная диагностика работы Xray TProxy.

**Проверяет 11 ключевых точек:**

| # | Компонент | Что проверяется |
|---|-----------|-----------------|
| 1 | Процесс Xray | Запущен ли `xray` (`pgrep -a xray`) |
| 2 | Порты | Слушается ли порт 12345 (`ss -tuln`); для TProxy отсутствие в `ss` — норма |
| 3 | Конфигурация | Наличие `"tproxy": "tproxy"` в inbound и `"mark": 2` в sockopt (loop prevention) |
| 4 | nftables `xray_tproxy` | Наличие цепочки, `jump` из `prerouting`, bypass DNS (53) — только предупреждение, т.к. отдельного правила `dport 53` нет, bypass серверов, TProxy-правила, блокировка QUIC |
| 5 | nftables `xray_self` | Цепочка с `type route hook output priority mangle`, `meta mark 2 return`, маркировка `meta mark set 1` (трафик роутера); наличие устаревшей `fw4 xray_output` даёт предупреждение |
| 6 | Маршрутизация | `ip rule` с `fwmark 0x1 lookup 100`, в таблице 100 — `local default` |
| 7 | dnsmasq | Перенаправление на `127.0.0.1#5353` |
| 8 | Логи Xray | Последние 3 строки из `/tmp/log/xray-error.log` |
| 9 | Доступность сервера | HTTPS/ICMP проверка первого `address` из конфига (для Reality недоступность — норма) |
| 10 | DNS-тесты | Ответ от `127.0.0.1` |
| 11 | DNS-тесты | Ответ от `77.88.8.8` |

**Авто-рекомендации:** Скрипт выдаёт конкретные команды для исправления найденных проблем:

- `[FIX NFT]` — если TProxy-правила отсутствуют (предлагает `update-nft.sh`)
- `[FIX DNSMASQ]` — если dnsmasq не перенаправляет на Xray:5353

**Запуск:** Скрипт **не устанавливается** автоматически — его нужно скачать вручную:

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/diagnose-xray-tproxy.sh \
  -o /usr/share/xray/diagnose-xray-tproxy.sh && chmod +x /usr/share/xray/diagnose-xray-tproxy.sh
/usr/share/xray/diagnose-xray-tproxy.sh
```

---

### xray-sub-parser.py

**Назначение:** Парсинг подписки (URL или stdin) и преобразование серверов в outbound-ы Xray.

**Поддерживаемые форматы подписки:**

- **Base64 / VLESS URI** — список `vless://`-ссылок
- **JSON** — Happ / Sing-box / Karing / XPower (список профилей с `remarks` и `outbounds`)

**Поддерживаемые протоколы (VLESS URI):**

- VLESS over TCP
- VLESS over WebSocket (WS)
- VLESS over gRPC
- VLESS over HTTP/HTTP2
- VLESS over XHTTP (с поддержкой `extra` JSON)

**Поддерживаемые режимы безопасности:**

- None (без шифрования)
- TLS (с SNI, ALPN, fingerprint, allowInsecure)
- Reality (с `password` — он же `publicKey` в старых ядрах, shortId, spiderX)

**Аргументы CLI:**

| Аргумент | Описание |
|----------|----------|
| `--ua=STRING` | Включает унифицированный режим и задаёт User-Agent, по которому определяется формат подписки (обязателен в унифицированном режиме) |
| `--remarks=STRING` | Фильтр профилей по `remarks` (регистронезависимая подстрока, только для JSON-подписок) |

**Автоопределение формата по User-Agent** (`--ua`): маркеры `happ`, `singbox`, `sfa`, `sfi`, `sfm`, `sft`, `karing`, `xpower` → JSON; иначе → Base64/VLESS.

> ⚠️ Маркер `xpower` входит в список JSON-маркеров, поэтому значение по умолчанию `subscription.user_agent = "XPower/1.0"` включает JSON-режим. Если провайдер отдаёт Base64 для этого UA, укажите другой `--sub-ua`.

**Функции:**

1. **Логирование** — ошибки пишутся в syslog (ident: `xray-parser`) и stderr
2. **Нормализация тегов** — очистка названий серверов от спецсимволов, замена пробелов на `_`; для JSON-подписок дубликаты тегов получают суффикс `-2`, `-3`, …. Все теги прокси получают префикс `proxy-`: `selector` балансировщика и `subjectSelector` observatory сопоставляются **по префиксу**, поэтому тег вида `d` иначе подтянул бы служебные `direct`/`dns-out`
3. **Загрузка URL** — автоматическое скачивание, если входные данные — HTTP(S) URL (с проверкой на HTML-ошибку)
4. **Base64-декодирование** — умное определение (URL-safe, с/без padding), нужно ли декодировать
5. **Парсинг query-параметров**:
   - `encryption`, `flow`, `type` (транспорт)
   - `security`, `sni`, `fp`, `alpn`, `allowInsecure`
   - `pbk`, `sid`, `spx` (Reality)
   - `path`, `host`, `serviceName`, `mode`, `extra` (транспорт)
6. **Фильтрация заглушек** — пропускаются outbound-ы с `address` = `0.0.0.0` / `127.0.0.1` / `hole`, `port` = 1, UUID `00000000-0000-0000-0000-000000000000`; служебные `freedom`/`blackhole`/`dns` из JSON-подписки тоже пропускаются
7. **Признак `hole`** — если в подписке найден сервер с `address = "hole"` (в `settings.vnext[0].address` или в `settings.address` для `freedom`), в результат пишется `"hole": true` (генератор после этого собирает DIRECT-конфиг)

**Входные данные:** Чтение из stdin (URL подписки, base64-строка или JSON)

**Выходные данные:**

- с `--ua` — унифицированный объект `{"hole": bool, "outbounds": [...]}`
- без `--ua` (устаревший режим) — JSON-массив outbound-ов

**Коды возврата (режим `--ua`):**

| Код | Значение |
|-----|----------|
| `0` | разбор успешен, в том числе при `hole` |
| `2` | серверов не найдено и `hole` нет: формат не совпал с User-Agent, фильтр `--remarks` ничего не нашёл или все серверы оказались заглушками. Вызывающая сторона оставляет прежний `config.json` |
| `1` | ошибка входа (пустые данные, не удалось скачать подписку, не декодируется Base64) |

**Пример использования:**

```bash
# Унифицированный режим (используется update-xray.sh и установщиком)
cat subscription.txt | python3 xray-sub-parser.py --ua "OpenWrt-Xray/1.0" > parsed.json

# Устаревший режим: только Base64/VLESS, на выходе массив outbound-ов
cat subscription.txt | python3 xray-sub-parser.py > outbounds.json
```

**Пример выхода (для VLESS-outbound):**

```json
{
  "hole": false,
  "outbounds": [
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
          "password": "...",   // документированное имя; publicKey — прежнее
          "publicKey": "...",  // оставлено для совместимости
          "shortId": "...",
          "spiderX": "...",
          "fingerprint": "chrome"
        }
      }
    }
  ]
}
```

---

### xray-generate-config.py

**Назначение:** Генерация полного `config.json` для Xray на основе унифицированного вывода парсера.

**Входные данные:** унифицированный JSON `{"hole": bool, "outbounds": [...]}` (через stdin)

**Аргументы CLI:**

| Аргумент | Описание |
|----------|----------|
| `--output=PATH` | Путь к создаваемому конфигу (обязателен) |
| `--format=unified` | Для обратной совместимости; значение игнорируется (формат всегда унифицированный) |

> Аргументов выбора формата (`--format vless` / `--format json`), выбора сервера и `--remarks` **нет**: формат подписки определяет парсер, фильтр remarks передаётся парсеру. Выбор сервера не выполняется — все прокси из подписки попадают в балансировщик.

**Выходные данные:** Полный конфиг Xray с log, dns, inbounds, outbounds, routing и burstObservatory

**Ключевые функции:**

1. **Нормализация прокси-аутбаундов** — каждому outbound из подписки добавляется `streamSettings.sockopt` (`mark: 2`, `tcpKeepAliveInterval: 30`) и отключается Mux (`mux.enabled: false`)

2. **Балансировка (всегда, даже для одного прокси)**:
   - Все outbound-ы из подписки добавляются в конфиг
   - Создаётся балансировщик `tag: "balancer"` со стратегией `leastLoad` и `fallbackTag: "direct"`
     (`selector`/`subjectSelector` сопоставляются с тегами outbound-ов **по префиксу** — по
     xtls.github.io/config/routing.html, xtls.github.io/config/observatory.html)
   - **burstObservatory** на корневом уровне: `subjectSelector` = все прокси, `pingConfig` = `http://connectivitycheck.gstatic.com/generate_204`, `interval 1m`, `sampling 10`, `timeout 15s`, `httpMethod GET`
   - `leastLoad` выбирает outbound по данным observatory; если выбрать не удалось, используется `fallbackTag` → `direct`

3. **Режим "hole" (DIRECT-конфиг)**:
   - Если парсер вернул `"hole": true` или пустой список outbound-ов — генерируется конфиг без прокси
   - Весь трафик идёт напрямую (`direct`), реклама блокируется
   - Полезно при окончании срока подписки

4. **Базовая конфигурация:**
   - **Логирование:** `loglevel: "none"`, access/error логи в `/tmp/log/`
   - **DNS** (tag `dns-inbuilt`): `queryStrategy: "UseIPv4"`, `serveStale`, `serveExpiredTTL: 600`, `enableParallelQuery`, `disableFallbackIfMatch`
     - `hosts`: DoH-домены закреплены за IP (`common.dot.dns.yandex.net` → `77.88.8.1/8.8`, `cloudflare-dns.com` → `1.0.0.1/1.1.1.1`, `dns.nextdns.io` → `45.90.28.0/45.90.30.0`)
     - `servers`: Yandex DoH для `geosite:category-ru` (`expectedIPs: geoip:ru`, `skipFallback`), Cloudflare DoH, NextDNS DoH
   - **Inbound:**
     - `tproxy-in`: `dokodemo-door` (документированное имя протокола — `tunnel`), `0.0.0.0:12345`, `allowedNetwork: tcp,udp`, `followRedirect: true`, `sockopt.tproxy: "tproxy"`, сниффинг `http`/`tls` с `routeOnly: true`
     - `dns-local`: `dokodemo-door` (`tunnel`), `127.0.0.1:5353`, `tcp,udp` — приём DNS от dnsmasq

5. **Правила маршрутизации** (порядок важен, правила собираются из `settings.json → routing`):
   1. `inboundTag: ["dns-local"]` → `dns-out` (hijack во встроенный DNS)
   2. `doh_domains` → `direct` (чтобы DNS-запросы не уходили в прокси)
   3. `block_domains` (`geosite:category-ads`) → `block`
   4. NTP (порт 123/UDP) → `direct`
   5. QUIC (UDP/443) → `block` (VLESS+XTLS не поддерживает UDP)
   6. `direct_ips` (`geoip:ru`, `geoip:private`) → `direct`
   7. `direct_domains` (`geosite:private`, `category-browser`, `category-cdn-ru`, `category-mobile`, `category-ru`) → `direct`
   8. `proxy_domains` (`geosite:category-streaming`, `geosite:category-games`) → `balancer`
   9. `network: "tcp,udp"` → `balancer`
   
   В DIRECT-режиме правила 1–7 остаются, а вместо 8–9 добавляется одно: `network: "tcp,udp"` → `direct`.

   > **Важно:** QUIC/UDP-443 блокируется на двух уровнях:
   > 1. В nftables (до Xray) — только с LAN-интерфейса
   > 2. В Xray routing — для любого источника, включая трафик с самого роутера
   >
   > Это предотвращает ошибку `XTLS rejected UDP/443 traffic`

6. **Stream settings прокси** — `mark: 2` (по нему nftables распознаёт пакеты Xray и не зацикливает их), `tcpKeepAliveInterval: 30`; Mux отключён

   > Транспорт задаётся полем `network` (`tcp`/`ws`/`grpc`/`http`/`xhttp`). В актуальной документации Xray его заменило поле `method`; `network` принимается ядром как совместимый вид. Поля `xhttpSettings` (`path`, `host`, `mode`, `extra`) в документации не описаны.

7. **Freedom (direct) outbound** — `tag: "direct"`, `sockopt.domainStrategy: "UseIPv4"` для корректной работы в IPv4-only среде, `sockopt.mark: 2`

8. **Blackhole (block) outbound** — `tag: "block"`, `response.type: "http"`: возвращает HTTP 403 вместо глухого закрытия соединения, чтобы браузер сразу показывал ошибку, а не висел в таймауте

9. **DNS outbound** — `tag: "dns-out"`, протокол `dns`, правило `hijack` для `qType` `1,28`

**Режим без серверов:** DIRECT-конфиг создаётся только по явному сигналу `"hole": true`. Если парсер вернул ошибку (код 2), установщик и `update-xray.sh` прежний конфиг не меняют — DIRECT-режим больше не включается из-за сбоя разбора.

**Примеры использования:**

```bash
# Подписка → унифицированный JSON → config.json
python3 xray-sub-parser.py --ua "OpenWrt-Xray/1.0" < /tmp/sub.txt > /tmp/parsed.json
python3 xray-generate-config.py --output /etc/xray/config.json < /tmp/parsed.json

# JSON-подписка с фильтром профилей по remarks (фильтр передаётся парсеру!)
python3 xray-sub-parser.py --ua "happ/3.21" --remarks "best" < /tmp/sub.txt > /tmp/parsed.json
python3 xray-generate-config.py --output /etc/xray/config.json < /tmp/parsed.json
```

---

## 📁 Структура файлов

```
/etc/xray/
├── settings.json         # 🔥 ЕДИНЫЙ конфигурационный файл (см. ниже)
├── config.json           # Активная конфигурация Xray (генерируется автоматически)
└── state/
    ├── xray.zip.sha256sum
    ├── xray.dgst
    ├── geoip.dat.sha256sum
    └── geosite.dat.sha256sum

/usr/share/xray/
├── xray-generate-config.py
├── xray-sub-parser.py
├── update-xray.sh
├── update-nft.sh
├── net-check.sh          # Скрипт проверки интернета для LED (создаётся setup-led-status.sh)
├── diagnose-xray-tproxy.sh   # НЕ устанавливается автоматически — скачивается вручную
├── geoip.dat             # Гео-база IP-адресов
└── geosite.dat           # Гео-база доменов

/etc/init.d/xray          # Init-скрипт для управления службой
/etc/hotplug.d/iface/99-xray-autoupdate  # Автообновление при ifup wan

/tmp/log/                # создаётся установщиком и init.d (Xray не создаёт каталог сам)
├── xray-access.log       # Логи доступа Xray (ротация при > 512 KB)
├── xray-error.log        # Логи ошибок Xray (ротация при > 256 KB)
└── xray-update.log       # Логи обновлений и cron-прогонов (ротация при > 256 KB)

/tmp/xray_install.log     # Логи установки
/tmp/setup-wifi.log       # Логи настройки Wi-Fi
```

### settings.json — единый конфигурационный файл

Все настройки проекта хранятся в одном JSON-файле `/etc/xray/settings.json`:

```json
{
  "subscription": {
    "url": "https://your-subscription-url.com",
    "user_agent": "XPower/1.0",
    "remarks_filter": "",
    "domain_whitelist": [
      "router.freenternet.top"
    ]
  },
  "hwid": "a1b2c3d4e5f6...",
  "device_model": "Cudy WR3000S v1",
  "device_os": "OpenWrt",
  "ver_os": "25.12.4",
  "routing": {
    "domainStrategy": "IPOnDemand",
    "doh_domains": [
      "common.dot.dns.yandex.net",
      "cloudflare-dns.com",
      "dns.google",
      "dns.quad9.net",
      "doh.opendns.com",
      "dns.nextdns.io"
    ],
    "block_domains": [
      "geosite:category-ads"
    ],
    "direct_ips": [
      "geoip:ru",
      "geoip:private"
    ],
    "direct_domains": [
      "geosite:private",
      "geosite:category-browser",
      "geosite:category-cdn-ru",
      "geosite:category-mobile",
      "geosite:category-ru"
    ],
    "proxy_domains": [
      "geosite:category-streaming",
      "geosite:category-games"
    ]
  },
  "geo": {
    "geoip_url": "https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat",
    "geosite_url": "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"
  }
}
```

**Описание полей:**

| Путь | Тип | Описание |
|------|-----|----------|
| `subscription.url` | string | URL подписки |
| `subscription.user_agent` | string | User-Agent для запроса подписки (по нему же определяется формат подписки) |
| `subscription.remarks_filter` | string | Фильтр профиля по remarks (только для JSON-подписок) |
| `hwid` | string | Уникальный ID устройства (UUID без дефисов) |
| `device_model` | string | Модель устройства (из dmesg) |
| `device_os` | string | Операционная система (DISTRIB_ID) |
| `ver_os` | string | Версия ОС (DISTRIB_RELEASE) |
| `subscription.domain_whitelist` | array | Домены whitelist — сейчас только выводятся в лог генератора, на выбор сервера не влияют |
| `routing.domainStrategy` | string | Стратегия маршрутизации (по умолчанию `IPOnDemand`) |
| `routing.doh_domains` | array | DoH-домены → direct (защита от DNS-петель) |
| `routing.block_domains` | array | Домены для блокировки (реклама) |
| `routing.direct_ips` | array | IP-адреса напрямую (РФ + локальные) |
| `routing.direct_domains` | array | Домены напрямую (geosite-категории РФ) |
| `routing.proxy_domains` | array | Домены через прокси (стриминг, игры) |
| `geo.geoip_url` | string | URL geoip.dat |
| `geo.geosite_url` | string | URL geosite.dat |

> **Примечание:** Поля `routing.*` мержатся поверх значений по умолчанию: если ключ отсутствует в `settings.json`, используется дефолт из кода `xray-generate-config.py`; если присутствует — полностью заменяет список.
>
> **Примечание:** Настройки гостевой, IoT сетей и LAN (`--guest=*`, `--iot=*`, `--lan-ip=`) — это параметры установочного скрипта. Они применяются в UCI напрямую и не сохраняются в `settings.json`.

**Чтение/запись из командной строки:**

```bash
# Прочитать значение
jq -r '.subscription.url' /etc/xray/settings.json

# Изменить значение
jq --arg d 'new-domain.com' \
    'if .subscription.domain_whitelist | index($d) then . else .subscription.domain_whitelist += [$d] end' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

---

## 💡 Примеры использования

### Обновление подписки вручную

```bash
# Прочитать настройки из единого JSON-конфига
HWID=$(jq -r '.hwid' /etc/xray/settings.json)
SUB_URL=$(jq -r '.subscription.url' /etc/xray/settings.json)
SUB_UA=$(jq -r '.subscription.user_agent' /etc/xray/settings.json)

# Скачать подписку
curl -s -L -H "User-Agent: $SUB_UA" -H "x-hwid: $HWID" "$SUB_URL" > /tmp/sub.txt
```

**Единый пайплайн (формат подписки определяется автоматически по UA):**
```bash
python3 /usr/share/xray/xray-sub-parser.py --ua "$SUB_UA" < /tmp/sub.txt > /tmp/parsed.json \
  && python3 /usr/share/xray/xray-generate-config.py --output /etc/xray/config.json < /tmp/parsed.json
```

**С фильтром профилей по remarks (только JSON-подписки):**
```bash
python3 /usr/share/xray/xray-sub-parser.py --ua "$SUB_UA" --remarks "best" < /tmp/sub.txt > /tmp/parsed.json \
  && python3 /usr/share/xray/xray-generate-config.py --output /etc/xray/config.json < /tmp/parsed.json
```

**Проверить и перезапустить:**
```bash
xray run -test -config /etc/xray/config.json && /etc/init.d/xray restart
```

> Проще всего пересобрать всё (Xray, гео-базы, конфиг, nftables, перезапуск) одной командой: `/usr/share/xray/update-xray.sh`

### Проверка статуса

```bash
# Статус службы
/etc/init.d/xray status

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
/etc/init.d/sqm restart
```

### Добавление своего домена в whitelist

```bash
jq --arg d 'your-custom-domain.com' \
    'if .subscription.domain_whitelist | index($d) then . else .subscription.domain_whitelist += [$d] end' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

> **Текущее поведение:** `domain_whitelist` только читается генератором и выводится в лог (`→ Domain whitelist из settings.json: …`). На выбор сервера он не влияет: серверы не выбираются, все прокси подписки попадают в балансировщик.

### Настройка правил роутинга

Правила маршрутизации настраиваются через секцию `routing` в `settings.json`.
Все поля опциональны — при отсутствии используются значения по умолчанию.

**Добавить домен в обход прокси (direct):**

```bash
jq '.routing.direct_domains += ["domain:example.com"]' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

**Добавить сайт в прокси:**

```bash
jq '.routing.proxy_domains += ["domain:youtube.com"]' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

**Заблокировать домен:**

```bash
jq '.routing.block_domains += ["domain:doubleclick.net"]' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

**Изменить стратегию маршрутизации:**

```bash
jq '.routing.domainStrategy = "IPIfNonMatch"' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

> Поддерживаемые форматы: `"domain:example.com"`, `"geosite:category-ru"`, `"geoip:ru"`, `"geoip:private"`, `"ext:custom.dat:tag"`.

После любых изменений перегенерируйте конфиг: `/usr/share/xray/update-xray.sh`.

---

### Прогон тестов без устройства

Проверяет парсер и генератор на синтетических фикстурах: коды возврата, режим `hole`,
фильтр `remarks`, префиксы тегов и отсутствие коллизий с `direct`/`block`/`dns-out`.
Если доступен бинарь `xray`, дополнительно валидирует сгенерированные конфиги.

```bash
XRAY_BIN=/usr/bin/xray XRAY_LOCATION_ASSET=/usr/share/xray ./tests/run.sh
```

Без `XRAY_BIN` проверки ядром пропускаются, остальные выполняются всегда.

---

## 🔧 Troubleshooting

### Сайты не грузятся, но Xray запущен

1. **Запустите глубокую диагностику:**

   ```bash
   /usr/share/xray/diagnose-xray-tproxy.sh
   ```

2. **Проверьте bypass локальных адресов и цепочки nftables:**

   ```bash
   nft list chain inet fw4 xray_tproxy
   nft list chain inet xray_self output
   ```

   DNS-запросы клиентов адресованы роутеру и отсекаются правилом `ip daddr { …, 192.168.0.0/16, … } return`; отдельного правила `dport 53` нет. Убедитесь, что в цепочке есть `meta mark 2 return` (защита от петель) и правила `tproxy ip to 127.0.0.1:12345`.

3. **Проверьте dnsmasq:**

   ```bash
   uci show dhcp.@dnsmasq[0].server
   ```

   Должно быть: `127.0.0.1#5353`

4. **Автоматическое исправление (если диагностика выявила проблемы):**

   ```bash
   # Если TProxy правила отсутствуют:
   /usr/share/xray/update-nft.sh
   
   # Если dnsmasq не настроен:
   uci set dhcp.@dnsmasq[0].noresolv='1'
   uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
   uci commit && /etc/init.d/dnsmasq restart
   ```

### Ошибка: «Недостаточно места в /tmp (нужно минимум 20MB)»

Установщик и `update-xray.sh` требуют свободного места: 20 MB в `/tmp` (распаковка ZIP Xray) и 10 MB в `/`. Освободите место и повторите:

```bash
rm -rf /tmp/xray_install /tmp/xray_update /tmp/sub_raw.txt /tmp/parsed_outbounds.json
df -h /tmp /
```

### Конфиг не проходит валидацию

Проверьте вывод парсера (и stderr):

```bash
HWID=$(jq -r '.hwid' /etc/xray/settings.json)
SUB_URL=$(jq -r '.subscription.url' /etc/xray/settings.json)
SUB_UA=$(jq -r '.subscription.user_agent' /etc/xray/settings.json)

curl -s -L -H "User-Agent: $SUB_UA" -H "x-hwid: $HWID" "$SUB_URL" | \
  python3 /usr/share/xray/xray-sub-parser.py --ua "$SUB_UA" 2>&1 | tee /tmp/debug.json
```

В `/tmp/debug.json` ожидается объект `{"hole": …, "outbounds": […]}`. Если `outbounds` пуст — проверьте формат подписки: при несовпадении формата парсер пишет в stderr `Failed to parse JSON subscription` (см. определение формата по User-Agent).

### Geo-файлы не загружаются

Проверьте доступность источника из `settings.json` (`geo.geoip_url` / `geo.geosite_url`):

```bash
curl -I https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat
curl -I https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat.sha256sum
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
   /etc/init.d/network restart
   /etc/init.d/firewall restart
   /etc/init.d/dnsmasq restart
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
