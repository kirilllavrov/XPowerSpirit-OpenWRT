# Полезные ссылки по Xray и nftables

> 📖 **Сначала справочник:** [xray-config-reference.md](./xray-config-reference.md) — выжимка из
> официальной русской документации (<https://xtls.github.io/ru/config/>) по всем объектам базовой
> конфигурации: поля, значения по умолчанию, ограничения и расхождения с этим проектом.
> Открывай его до правки `config.json` и генератора; ссылки ниже — для проверки первоисточника.
>
> 📌 **Точка входа для ИИ-агента и разработчика.** Перед генерацией или правкой
> Xray-конфигурации (`config.json`), правил маршрутизации/DNS, TProxy/nftables или
> парсеров подписок — сначала открой нужный раздел ниже. Если не уверен в параметре —
> **открой официальную страницу по ссылке** и следуй ей дословно, не выдумывай.
>
> ⚠️ `xtls.github.io` — SPA: несуществующая страница может ответить HTTP 200 и отдать
> заглушку «404». Перед использованием страницы проверь её заголовок, например:
> `curl -sL <URL> | grep -o '<title>[^<]*</title>'`.

## Что где в проекте

| Файл / тема | Раздел документации |
|-------------|---------------------|
| `xray-generate-config.py` — log, dns, inbounds, outbounds, routing, balancers | `config/`, `config/dns.html`, `config/inbound.html`, `config/outbound.html`, `config/routing.html`, `config/observatory.html` |
| `xray-generate-config.py` — `burstObservatory` + `leastLoad` | `config/observatory.html`, `config/routing.html` |
| `xray-generate-config.py` — `tproxy-in` (dokodemo-door), `sockopt.tproxy`, `mark` | `config/inbounds/tunnel.html`, `config/transports/sockopt.html`, `document/level-2/tproxy.html` |
| `xray-sub-parser.py` — VLESS URI, транспорты, TLS/Reality | `config/outbounds/vless.html`, `config/transport.html`, `config/transports/*.html` |
| `update-nft.sh` — `tproxy`, `meta mark`, цепочки fw4 | man nftables, wiki nftables, `document/level-2/tproxy.html` |

## Конфигурация Xray (xtls.github.io/config)

Общая структура конфига: лог, DNS, inbounds, outbounds, routing. Оглавление для всей работы с Xray.

- https://xtls.github.io/config/
- https://xtls.github.io/config/dns.html — DNS: серверы, domainStrategy, hosts, правила
- https://xtls.github.io/config/fakedns.html
- https://xtls.github.io/config/inbound.html — входящие: tproxy/dokodemo-door, sniffing, порты
- https://xtls.github.io/config/outbound.html — исходящие: freedom, blackhole, dns, vless (общие поля, Mux)
- https://xtls.github.io/config/routing.html — routing: rules, балансировщики (`balancers`, стратегии, `fallbackTag`)
- https://xtls.github.io/config/observatory.html — `observatory` / `burstObservatory` (`subjectSelector`, `pingConfig`), используется проектом для `leastLoad`

### Входящие подключения (inbounds)

Куда смотреть при настройке inbound (tproxy/dokodemo-door, sniffing, порты).
`tproxy-in` в этом проекте — это **dokodemo-door**, его страница называется «Tunnel（dokodemo-door）».

- https://xtls.github.io/config/inbounds/tunnel.html — Tunnel (dokodemo-door): `followRedirect`, `allowedNetwork`, TProxy
- https://xtls.github.io/config/inbounds/tun.html

### Исходящие подключения (outbounds)

Куда смотреть при настройке outbounds (direct/block/dns-out, VLESS-клиент).

- https://xtls.github.io/config/outbounds/blackhole.html
- https://xtls.github.io/config/outbounds/dns.html
- https://xtls.github.io/config/outbounds/freedom.html
- https://xtls.github.io/config/outbounds/vless.html — VLESS-клиент: `vnext`, `users`, `flow`, `encryption`

### Транспорт

Куда смотреть при выборе/настройке транспорта: tcp/ws/grpc/http/xhttp, TLS/Reality,
sockopt (tproxy, mark) и безопасность соединения.

- https://xtls.github.io/config/transport.html — выбор сети (network) и её настроек
- https://xtls.github.io/config/transports/finalmask.html
- https://xtls.github.io/config/transports/sockopt.html — sockopt: tproxy, mark, domainStrategy, keepalive
- https://xtls.github.io/config/transports/reality.html — Reality: pbk/sid/spx/fp/SNI
- https://xtls.github.io/config/transports/tls.html

## Документация Xray

- Уровень 0 — клиенты: https://xtls.github.io/document/level-0/ch08-xray-clients.html
- Уровень 1 — маршрутизация, часть 1: https://xtls.github.io/document/level-1/routing-lv1-part1.html
- Уровень 1 — маршрутизация, часть 2: https://xtls.github.io/document/level-1/routing-lv1-part2.html
- Уровень 1 — общая работа: https://xtls.github.io/document/level-1/work.html
- Уровень 1 — маршрутизация + DNS: https://xtls.github.io/document/level-1/routing-with-dns.html
- Уровень 2 — прозрачный прокси: https://xtls.github.io/document/level-2/transparent_proxy/transparent_proxy.html
- Уровень 2 — tproxy: https://xtls.github.io/document/level-2/tproxy.html
- Уровень 2 — redirect: https://xtls.github.io/document/level-2/redirect.html

## nftables

Куда смотреть при правке правил TProxy (`update-nft.sh`): цепочки, `tproxy`, `mark`, policy routing
(`ip rule`/`ip route` — это уже iproute2, `man ip-rule` / `man ip-route`).

- https://www.netfilter.org/projects/nftables/manpage.html — man nftables (синтаксис, `tproxy`, `meta mark`)
- https://www.netfilter.org/projects/nftables/index.html — официальная страница проекта nftables
- https://wiki.nftables.org/wiki-nftables/index.php/Main_Page — официальная wiki nftables (примеры цепочек)
