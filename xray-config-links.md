# Полезные ссылки по Xray и nftables

> 📌 **Точка входа для ИИ-агента и разработчика.** Перед генерацией или правкой
> Xray-конфигурации (`config.json`), правил маршрутизации/DNS, TProxy/nftables или
> парсеров подписок — сначала открой нужный раздел ниже. Если не уверен в параметре —
> **открой официальную страницу по ссылке** и следуй ей дословно, не выдумывай.

## Конфигурация Xray (xtls.github.io/config)

Общая структура конфига: лог, DNS, inbounds, outbounds, routing. Оглавление для всей работы с Xray.

- https://xtls.github.io/config/
- https://xtls.github.io/config/dns.html — DNS: серверы, domainStrategy, hosts, правила
- https://xtls.github.io/config/fakedns.html
- https://xtls.github.io/config/inbound.html — входящие: tproxy/dokodemo-door, sniffing, порты
- https://xtls.github.io/config/outbound.html — исходящие: freedom, blackhole, dns, vless
- https://xtls.github.io/config/routing.html — routing: rules, balancer, observatory

### Входящие подключения (inbounds)

Куда смотреть при настройке inbound (tproxy/dokodemo-door, sniffing, порты).

- https://xtls.github.io/config/inbounds/tunnel.html
- https://xtls.github.io/config/inbounds/tun.html

### Исходящие подключения (outbounds)

Куда смотреть при настройке outbounds (direct/block/dns-out, VLESS-клиент).

- https://xtls.github.io/config/outbounds/blackhole.html
- https://xtls.github.io/config/outbounds/dns.html
- https://xtls.github.io/config/outbounds/freedom.html

### Транспорт

Куда смотреть при выборе/настройке транспорта: tcp/ws/grpc/http/xhttp, TLS/Reality,
sockopt (tproxy, mark) и безопасность соединения.

- https://xtls.github.io/config/transport.html — выбор сети (network) и её настроек
- https://xtls.github.io/config/transports/finalmask.html
- https://xtls.github.io/config/transports/sockopt.html — sockopt: tproxy, mark, tcpNoDelay, keepalive
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

Куда смотреть при правке правил TProxy (`update-nft.sh`): цепочки, tproxy, mark, policy routing.

- https://www.netfilter.org/projects/nftables/manpage.html — man nftables
