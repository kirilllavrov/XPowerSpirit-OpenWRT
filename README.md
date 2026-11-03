# XPowerSpirit-OpenWRT

Прозрачное проксирование Xray на OpenWrt: установщик ставит Xray, настраивает TProxy через nftables, собирает `config.json` из подписки и дальше сам следит за обновлениями — ядра, гео-баз, конфигурации и собственных скриптов.

Работает в двух режимах: **основной роутер** (свой DHCP, проксируется весь трафик LAN и самого роутера) и **шлюз** за основным роутером (Keenetic и подобные). Дополнительно — изолированные гостевая и IoT-сети с ограничением скорости, диагностика всех компонентов одной командой.

## ✨ Что умеет

- **Установка одной командой** — Xray с GitHub с проверкой SHA2-256 по `.dgst`
- **TProxy на nftables** — прозрачно TCP и UDP, отдельные правила для LAN и для трафика роутера
- **Подписки** — JSON-подписки провайдера, фильтр по профилю (remarks), `fallback_all`
- **Балансировка** — пул узлов профиля (`leastLoad`) с проверкой доступности; отдельный пул для  видео и игр (`leastPing`)
- **Маршрутизация** — RU-зоны и `geoip:ru` напрямую, блокировка рекламы на уровне DNS, QUIC через прокси, DoH мимо прокси
- **Автообновление** — ядро и гео-базы по cron, конфигурация каждые 2 часа, догон по hotplug  при подъёме WAN
- **Самообновление скриптов** — из `latest.zip` с проверкой SHA-256 и откатом на прежнюю версию
- **Один источник настроек** — всё в `/etc/xray/settings.json`, значения по умолчанию в эталоне
  `/usr/share/xray/settings.default.json`
- **Диагностика** — `xpower-client status`, `traffic`, `doctor`

## 📦 Требования

- OpenWrt **25.12.x**, firewall `fw4` (nftables), ядро с `kmod-nft-tproxy` и `kmod-nft-socket`
- Свободно минимум 10 МБ в `/` и 20 МБ в `/tmp`
- Архитектура: x86-64/32, ARM64, ARMv7/6/5, MIPS/MIPSel, MIPS64, RISC-V, LoongArch
- Пакеты ставятся **заранее** — установщик их не тянет:

```bash
apk update
apk add curl ca-bundle nftables-json kmod-nft-tproxy kmod-nft-socket python3-light resolveip unzip jq
```

## 🚀 Установка

Скрипт запускается на роутере под root. Самый короткий вариант — из архива в Object Storage (скачивается `latest.zip`, проверяется SHA-256, установка идёт из проверенной копии):

```bash
cd /tmp
curl -fsSL https://storage.yandexcloud.net/xpower/OpenWRT/install.sh | sh -s -- \
  --sub=https://your-subscription-url.com
```

### Аргументы `install-openwrt-xray.sh` (и `install.sh`)

`install.sh` — загрузчик: скачивает `latest.zip`, проверяет SHA-256 и запускает установщик из архива, передавая ему **все аргументы как есть**. Поэтому набор флагов ниже — общий для обоих.

| Аргумент | Что задаёт | По умолчанию |
| --- | --- | --- |
| `--sub=URL` | URL подписки. **Обязателен**, без него установка останавливается | — |
| `--sub-ua=STRING` | `User-Agent` для запроса подписки (провайдер должен отдавать JSON) | `XPower/1.2` из `settings.default.json` |
| `--remarks=STRING` | Профиль подписки по полю remarks; при `fallback_all: true` отсутствие профиля не роняет установку | из `settings.json → subscription.remarks_filter` |
| `--mode=router\|gateway` | Режим: `router` — основным роутером; `gateway` — шлюзом за основным роутером | `router` |
| `--gw=IP` | IP основного роутера, только для `--mode=gateway` | определяется по маршруту по умолчанию |
| `--lan-ip=IP` | Адрес устройства в LAN | `192.168.1.1` |
| `--log=quiet\|normal\|debug` | Пресет журналирования: пишется в `settings.json → log.preset`, а в UCI выставляет `cronloglevel` (9 / 7 / 5) | `quiet` |
| `--guest=1\|0` | Гостевая сеть + SQM. **Несовместимо с `--mode=gateway`** | `0` |
| `--guest-ip=IP` | Адрес шлюза гостевой сети | `192.168.2.1` |
| `--guest-dl=Kbps` | Лимит скачивания для гостей; `0` — без ограничения | `5120` (5 Мбит/с) |
| `--guest-ul=Kbps` | Лимит загрузки для гостей; `0` — без ограничения | `5120` (5 Мбит/с) |
| `--iot=1\|0` | IoT-сеть + SQM. **Несовместимо с `--mode=gateway`** | `0` |
| `--iot-ip=IP` | Адрес шлюза IoT-сети | `192.168.3.1` |
| `--iot-dl=Kbps` | Лимит скачивания для IoT; `0` — без ограничения | `10240` (10 Мбит/с) |
| `--iot-ul=Kbps` | Лимит загрузки для IoT; `0` — без ограничения | `10240` (10 Мбит/с) |
| `--keep-xray` | Не перезаписывать Xray, уже встроенный в прошивку (пакет `xray-core` в squashfs). Нужен на устройствах с малым overlay: бинарь ~31 МБ съест почти весь раздел | выключен — установщик ставит свежий релиз с GitHub |

Особенности:

- SQM выключается только когда **оба** лимита сети равны нулю (`--guest-dl=0 --guest-ul=0`);
  если ноль только у одного направления, SQM работает, а это направление не ограничивается.
- Неизвестный аргумент не прерывает установку — печатается `[!] Неизвестный аргумент: …`.
- Сменить `--mode` на уже настроенной системе нельзя: установщик откажется и покажет, как сбросить
  `mode` в `settings.json`, если смена действительно нужна (переключение перекраивает сеть и может
  отрезать SSH).
- `--lan-ip`, `--guest-*`, `--iot-*` применяются напрямую в UCI и в `settings.json` не сохраняются;
  `--sub`, `--sub-ua`, `--remarks`, `--mode`, `--log` — сохраняются.

Пример с гостевой сетью:

```bash
cd /tmp
curl -fsSL https://storage.yandexcloud.net/xpower/OpenWRT/install.sh | sh -s -- \
  --sub=https://your-subscription-url.com \
  --mode=router \
  --guest=1
```

По завершении роутер перезагружается.

> Установщик, запущенный из распакованного архива (`sh /tmp/install-xray/install-openwrt-xray.sh`), 
> ставит скрипты из своего каталога; запущенный через `curl | sh` — скачивает их с GitHub.
> Wi-Fi и LED-индикация настраиваются отдельно: `setup-wifi-network.sh`, `setup-led-status.sh`.

### Настройка WiFi сетей `setup-wifi-network.sh`

Скрипт настраивает точки доступа на всех радио: основную сеть в `lan`, а гостевую и IoT — только если в `/etc/config/network` есть интерфейсы `guest` / `iot` (например, после установки с `--guest=1` / `--iot=1`). Шифрование всегда `sae-mixed` (WPA2+WPA3), PMF включён, у гостевой и IoT-сети — изоляция клиентов.

| Аргумент | Что задаёт | По умолчанию |
| --- | --- | --- |
| `--ssid=STRING` | SSID основной сети (1–32 символа) | `Home-WiFi` |
| `--pass=STRING` | Пароль основной сети (8–63 символа) | `HomeSecure123!` |
| `--ssid-guest=STRING` | SSID гостевой сети (1–32) | `Guest-WiFi` |
| `--pass-guest=STRING` | Пароль гостевой сети (8–63) | `GuestSecure123!` |
| `--ssid-iot=STRING` | SSID IoT-сети (1–32) | `IoT-WiFi` |
| `--pass-iot=STRING` | Пароль IoT-сети (8–63) | `IoTSecure123!` |

Все значения по умолчанию — рабочие пароли из скрипта: **смените их** при первом запуске.
Длина проверяется до применения — при нарушении скрипт выходит с ошибкой. Существующие
Wi-Fi-интерфейсы удаляются перед настройкой, `country` ставится `RU`, канал — `auto`.

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/setup-wifi-network.sh | sh -s -- \
  --ssid=Home-WiFi --pass=MySecurePass123 \
  --ssid-guest=Guest-WiFi --pass-guest=GuestPass456 \
  --ssid-iot=IoT-WiFi --pass-iot=IoTPass789
```

### Настройка led индикации `setup-led-status.sh`

Аргументов нет — скрипт настраивается через `/etc/xray/settings.json`.

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT/main/setup-led-status.sh | sh
```

Что делает и от чего зависит:

- Проверяет наличие светодиодов `white:wps` и `white:wan-online`; если их нет — выходит с ошибкой
  (рассчитан на Cudy WR3000S v1, для других моделей имена в `/sys/class/leds/` надо поправить).
- Удаляет **все** существующие LED-конфигурации (`system.@led`), затем создаёт две свои:
  `Xray_Status` (мигает по трафику интерфейса `lo`, то есть по работе прокси) и индикатор интернета
  через `net-check.sh` с ежесекундным cron.
- Адрес проверки берётся из `/etc/xray/settings.json → health.probe_url` — тот же, что у
  `burstObservatory`; если настройки нет, используется
  `https://connectivitycheck.gstatic.com/generate_204`.

## 🧰 xpower-client

Единая CLI на роутере

```bash
xpower-client <команда> [параметры]
```

| Команда | Что делает |
| --- | --- |
| `status` | Состояние: версия Xray, TProxy и policy routing, `config.json`, автообновление, узлы, трафик, внешний IP |
| `traffic` | Статистика по серверам из Xray API (`StatsService`): сколько отдано/принято каждым узлом, доля `proxy` и `direct` |
| `sub` | Состояние подписки: URL (частично скрыт), User-Agent, фильтр профиля, HWID, узлы, дата конфигурации |
| `settings` | Действующие настройки по блокам; чего нет в `settings.json` — берётся из эталона и помечается `(эталон)` |
| `test` | Быстрая проверка: интернет, DNS через `dnsmasq → Xray`, перехват TProxy |
| `doctor` | Полная диагностика `diagnose-xray-tproxy.sh` по пунктам (`[OK]` / `[WARN]` / `[FAIL]`) |
| `update` | Обновить Xray, гео-базы и конфигурацию — то же, что делает cron |
| `start` / `stop` / `restart` / `toggle` | Управление службой через `/etc/init.d/xray` |
| `logs` | Живой журнал Xray (`logread -f`), выход — Ctrl+C |
| `config` | Начало `config.json` для быстрой проверки |
| `proxy-list` | Список узлов из `config.json`: тег, протокол, адрес |
| `setup` | Переприменить правила nftables — после ручной правки `settings.json → tproxy`/`routing` |
| `help [команда]` | Общая справка или подробно по одной команде |

### Параметры команд

| Вызов | Что меняет |
| --- | --- |
| `status --full` | Развёрнутый вывод |
| `status --short` | Только главное |
| `status --no-net` | Не проверять внешний IP и доступность сети (быстро, работает без интернета) |
| `sub --full` | Показать URL подписки целиком (по умолчанию маскируется) |
| `sub set <URL>` | Записать новый URL подписки (`http://`, `https://` или `file://`) и сразу пересобрать `config.json` |
| `sub ua <User-Agent>` | Записать новый User-Agent и сразу пересобрать `config.json` |
| `update --config-only` | Только подписка → `config.json`, без обновления ядра и гео-баз |
| `doctor --download` | Скачать `diagnose-xray-tproxy.sh`, если его нет на устройстве, и запустить |

`--no-color` (или переменная окружения `NO_COLOR=1`) — общий флаг для любой команды: отключает цвета и значки, вывод остаётся чистым текстом для журналов и скриптов. `-h` и `--help` эквивалентны `help`.

### Коды возврата

`0` — успех, `1` — ошибка выполнения (например, нет подписки, не удалось обновить),
`2` — неверное использование (неизвестная команда или параметр).

### Примеры

```bash
xpower-client status                      # что происходит сейчас
xpower-client status --short --no-net     # быстро, без обращения в интернет
xpower-client traffic                     # кто сколько скачал через прокси и напрямую
xpower-client settings                    # что реально действует и что взято из эталона
xpower-client sub set https://new-sub.example/abc   # сменить подписку и пересобрать конфиг
xpower-client update --config-only         # только пересобрать config.json
xpower-client setup                        # после ручной правки портов/правил
xpower-client doctor                       # когда «интернет пропал»
```

## 🔄 Обновление

Всё делается автоматически, вмешательство нужно только для отката.

| Что | Когда | Чем |
| --- | --- | --- |
| Подписка → `config.json` | каждые 2 часа (`0 */2 * * *`) | `update-xray.sh --config-only` |
| Скрипты из `latest.zip` | ежедневно в 02:20 | `update-scripts.sh` |
| Ядро Xray + гео-базы | ежедневно в 02:30 | `update-xray.sh` |
| Всё сразу после подъёма WAN | hotplug `ifup` | `99-xray-autoupdate` |

Расписание живёт в `settings.json → update.cron`. Вручную:

```bash
xpower-client update                 # ядро + гео-базы + конфигурация
xpower-client update --config-only    # только пересобрать config.json из подписки

/usr/share/xray/update-scripts.sh --check      # есть ли новая версия скриптов
/usr/share/xray/update-scripts.sh              # применить
/usr/share/xray/update-scripts.sh --rollback   # вернуть предыдущие скрипты
```

Журналы: `/tmp/log/xray-update.log` (обновления), `/tmp/log/xray-scripts.log`
(самообновление), `/tmp/log/xray-sub.log` (подписка). `/tmp` — это tmpfs: после перезагрузки
файлы исчезают, важные события дублируются в syslog (`logread`).

**Настройки.**
Всё в `/etc/xray/settings.json`;
что реально действует — `xpower-client settings`.

## 📄 Лицензия

MIT — см. [LICENSE](LICENSE).

## 👤 Автор

- GitHub: [@kirilllavrov](https://github.com/kirilllavrov)
- Репозиторий: [XPowerSpirit-OpenWRT](https://github.com/kirilllavrov/XPowerSpirit-OpenWRT)

Вопросы и предложения — через GitHub Issues, pull requests приветствуются.
