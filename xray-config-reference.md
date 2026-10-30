# Справочник по базовой конфигурации Xray-core (по официальной русской документации)

> **Назначение файла.** Это выжимка из официальной русской документации Xray-core
> (<https://xtls.github.io/ru/config/>), к которой агент/разработчик обращается **до** правки
> `config.json`, правил маршрутизации/DNS или генератора конфигурации в этом проекте.
>
> **Правило работы с этим файлом.** Справочник — не источник истины, а *указатель* на него.
> Если поля нет в этом файле или в официальной документации — писать
> «В документации не упоминается, подтвердить нельзя.» и не додумывать.

## Паспорт справочника

| Параметр | Значение |
|---|---|
| Источник | <https://xtls.github.io/ru/config/> (русская версия, синхронизирована с последним релизом Xray-core) |
| Дата сверки | 2026-10-23 |
| Версия Xray, на которой проверялось поведение | 26.10.21 |
| Что проверялось рантаймом | `xray run -test -config` на конфигах, сгенерированных `xray-generate-config.py` |
| Связанные файлы | [xray-config-links.md](./xray-config-links.md) — карта ссылок; [AGENTS.md](./AGENTS.md) — правила работы агента |

Примечание из документации: русская документация синхронизируется с **последним релизом**, а
one-click-скрипты ставят версию `Latest`, поэтому часть полей на конкретном устройстве может
отсутствовать или вести себя иначе.

### Как обновлять справочник

1. Открыть нужную страницу из [карты ссылок](./xray-config-links.md).
2. Проверить, что это не SPA-заглушка «404» с кодом 200:
   `curl -sL <URL> | grep -o '<title>[^<]*</title>'`.
3. Сверить поля, значения по умолчанию и ограничения; обновить таблицу и дату сверки.
4. Ничего не добавлять «по памяти» и из примеров сообщества.

---

## 1. Верхний уровень конфигурации

```jsonc
{
  "env": {},
  "log": {},
  "api": {},
  "dns": {},
  "routing": {},
  "policy": {},
  "inbounds": [],
  "outbounds": [],
  "stats": {},
  "fakedns": {},
  "metrics": {},
  "observatory": {},
  "burstObservatory": {},
  "geodata": {},
  "version": {}
}
```

Формат JSON одинаков для клиента и сервера, отличается содержимое.
Если ни одно правило маршрутизации не совпало, используется **первый outbound**.

---

## 2. `log` — LogObject

Страница: <https://xtls.github.io/ru/config/log.html>

| Поле | Тип / значения | По умолчанию | Что делает и ограничения |
|---|---|---|---|
| `access` | string | нет (→ stdout) | Путь к журналу доступа. Специальное значение `none` отключает журнал |
| `error` | string | нет (→ stdout) | Путь к журналу ошибок. Специальное значение `none` отключает журнал |
| `loglevel` | `debug` \| `info` \| `warning` \| `error` \| `none` | `warning` | Уровень **только** журнала ошибок. На access-журнал влияет лишь значение `none` |
| `dnsLog` | bool | — | Писать DNS-запросы встроенных DNS-клиентов в access-журнал; они же всегда пишутся в error-журнал с уровнем `Info`. Запросы FakeDNS в access не пишутся |
| `maskAddress` | `quarter` \| `half` \| `full` \| свой формат `/N+/M` | выключено | Маскировка IP в логах; `/32` или `/128` — без маскировки, `/0` — `[Masked IPv4/IPv6]` |

Ограничения:

* Xray не выполняет **все** DNS-запросы через встроенные клиенты — `dnsLog` не означает «весь DNS».
* Настройки логирования применяются не сразу: на старте возможны записи от ещё не сконфигурированного логгера.
* Каталог для файлов журнала должен существовать — это поведение ОС, а не поле конфигурации
  (см. раздел «Практика этого проекта», п. 1).

---

## 3. `dns` — встроенный DNS-сервер

Страница: <https://xtls.github.io/ru/config/dns.html>

### 3.1. DnsObject

| Поле | Тип / значения | По умолчанию | Комментарий |
|---|---|---|---|
| `hosts` | `map{string: address}` или `map{string: [address]}` | — | Статические записи; имеет приоритет над серверами |
| `script` | string | — | Lua-скрипт обработки |
| `servers` | `[string \| DnsServerObject]` | — | Список серверов (см. 3.2) |
| `clientIp` | string | — | Подставляемый EDNS Client Subnet по умолчанию |
| `queryStrategy` | `UseIP` \| `UseIPv4` \| `UseIPv6` \| `UseSystem` | — | Какие типы записей запрашивать; глобальное значение **ограничивает** серверные |
| `disableCache` | bool | `false` | Отключает кэш DNS (кроме `localhost`) |
| `serveStale` | bool | `false` | Оптимистичное кэширование; работает только при включённом кэше |
| `serveExpiredTTL` | number (сек) | `0` (никогда не истекает) | Срок жизни оптимистичного кэша |
| `disableFallback` | bool | `false` | Отключает fallback-запросы |
| `disableFallbackIfMatch` | bool | `false` | Отключает fallback, если сработал приоритетный список доменов сервера |
| `enableParallelQuery` | bool | `false` | Параллельные запросы: динамическая группировка соседних серверов, гонка внутри группы, откат между группами |
| `useSystemHosts` | bool | `false` | Добавлять системный `/etc/hosts` |
| `tag` | string | — | Тег, которым запросы non-local режима входят в routing (`inboundTag`) |

Группировка при `enableParallelQuery` требует **полного** совпадения `clientIP`, `skipFallback`,
`queryStrategy`, `tag`, `domains`, `expectedIPs`, `unexpectedIPs` у **соседних** серверов.

### 3.2. DnsServerObject и схемы адресов

| Поле | Тип | По умолчанию | Комментарий |
|---|---|---|---|
| `id` | string | `""` | Идентификатор для Lua-скриптов |
| `address` | address | — | Схема адреса — см. ниже |
| `port` | number | `53` | Не действует для DOH/DOHL/DOQL — порт задаётся в URL |
| `domains` | `[string]` | — | Домены, обслуживаемые этим сервером; формат как в routing |
| `expectedIPs` | `[string]` | — | Возвращать IP только из списка; `*` в списке — вернуть исходный IP, если фильтр ничего не оставил |
| `unexpectedIPs` | `[string]` | — | Исключить IP из списка; `*` работает так же |
| `skipFallback` | bool | `false` | Пропускать сервер при fallback-запросах |
| `timeoutMs` | number | `4000` | Таймаут сервера (кроме `localhost`) |
| `finalQuery` | bool | `false` | Запрос к этому серверу — последняя попытка, fallback не запускается |
| `queryStrategy` | как глобальный | наследуется | Всегда ограничен глобальным значением |
| `tag`, `clientIP`, `disableCache`, `serveStale`, `serveExpiredTTL` | — | наследуются | Можно переопределить на уровне сервера |

Схемы значения `address`:

| Форма | Режим | Проходит через routing? |
|---|---|---|
| `"localhost"` | системный DNS | — |
| `"8.8.8.8"` | UDP DNS | да |
| `"tcp://host"` | DNS over TCP | да |
| `"tcp+local://host"` | TCPL (local) | нет, напрямую через Freedom |
| `"https://host:port/dns-query"` | DoH | да |
| `"https+local://host:port/dns-query"` | DOHL (local) | нет, напрямую через Freedom |
| `"quic+local://host:port"` | DOQL (local), порт 853 | нет, напрямую через Freedom |
| `"fakedns"` | FakeDNS | — |

Ключевое для прозрачного прокси:

* non-local запросы входят в routing с `inboundTag` = `dns.tag`; их резолвинг через
  `IPIfNonMatch`/`IPOnDemand` пропускается, чтобы не было петли;
* local-режимы (TCPL/DOHL/DOQL) в routing **не попадают** — их домены разрешает система;
* документация прямо рекомендует (особенно в Transparent Proxy) указывать IP доменных DNS-серверов
  в `hosts`, чтобы избежать петель.

---

## 4. `routing` — маршрутизация

Страница: <https://xtls.github.io/ru/config/routing.html>

### 4.1. RoutingObject

| Поле | Тип / значения | По умолчанию | Комментарий |
|---|---|---|---|
| `domainStrategy` | `AsIs` \| `IPIfNonMatch` \| `IPOnDemand` | `AsIs` | `IPOnDemand`: при встрече правила с `ip` домен разрешается встроенным DNS сразу; при ошибке используется исходный IP. `IPIfNonMatch`: второй проход после того, как ни одно правило не сработало |
| `rules` | `[RuleObject]` | — | Правила применяются по порядку |
| `script` | string | — | Lua-скрипт |
| `balancers` | `[BalancerObject]` | — | Балансировщики |

Особенности: результаты резолва содержат и IPv4, и IPv6; правило считается сработавшим, если
подошёл хотя бы один IP. Если одновременно доступны исходный домен и домен из sniffing, приоритет
у домена из sniffing. Роутинг не меняет фактический адрес назначения.

### 4.2. RuleObject

Условия (если указано несколько — должны выполняться **одновременно**):

`domain`, `ip`, `port`, `sourcePort`, `localPort`, `network`, `sourceIP`, `localIP`, `user`,
`vlessRoute`, `inboundTag`, `protocol`, `attrs`, `process`.
Действие: `outboundTag` **или** `balancerTag` (если указаны оба — используется `outboundTag`),
плюс `ruleTag` и `webhook {url, deduplication, headers}`.

| Условие | Формат |
|---|---|
| `domain` | строка без префикса = подстрока; `regexp:`; `domain:` (домен и поддомены, рекомендуется); `keyword:`; `full:`; `dotless:`; `geosite:name`; `ext:file:tag` |
| `ip` | IP, CIDR, `geoip:xx`, `geoip:private`, `ext:file:tag`; инверсия `!` (несколько отрицаний — AND, положительные и совокупность отрицаний — OR) |
| `port` / `sourcePort` / `localPort` | `a`, `"a-b"`, `"53,443,1000-2000"` |
| `network` | `tcp` \| `udp` \| `tcp,udp`; `"tcp,udp"` — catch-all, ставится последним как «по умолчанию» |
| `inboundTag` | массив тегов inbound |
| `protocol` | `http` (только 1.0/1.1) \| `tls` (1.0–1.3) \| `quic` \| `bittorrent`; требует `sniffing` |

`geosite:` в стандартной поставке содержит, например, `category-ads`, `category-ads-all`,
`geolocation-cn`, `geolocation-!cn`, `tld-cn`, `cn`, `apple`, `google`, `microsoft`, `facebook`,
`twitter`, `telegram`, `category-ai-cn`, `category-ai-!cn`. Набор зависит от версии данных;
облегчённый `geoip.dat` содержит только `cn`, `ir`, `ru`.

### 4.3. BalancerObject и StrategyObject

| Поле | Тип / значения | Комментарий |
|---|---|---|
| `tag` | string | Сопоставляется с `balancerTag` правила |
| `selector` | `[string]` | **Префиксное** сопоставление с тегами outbound: `["a"]` захватит `a` и `ab` |
| `fallbackTag` | string | Используется, если по данным наблюдения все outbound недоступны |
| `strategy.type` | `random` (по умолчанию) \| `roundRobin` \| `leastPing` \| `leastLoad` | |
| `strategy.settings` | только для `leastLoad` | `expected`, `maxRTT`, `tolerance`, `baselines`, `costs[{regexp, match, value}]` |

* `random`/`roundRobin` опционально используют observatory: при заданном `fallbackTag` узлы,
  помеченные недоступными, исключаются (узлы без данных считаются доступными).
* `leastPing`/`leastLoad` **обязаны** работать с observatory; узлы без данных наблюдения
  исключаются. Если всё недоступно и `fallbackTag` не задан — используется outbound по умолчанию.
* `costs[].value`: чем больше значение, тем меньше вероятность выбора узла.
* `expected` — число выбираемых «лучших» узлов, трафик распределяется между ними случайно.

---

## 5. `policy` — локальные политики

Страница: <https://xtls.github.io/ru/config/policy.html>

`level`: `map{string: LevelPolicyObject}`, `system`: `SystemPolicyObject`.

| Поле уровня | По умолчанию | Смысл |
|---|---|---|
| `handshake` | `60` (сек) | Лимит времени на рукопожатие |
| `connIdle` | `300` (сек) | Лимит простоя соединения |
| `uplinkOnly` | `1` (сек) | Ожидание после закрытия исходящего канала |
| `downlinkOnly` | `1` (сек) | Ожидание после закрытия входящего канала |
| `statsUserUplink` / `statsUserDownlink` | `false` | Учёт трафика пользователей уровня |
| `statsUserOnline` | `false` | Учёт онлайна (активность за 20 с) |
| `bufferSize` | `0` на ARM/MIPS, `4` на ARM64/MIPS64, `512` на остальных (КБ) | Внутренний буфер запроса; переопределяется `XRAY_RAY_BUFFER_SIZE` (в МБ). Для UDP переполнение = отбрасывание данных |

`SystemPolicyObject`: `statsInboundUplink`, `statsInboundDownlink`, `statsOutboundUplink`,
`statsOutboundDownlink`.

---

## 6. Наблюдение за подключениями

Страница: <https://xtls.github.io/ru/config/observatory.html>

`observatory` (фоновый): `subjectSelector` (префиксное сопоставление тегов), `probeUrl`,
`probeInterval`, `enableConcurrency` — при `true` все outbound проверяются одновременно,
при `false` — по очереди с паузой `probeInterval` после каждого.

`burstObservatory` (пакетный): `subjectSelector`, `pingConfig`:

| Поле | По умолчанию | Комментарий |
|---|---|---|
| `destination` | `https://connectivitycheck.gstatic.com/generate_204` | URL должен возвращать HTTP 204 |
| `connectivity` | `""` | Проверка локальной сети, выполняется только при неудаче `destination` |
| `interval` | `1m` | Средний интервал на каждый outbound; минимум `10s` (меньшее значение заменяется) |
| `sampling` | `10` | Сколько последних результатов хранить |
| `timeout` | `5s` | Таймаут проверки; формат число + `ns/us/ms/s/m/h` |
| `httpMethod` | `HEAD` | Примеры значений: `HEAD`, `GET` |

Документация предупреждает: **в режиме прозрачного проксирования** запрос проверки может быть
перехвачен прокси и снова попасть в Xray; нужны обход по IP, cgroup/pid-маршрутизация или URL,
попадающий под правило прямого подключения.

Принцип: проверка планируется на цикл `interval * sampling`; узел помечается неисправным за
1–2 цикла, восстанавливается после первой успешной проверки.

---

## 7. `inbounds` — InboundObject

Страница: <https://xtls.github.io/ru/config/inbound.html>

| Поле | Тип / значения | По умолчанию | Комментарий |
|---|---|---|---|
| `listen` | address | `0.0.0.0` | `"::"` = одновременно IPv6+IPv4; поддерживается Unix domain socket (`/dev/shm/x.sock`, `@`/`@@` для abstract, `,0666` для прав) |
| `port` | number \| `"env:VAR"` \| string | — | Диапазоны `"5-10"`, `"11,13,15-17"`; слушать большой диапазон — дорого, лучше iptables |
| `protocol` | `tunnel` \| `http` \| `shadowsocks` \| `socks` \| `vless` \| `vmess` \| `trojan` \| `wireguard` \| `hysteria` \| `masque` \| `tun` | — | |
| `settings` | InboundConfigurationObject | — | Зависит от протокола |
| `streamSettings` | StreamSettingsObject | — | См. раздел 9 |
| `tag` | string | — | Должен быть уникальным среди всех тегов |
| `sniffing` | SniffingObject | — | Обнаружение трафика |

### 7.1. SniffingObject

| Поле | Значения | По умолчанию | Комментарий |
|---|---|---|---|
| `enabled` | bool | — | Включает обнаружение |
| `destOverride` | `["http" \| "tls" \| "quic" \| "fakedns"]` | — | Заменять целевой адрес обнаруженным |
| `metadataOnly` | bool | — | Только метаданные соединения; отключает все снифферы кроме `fakedns` |
| `domainsExcluded` | `[string]` | — | Не заменять адрес для этих доменов (пример из документации: push iOS, Mijia) |
| `ipsExcluded` | `[string]` | — | Не заменять эти IP |
| `routeOnly` | bool | `false` | Только использовать домен для маршрутизации, адрес остаётся IP. Требует `destOverride` |

Ограничение: браузеры с ECH дают только домен внешнего Client Hello.

### 7.2. Tunnel (Dokodemo-Door)

Страница: <https://xtls.github.io/ru/config/inbounds/tunnel.html>

Имя протокола в документации — `tunnel`; «Dokodemo door» — прежнее название.

| Поле | Значения | По умолчанию | Комментарий |
|---|---|---|---|
| `allowedNetwork` | `tcp` \| `udp` \| `tcp,udp` | `tcp` | |
| `rewriteAddress` | address | `localhost` | Куда перенаправлять |
| `rewritePort` | number `[0,65535]` | `0` → порт прослушивания | |
| `portMap` | `map[string]string` | — | Соответствие локальных портов удалённым адресам |
| `followRedirect` | bool | `false` | Распознавать данные, перенаправленные iptables (TProxy) |
| `userLevel` | number | `0` | Уровень политик |

Для прозрачного прокси документация отсылает к руководству TProxy уровня 2.

---

## 8. `outbounds` — OutboundObject

Страница: <https://xtls.github.io/ru/config/outbound.html>

| Поле | Значения | Комментарий |
|---|---|---|
| `sendThrough` | address | Исходный адрес |
| `protocol` | `blackhole` \| `dns` \| `freedom` \| `http` \| `loopback` \| `shadowsocks` \| `socks` \| `trojan` \| `vless` \| `vmess` \| `hysteria` \| `wireguard` \| `masque` | |
| `settings` | OutboundConfigurationObject | Зависит от протокола |
| `tag` | string | Первый outbound в списке — основной |
| `streamSettings` | StreamSettingsObject | Раздел 9 |
| `mux` | MuxObject | `enabled` (по умолчанию `false`), `concurrency` (1–128, по умолчанию 8), `xudpConcurrency` (1–1024), `xudpProxyUDP443` (`reject` по умолчанию \| `allow` \| `skip`); отрицательное значение — не использовать Mux |
| `targetStrategy` | `AsIs` \| `UseIP` \| `UseIPv6v4` \| `UseIPv6` \| `UseIPv4v6` \| `UseIPv4` \| `ForceIP` \| … | Стратегия резолва **цели проксируемого запроса**; резолв адреса самого прокси-сервера — `sockopt.domainStrategy` |

### 8.1. VLESS

Страница: <https://xtls.github.io/ru/config/outbounds/vless.html>

Документированный вид клиентских `settings` (плоский):

| Поле | Тип | Комментарий |
|---|---|---|
| `address` | address | Домен / IPv4 / IPv6 сервера |
| `port` | number | |
| `id` | string | Любая строка < 30 байт или UUID; соответствие описано стандартом VLESS UUID Mapping |
| `encryption` | string | Не может быть пустым; для отключения явно `"none"` |
| `flow` | string | Например `xtls-rprx-vision` |
| `level` | number | Уровень политик |
| `reverse` | struct | Обратный прокси |

Предупреждение документации: VLESS нужно использовать с внешней защитой транспорта;
`security: "none"` допустим только для private-адреса в доверенной сети или при VLESS Encryption.

### 8.2. Freedom

Страница: <https://xtls.github.io/ru/config/outbounds/freedom.html>

`settings`: `redirect`, `userLevel`, `fragment {packets, length, interval}`,
`noises [{type, packet, delay}]`, `proxyProtocol`, `finalRules [{action: allow|block, network, port, ip, blockDelay}]`.

Поля `domainStrategy` в `settings` **нет**: стратегия резолва Freedom задаётся
`sockopt.domainStrategy`, и перед проверкой `finalRules` домен разрешается именно по ней;
блокировка хотя бы одного IP блокирует весь запрос.

### 8.3. Blackhole

Страница: <https://xtls.github.io/ru/config/outbounds/blackhole.html>

`settings.response.type`: `none` (по умолчанию — просто закрыть соединение) или `http`
(вернуть простой пакет HTTP 403 и закрыть).

### 8.4. DNS (outbound)

Страница: <https://xtls.github.io/ru/config/outbounds/dns.html>

Только традиционный DNS (UDP/TCP); DoH/DoT/DoQ к этому outbound не применимы.

| Поле | Значения | Комментарий |
|---|---|---|
| `rewriteNetwork` | `tcp` \| `udp` | Изменить транспорт запроса |
| `rewriteAddress` | address | Изменить адрес DNS-сервера |
| `rewritePort` | number | Изменить порт |
| `userLevel` | number | По умолчанию `0` |
| `rules` | `[RuleObject]` | Сопоставление по `qType` и `domain` |

`RuleObject`: `action` (`direct` \| `hijack` \| `drop` \| `return`), `qType`
(number или строка: `"28"`, `"5-10"`, `"11,13,15-17"`), `rCode` (`0..65535`, только для `return`),
`domain` (формат как в routing). Условия внутри правила объединяются по AND.

Правило по умолчанию при отсутствии совпадений: A и AAAA → во встроенный DNS, остальные типы →
пустой ответ с RCODE `0`. `hijack` поддерживает только A и AAAA.

---

## 9. `streamSettings` — транспорт

Страница: <https://xtls.github.io/ru/config/transport.html>

```jsonc
"streamSettings": {
  "method": "raw",              // способ передачи
  "rawSettings": {},            // настройки выбранного способа
  "xhttpSettings": {},
  "kcpSettings": {},
  "grpcSettings": {},
  "wsSettings": {},
  "httpupgradeSettings": {},
  "hysteriaSettings": {},
  "masqueSettings": {},
  "security": "none",           // защита транспорта
  "realitySettings": {},
  "tlsSettings": {},
  "finalmask": {},              // дополнительно
  "sockopt": {}
}
```

* `method`: `raw` (по умолчанию) \| `xhttp` \| `mkcp` \| `grpc` \| `websocket` \| `httpupgrade` \| `hysteria` \| `masque`.
* `security`: `none` (по умолчанию) \| `reality` \| `tls`.
* REALITY только с `raw`, `xhttp`, `grpc`.
* TLS — с `raw`, `xhttp`, `mkcp`, `grpc`, `websocket`, `httpupgrade`, `hysteria`, `masque`.
* `hysteria` и `masque` требуют TLS; REALITY с ними не поддерживается; `websocket`/`httpupgrade`/`mkcp` с REALITY не поддерживаются.

### 9.1. TLSObject (`tlsSettings`)

Ключевые поля: `serverName` (для IP SNI не отправляется; пусто → берётся `address`), `alpn`
(по умолчанию `["h2", "http/1.1"]`), `allowInsecure` (по умолчанию `false`, только клиент),
`fingerprint` (по умолчанию `chrome`; `unsafe` — обычный Go TLS), `minVersion`, `maxVersion`,
`cipherSuites`, `curvePreferences`, `verifyPeerCertByName`, `rejectUnknownSni`, `useSystemCA`,
`disableSystemRoot`, `enableSessionResumption`, `pinnedPeerCertSha256`, `certificates`,
`echConfigList`, `echSockopt`, `masterKeyLog`.

### 9.2. REALITYObject

Сервер: `show`, `target`, `xver`, `serverNames`, `privateKey`, `minClientVer`, `maxClientVer`,
`maxTimeDiff`, `shortIds`, `mldsa65Seed`, `limitFallbackUpload`/`limitFallbackDownload`.

Клиент:

| Поле | Обязательность | Комментарий |
|---|---|---|
| `serverName` | — | Одно из серверных `serverNames`; IP → Client Hello без SNI |
| `fingerprint` | **обязательно** | `unsafe` не поддерживается |
| `shortId` | — | До 16 hex-символов, длина **чётная**; короче — дополнится нулями справа |
| `password` | **обязательно** | Публичный ключ сервера (`xray x25519 -i "private"`). **Ранее поле называлось `publicKey`** |
| `mldsa65Verify` | — | Публичный ключ проверки подписи |
| `spiderX` | — | Начальный путь краулера |

### 9.3. WebSocket (`wsSettings`)

`acceptProxyProtocol`, `path` (по умолчанию `"/"`; `?ed=2560` включает Early Data),
`host`, `headers` (только клиент), `heartbeatPeriod`.
Приоритет хоста на клиенте: `host` > `headers` > `address`.
Документация рекомендует переходить на XHTTP.

### 9.4. gRPC (`grpcSettings`)

`authority`, `serviceName`, `user_agent`, `multiMode`, `idle_timeout`, `health_check_timeout`,
`permit_without_stream`, `initial_windows_size`.

### 9.5. RAW (`rawSettings`)

`acceptProxyProtocol`, `header`:
`{type: "none"}` или `{type: "http", request{version, method, path, headers}, response{version, status, reason, headers}}`.

### 9.6. XHTTP

Страница <https://xtls.github.io/ru/config/transports/xhttp.html> — это статья
«XHTTP: Beyond REALITY» со ссылкой на внешний материал; **поля `xhttpSettings`
(`path`, `host`, `mode`, `extra`) в документации не описаны.**

---

## 10. `sockopt` — SockoptObject

Страница: <https://xtls.github.io/ru/config/transports/sockopt.html>

Полный список документированных полей: `mark`, `tcpMaxSeg`, `tcpFastOpen`, `tproxy`,
`domainStrategy`, `happyEyeballs`, `dialerProxy`, `acceptProxyProtocol`, `trustedXForwardedFor`,
`tcpKeepAliveInterval`, `tcpKeepAliveIdle`, `tcpUserTimeout`, `tcpcongestion`, `interface`,
`V6Only`, `tcpWindowClamp`, `tcpMptcp`, `addressPortStrategy`, `customSockopt`.

| Поле | Значения | Комментарий |
|---|---|---|
| `mark` | number | `SO_MARK` для исходящих соединений при ненулевом значении; только Linux, нужен `CAP_NET_ADMIN` |
| `tproxy` | `redirect` \| `tproxy` \| `off` | Прозрачное проксирование (Linux): `redirect` — TCP, `tproxy` — TCP и UDP |
| `domainStrategy` | `AsIs` \| `UseIP` \| `UseIPv4` \| … | Резолв адреса прокси-сервера / цели Freedom через встроенный DNS |
| `tcpKeepAliveInterval`, `tcpKeepAliveIdle`, `tcpUserTimeout` | number | Параметры TCP (кроме них, в разделе нет `tcpNoDelay`) |

Опасное правило из документации: в `tunnel` при `followRedirect: true` и пустом `tproxy`
значение `tproxy` автоматически ставится в `"redirect"`.

---

## 11. `env`, `geodata`, `stats`, `metrics`, `api`

**`env`** (<https://xtls.github.io/ru/config/env.html>): набор «имя → строка»; записывается в
окружение процесса после чтения всех файлов конфигурации. Нельзя задать через `env`:
`XRAY_JSON_STRICT`, `XRAY_LOCATION_CONFIG`, `XRAY_LOCATION_CONFDIR`, `GOGC`, `GOMEMLIMIT`,
`GOMAXPROCS`, `GOTRACEBACK`.
`XRAY_LOCATION_ASSET` — каталог `geoip.dat`/`geosite.dat`; при отсутствии поиск идёт в
`./`, `/usr/local/share/xray`, `/usr/share/xray`.

**`geodata`** (<https://xtls.github.io/ru/config/geodata.html>): `cron` (5 полей, локальный TZ),
`outbound` (тег для загрузки), `assets [{url (HTTPS), file}]` — файл должен уже существовать в
каталоге ресурсов; при неудачной перезагрузке выполняется откат. «На устройствах с малым объёмом
памяти используйте с осторожностью».

**`stats`** (<https://xtls.github.io/ru/config/stats.html>): пустой объект включает статистику;
метрики (`user>>>[email]>>>traffic>>>uplink`, `inbound>>>[tag]>>>…`, `outbound>>>[tag]>>>…`)
собираются только для включённых в `policy` счётчиков; без `email` пользовательская статистика
не собирается.

**`metrics`** (<https://xtls.github.io/ru/config/metrics.html>): `tag` (тег outbound для метрик),
`listen` (например `127.0.0.1:11111`).

**`api`** (<https://xtls.github.io/ru/config/api.html>): `tag`, `listen`, `services`
(`HandlerService`, `LoggerService`, `StatsService`, `RoutingService`, …). С v1.8.12 есть
упрощённый режим только с `ApiObject`; при нём трафик API-входов не учитывается в статистике.
Гибридный режим требует inbound с `rewriteAddress: "127.0.0.1"` и правила
`{"inboundTag": ["api"], "outboundTag": "api"}`.

---

## 12. Что в русской документации НЕ описано

Проверено 2026-10-23 на перечисленных страницах. Для этих сущностей действует правило:
«В документации не упоминается, подтвердить нельзя.»

| Сущность | Статус |
|---|---|
| `streamSettings.network` (`tcp`/`ws`/`grpc`/`http`) | не описано; документировано `streamSettings.method`. На Xray 26.10.21 `network` принимается (совместимость), но это не документированное поведение |
| `sockopt.tcpNoDelay` | отсутствует в списке полей SockoptObject |
| `settings.domainStrategy` у Freedom и direct-подобных outbound | нет; документировано `sockopt.domainStrategy` |
| `realitySettings.publicKey` | переименовано в `password`; `publicKey` упомянуто только как прежнее имя |
| `settings.vnext[].address/port/users[]` у VLESS | на странице VLESS документирован плоский вид `settings.address/port/id/...` |
| `xhttpSettings.path/host/mode/extra` | полей нет — страница XHTTP является статьёй |
| Правило DNS-outbound с ключом `qtype` (нижний регистр) | документировано `qType` |
| Название протокола inbound `dokodemo-door` | документировано `tunnel` («Dokodemo door» — прежнее название) |

---

## 13. Практика этого проекта (сверка)

Что проект использует и чем это подтверждается:

| Использование | Где в проекте | Как в документации |
|---|---|---|
| `log.loglevel: "none"` + файлы access/error; каталог создают установщик и `init.d` | [xray-generate-config.py](./xray-generate-config.py), [install-openwrt-xray.sh](./install-openwrt-xray.sh) | `access`/`error`/`loglevel` — подтверждено; сам ядро каталог не создаёт. С 2026-10-30 значения приходят из пресета `log.preset`: `quiet` → `none`/`none`/`none`, `normal` → `warning`+error-файл, `debug` → `info`+access-файл (все значения документированы) |
| `dns` c `hosts`, `queryStrategy`, `serveStale`, `serveExpiredTTL`, `disableFallbackIfMatch`, `enableParallelQuery` | [xray-generate-config.py](./xray-generate-config.py) | подтверждено |
| `servers` в режиме `https+local://` (DOHL) + `domains`, `expectedIPs`, `skipFallback` | там же | подтверждено; DOHL не проходит routing |
| `routing.domainStrategy: "IPOnDemand"`, правила `domain`/`ip`/`port`/`network`/`inboundTag` | [build_rules](./xray-generate-config.py) | подтверждено |
| `balancers[].selector` + `leastLoad` + `fallbackTag`; теги прокси с префиксом `proxy-` | [build_balancer](./xray-generate-config.py), [proxy_tag](./xray-sub-parser.py) | подтверждено; `selector` и `subjectSelector` **префиксные** |
| `burstObservatory.pingConfig` (`destination`, `GET`, `1m`, `10`, `15s`) | [build_burst_observatory](./xray-generate-config.py) | подтверждено; предупреждение о перехвате TProxy |
| inbound `tunnel` (в конфиге — `dokodemo-door`) + `sockopt.tproxy` + `sniffing.routeOnly` | [base_config](./xray-generate-config.py) | подтверждено; `dokodemo-door` — прежнее имя протокола |
| `blackhole` c `response.type: "http"` | [make_block_outbound](./xray-generate-config.py) | подтверждено |
| DNS-outbound: `action: "hijack"`, `qType: "1,28"` | [build_dns_outbound](./xray-generate-config.py) | подтверждено |
| Freedom: `sockopt.domainStrategy: "UseIPv4"` | [make_direct_outbound](./xray-generate-config.py) | подтверждено |
| REALITY: `password` (+ `publicKey` для старых ядер) | [parse_vless_uri](./xray-sub-parser.py) | подтверждено; `publicKey` — прежнее имя |

### Проверено на живом стенде (OpenWrt 25.12 в контейнере)

Стенд: OpenWrt 25.12 (procd, fw4), два клиента — LAN и сам роутер, настоящий VLESS-сервер.
Подтверждено: установка проходит целиком, после перезагрузки Xray стартует сам, TProxy
проксирует и LAN, и трафик роутера, DNS через встроенный модуль работает, `hole` уводит
в DIRECT, сбой разбора подписки оставляет прежний конфиг.

Найдено и исправлено на стенде:

* **Трафик роутера не проксировался.** Цепочка `fw4 output` имеет `type filter`, mark в ней
  не влияет на маршрутизацию. По официальному руководству TProxy
  (<https://xtls.github.io/ru/document/level-2/tproxy.html>) нужна отдельная цепочка
  `type route hook output priority mangle` — она теперь и используется (`inet xray_self`).
* `paste` отсутствует в busybox OpenWrt — bypass-DNS собирался пустым и правило не добавлялось;
  заменено на `tr` + проверка правила после применения.
* Guard `LAN_IF` был нерабочим (`|| echo "br-lan"` всегда давал непустое имя) — теперь проверяется
  существование интерфейса через `ip link show`.
* Диагностика давала ложные `FAIL`/`WARN` на формате вывода nft (`meta mark 0x00000002`)
  и на имени таблицы в `ip rule` (`lookup xray` вместо `lookup 100`).
* **Архитектура определялась по `uname -m` с fallback на x86-64.** На MIPS-роутерах
  (MT7621/ath79) и ARMv6 это ставило x86-64 бинарь; `update-xray.sh` при этом заменял рабочий
  бинарь неработающим. Теперь используется `DISTRIB_ARCH` из `/etc/openwrt_release`
  (`mips_*`/`mipsel_*` — критично, `uname -m` их не различает), неизвестная архитектура
  останавливает установку.

### Проверено на реальной подписке (JSON, 141 outbound)

Подписка провайдера с одним устройством (HWID), формат JSON, 44 профиля. Итог: установка,
генерация и проксирование работают; egress отличается от прямого (57.129.105.68 против
46.158.58.5), DNS идёт через встроенный модуль (DOHL), LAN-клиент и сам роутер — через общий
`balancer`.

Найдено на реальных данных и исправлено:

* **`loopback`-outbound'ы попадали в балансировщик.** В шаблонной подписке есть outbound-ы
  `{"protocol": "loopback", "settings": {"inboundTag": …}}` — это внутренняя петля, а не сервер:
  при выборе она возвращала бы трафик в маршрутизацию. Исключены и в парсере, и в генераторе
  (защита от ручного унифицированного входа).

Наблюдения для эксплуатации:

* **135 узлов в балансировщике = постоянный фон проверок.** `burstObservatory` пингует каждый
  субъект раз в минуту: на простаивающем роутере это ~50 новых TCP-соединений в минуту к
  серверам подписки, RSS Xray ~64 МБ против ~10 МБ на малом конфиге. На роутере с 128 МБ
  памяти и лимитом «одно устройство» это заметно; помогает фильтр `--remarks` (например,
  «Германия» → 1 узел, конфиг 5.4 КБ вместо 147 КБ).
* **Проверочные домены IP вынесены в geosite-категорию `category-ipcheck`.**
  В подписке/геобазе `ifconfig.me` и `api.ipify.org` попадали в `direct` случайно, через
  `geosite:category-cdn-ru` (проверка по категориям: `category-browser`, `category-mobile`,
  `category-ru`, `private` → прокси, `category-cdn-ru` → direct). Поведение верное по смыслу
  (иначе провайдер увидит IP прокси и определит VPN), но держалось на побочном эффекте чужой
  категории, меняющейся вместе с геобазой. Список перенесён в геофайл — категория
  `category-ipcheck`; генератор ставит правило `geosite:category-ipcheck → direct` **раньше**
  блокировок и всех прочих правил (`2ip.ru`, `ifconfig.me`, `ipify.org`, `ipinfo.io`, `ip.sb`,
  `ident.me`, `ipapi.co`, `ipwho.is`, `checkip.amazonaws.com`, `wtfismyip.com`, `myip.ipip.net`).
  Наличие категории проверяется по `geosite.dat`: неизвестная категория делает конфиг
  невалидным (`failed to check code … from geosite.dat`), поэтому при её отсутствии правило
  пропускается с предупреждением в stderr, а не ломает старт Xray.

  Практика по геофайлу (проверено вручную собранным `geosite.dat`): коды категорий в файле
  хранятся **в верхнем регистре** (`CATEGORY-IPCHECK`), entries идут как последовательность
  `0a <len> <GeoSite>`, поэтому новую категорию можно дописать в конец существующего файла.
  Живая проверка с дописанной категорией: `ifconfig.me`, `api.ipify.org`, `2ip.ru` →
  `direct`, `example.com` → `proxy-AUTO-3`.

### Проверено на aarch64 (OpenWrt 25.12 armsr/armv8 в QEMU)

Отдельный стенд: реальное ARM-ядро (aarch64, TCG), rootfs armsr/armv8, WAN через NAT контейнера,
LAN — tap+netns-клиент, VLESS-сервер на amd64-хосте. Результаты:

* определение архитектуры: `DISTRIB_ARCH=aarch64_generic` → `arm64-v8a`, скачан
  `Xray-linux-arm64-v8a.zip`, `/usr/bin/xray version` → `linux/arm64`;
* установщик прошёл целиком, `tests/run.sh` — 29/29 (включая `xray run -test` ARM-бинаря);
* диагностика — все пункты `[OK]`;
* TProxy проксирует и LAN-клиента, и трафик самого роутера (в логе VLESS-сервера видны
  `accepted tcp:…:80` от ARM-роутера);
* `hole` уводит в DIRECT без обращений к прокси;
* `update-nft.sh` на ARM **корректно отказывается** работать без `kmod-nft-tproxy`
  (в образе armsr модуля нет) — то есть guard срабатывает на реальном ядре.

Найдено на этом стенде и исправлено:

* **При неудаче применения TProxy оставалась цепочка `xray_self`.** Router-vаш трафик
  маркировался, уходил в таблицу 100 (`local default dev lo`), TProxy-правил нет — пакет
  терялся, роутер оставался без интернета (в лабе это проявилось как `EPERM` на connect).
  Теперь любая ошибка вызывает `fail()`: снимает `xray_self`, чистит `xray_tproxy`,
  удаляет `ip rule`/таблицу 100 и завершается с кодом 1 — трафик идёт напрямую.
* `fail()` изначально стоял ниже первого вызова — в POSIX sh функция должна быть объявлена
  до использования; перенесён в начало скрипта.

Ограничение стенда: он x86-64. Пользовательский код (busybox-апплеты, python3, nft, логика
скриптов) на ARM/MIPS тот же, но ядро, `kmod-nft-tproxy`, производительность splice и память
на реальном ARM-роутере этим стендом не проверяются — нужен либо qemu-user с aarch64-rootfs,
либо железо.

### Замечания для ARM/MIPS (из документации)

* `policy.levels.*.bufferSize` по умолчанию `0` на ARM/MIPS/MIPSLE и `4` на ARM64/MIPS64
  (на остальных `512` КБ). Документация предупреждает, что слишком низкое значение (или `0`)
  для UDP приводит к отбрасыванию данных при переполнении буфера — на роутерах это стоит
  задать явно.
* `net.ipv4.ip_forward=1` (проект его включает) снижает производительность Splice по данным
  официального руководства TProxy; forwarding нужен только для bypass-сегментов (guest/IoT).

### Единственный источник правил роутинга (2026-10-25)

`routing` задаётся **только** в `settings.json` (эталон — `settings.default.json`). В генераторе
значений больше нет: остался перечень обязательных ключей (`ROUTING_KEYS`) и отказ с кодом 1 при
их отсутствии. Причина — дублирование дефолтов в двух файлах давало «тихий» дрейф: правка
в генераторе не действовала, потому что `settings.json` её перекрывал.

Проверено на стенде: при том же входе и том же `settings.json` конфиг до и после правки совпал
побайтово (sha256 `ec3eae6e…`, 10 правил), а при удалении `routing` целиком, отдельного ключа
`direct_ips` или самого файла настроек генератор завершается с кодом 1 и печатает команду
доливки ключей.

Следствие для обновления с прежних версий: старый `settings.json` может не содержать каких-то
ключей `routing` — генератор тогда завершится с ошибкой, а `update-xray.sh` оставит прежний
конфиг. Лечится доливкой недостающих ключей из `settings.default.json` (команда в README).

### Исправлено при сверке (2026-10-23)

1. `sockopt.tcpNoDelay` удалён — поля нет в SockoptObject, ядро его игнорировало.
2. `freedom.settings.domainStrategy` → `sockopt.domainStrategy` — предупреждение ядра исчезло.
3. `qtype` → `qType` — документированное написание ключа.
4. REALITY `publicKey` → `password` (+ переходный алиас).
5. Парсер возвращает код 2 вместо пустого результата: сбой разбора больше не превращается в DIRECT-конфиг.
6. Все теги прокси получают префикс `proxy-`: префиксное сопоставление `selector`/`subjectSelector` больше не может захватить `direct`/`block`/`dns-out`.
7. `/tmp/log` создаётся установщиком, `init.d` и `update-xray.sh` — иначе Xray не стартовал.
8. `update-nft.sh` завершается с ошибкой, если не определён LAN-интерфейс или ключевые правила не применились; bypass DNS-IP берётся из `config.json`.

### Остаётся осознанно (документацией не подтверждено)

1. **`protocol: "dokodemo-door"`** — работает как совместимое имя; в документации протокол называется `tunnel`.
2. **`network` вместо `method`** — легаси-вид `streamSettings`; валидатор принимает, новые примеры документации используют `method`.
3. **`xhttpSettings`** — проект генерирует `path`, `host`, `mode`, `extra`; официального описания полей нет (страница XHTTP — статья).
4. **`settings.vnext[]`** у VLESS — документирован плоский вид `settings.address/port/id/...`; `vnext` принимается как совместимый.

При любой правке конфигурации: сначала подтвердить поле по первоисточнику, затем менять код,
затем `./tests/run.sh` (включая `xray run -test`) и только после этого считать изменение рабочим.
