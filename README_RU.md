# OpenWrt Roaming Manager (`roamctl`)

Бесшовный Wi-Fi-роуминг для OpenWrt практически в одно касание:
`roamctl setup` анализирует точку доступа, определяет, что реально
поддерживают оборудование, драйвер и сборка hostapd, показывает план
изменений и после подтверждения настраивает **802.11k** (neighbor
reports), **802.11v** (BSS Transition Management), **802.11r** (Fast BSS
Transition), **steering** клиентов и диапазонов и синхронизацию
**нескольких AP**. Каждое изменение сохраняется в backup, применяется в
транзакции с recovery watchdog и проверяется по реально работающему
hostapd.

> **Важно:** решение о роуминге принимает клиент. roamctl настраивает
> точки доступа так, чтобы совместимые клиенты переключались быстро и
> получали рекомендации перейти на лучшую AP. Принудить клиента к
> переходу невозможно, и переключение без потерь не гарантируется для
> клиентов без поддержки 802.11k/v/r.

[English version](README.md)

## Возможности

| Область | Что делает roamctl |
|---|---|
| Обнаружение | версия OpenWrt, менеджер пакетов (opkg/apk), плата, SoC (MediaTek Filogic MT7981/MT7986/MT7987/MT7988, Qualcomm IPQ, Broadcom и др.), ядро, радиомодули, диапазоны, каналы, драйверы, BSSID, SSID, безопасность |
| Compatibility Engine | шесть независимых уровней: оборудование → драйвер (softmac/fullmac) → ядро → netifd-обработчик и пакет wpad → возможности сборки hostapd и его ubus-методы → безопасность конкретного BSS. Функция включается, только если согласны все уровни |
| 802.11k | `ieee80211k` (RRM, neighbor и beacon reports); реальные записи Neighbor Report со всех BSS группы с поддержкой актуальности |
| 802.11v | `bss_transition` (+ `ieee80211v` для старых обработчиков), BTM-запросы с ранжированным списком кандидатов |
| 802.11r | FT over the Air (по умолчанию) или over the DS, FT-PSK, FT-SAE, FT-EAP, `ft_psk_generate_local` либо общий ключ R0KH/R1KH |
| Mobility Domain | криптостойкий MDID на roaming-группу, сохраняется, не перегенерируется, общий для всех AP группы, обнаружение конфликтов |
| Steering | usteer (по умолчанию), DAWN (альтернатива) или встроенный native-backend; пороги по диапазонам, гистерезис, cooldown, лимит попыток, защита от ping-pong, списки клиентов, band steering, учёт нагрузки |
| Multi-AP | управление по SSH-ключам, обнаружение, проверки согласованности, поэтапное применение (по одной AP), распространение FT-ключей и neighbor reports |
| Безопасность | backup перед каждым изменением, журнал изменений, транзакции commit-confirm с отделённым watchdog, откат при загрузке, блокировка параллельных запусков, атомарная запись, секреты не попадают в логи |
| Диагностика | оборудование, пакеты, конфигурация, работающий hostapd, 802.11k/v/r, steering, связность, опрос возможностей клиентов, live-тест роуминга с реальным клиентом |

## Совместимость

| OpenWrt | Пакеты | Статус |
|---|---|---|
| 25.x / SNAPSHOT | apk | поддерживается, проверено в mock-окружении |
| 24.10.x | opkg | поддерживается, проверено в mock-окружении |
| 22.03 / 23.05 | opkg | best effort (старый shell-обработчик netifd) |
| ≤ 21.02 | opkg | не поддерживается |

Подходит любой mac80211 (softmac) драйвер. Основные цели: MediaTek
Filogic (MT7981, MT7986, MT7987, MT7988) для главного роутера и
**MediaTek MT7621 (ramips) для дополнительных точек доступа** (MT7603E,
MT7612E, MT7615E, MT7915E). На этих MIPS-устройствах roamctl проверяет свободный флеш перед
установкой пакетов, хранит меньше backup, использует облегчённые
настройки демона и не порождает лишних процессов в «горячих» местах.
Qualcomm ath9k/ath10k/ath11k/ath12k, Realtek rtw88/rtw89 и др. тоже
работают. Fullmac-драйверы (например, Broadcom
`brcmfmac`) выполняют аутентификацию в прошивке — для них roamctl честно
сообщает, что 802.11r/k/v не поддерживаются, и ничего не включает.

Подробности: [docs/compatibility.md](docs/compatibility.md).

## Установка

На точке доступа:

```bash
cd /tmp && wget -O roamctl.tar.gz https://github.com/p0sixxx/openwrt-roaming-manager/archive/refs/heads/main.tar.gz
```

```bash
tar -xzf roamctl.tar.gz && sh openwrt-roaming-manager-main/install/install.sh
```

С рабочей станции:

```bash
git clone https://github.com/p0sixxx/openwrt-roaming-manager.git
```

```bash
cd openwrt-roaming-manager && tar -czf - . | ssh root@192.168.1.1 'mkdir -p /tmp/orm && tar -xzf - -C /tmp/orm && sh /tmp/orm/install/install.sh'
```

Установщик копирует программу в `/usr/lib/roamctl`, создаёт
`/usr/sbin/roamctl` и сервис `roamctl`. Конфигурация не меняется, пакеты
не устанавливаются.

## Быстрый старт

```bash
roamctl audit        # только анализ: показывает, что изменит setup
```

```bash
roamctl setup        # план, подтверждение, настройка, проверка
```

```bash
roamctl --yes setup  # без вопросов
```

Без команды в терминале открывается интерактивное меню: Automatic /
Advanced / Audit / Repair / Multi-AP / Diagnostics / Backup-Restore /
Uninstall. Коды выхода: `0` — успех, `1` — ошибка (изменения откачены),
`3` — выполнено, но диагностика нашла FAIL.

## Как это работает

```
обнаружение ─► совместимость ─► roaming-группы ─► план ─► подтверждение
   ─► backup ─► пакеты ─► транзакция (watchdog ─► UCI ─► wifi reload ─► health check)
   ─► подтверждение или откат ─► neighbor reports ─► проверка ─► отчёт
```

* **Roaming-группа** — интерфейсы с одинаковыми SSID, режимом
  безопасности *и* паролем (сравнивается отпечаток). Совпадение SSID само
  по себе ничего не доказывает: конфликты показываются и не объединяются.
* **Guest/IoT/изолированные** интерфейсы и открытые/OWE-сети не
  затрагиваются без явного `--include <section>`.
* SSID, пароль, канал, ширина канала, мощность и страна в стандартном
  режиме не меняются.
* Пишутся только UCI-параметры, которые понимает установленный
  обработчик netifd; результат проверяется в реально используемой
  конфигурации hostapd (`/var/run/hostapd-*.conf`) и через ubus.

## 802.11k / 802.11v / 802.11r

* **802.11k**: `ieee80211k=1` → `rrm_neighbor_report=1`,
  `rrm_beacon_report=1`. Записи Neighbor Report берутся из
  `ubus call hostapd.<if> rrm_nr_get_own` каждого BSS группы (все
  диапазоны, все AP), проверяются (BSSID, operating class, канал, PHY) и
  устанавливаются через `rrm_nr_set`, без самого BSS. Фиктивные записи не
  создаются. При usteer/DAWN их распространяет backend, иначе roamctl
  (с повторной установкой после перезапуска hostapd).
* **802.11v**: `bss_transition=1`. В стандартном профиле BTM-запросы —
  *рекомендации* без «disassociation imminent»; клиенты без BTM никогда
  не отключаются.
* **802.11r**: `ieee80211r=1`, `mobility_domain`, `ft_over_ds=0`
  (over the Air — лучшая совместимость; `--ft-over-ds` для смены).
  WPA2-PSK использует `ft_psk_generate_local=1`; SAE, смешанный SAE/PSK и
  EAP — R0KH/R1KH с общим случайным ключом.

## Mobility Domain и ключи FT

* MDID — 2 байта (4 hex-символа) из `/dev/urandom` (на основе getrandom),
  один на roaming-группу, хранится в `/etc/config/roamctl`, переиспользуется
  при каждом запуске и передаётся на все AP группы. `0000`, `ffff` и
  пример из hostapd не используются. Уже согласованно настроенный MDID
  перенимается, а не заменяется. `$RANDOM` не используется.
* Конфликты: другие группы roamctl, другие SSID на AP, участники
  Multi-AP и (через `roamctl mdid scan`) соседние сети с тем же MDID.
* Ручная смена: `roamctl mdid set <group> <hex4>` или
  `roamctl mdid random <group>`, затем `roamctl multiap sync`.
* Ключ FT (SAE/EAP): 256 бит, `/etc/roamctl/keys/<group>.ftkey`
  (права 600), используется в записях `r0kh`/`r1kh`; передаётся на AP
  только через stdin SSH-сессии, сравнивается по отпечатку, никогда не
  выводится и не логируется.

## Steering (usteer, DAWN, native)

| Backend | Когда | Примечание |
|---|---|---|
| `usteer` | по умолчанию | распределённый, обмен по UDP 16720; пишутся только параметры, которые сообщает `ubus call usteer get_config` |
| `dawn` | `--backend dawn` | пороги по диапазонам, шифрование обмена случайным секретом группы |
| `native` | резерв или `--backend native` | встроенный policy engine, BTM через hostapd напрямую |
| `none` | `--backend none` | только функции роуминга |

Одновременно активен только один steering-демон; конкурирующий
останавливается и отключается (пакет остаётся). Пороги различаются для
2.4/5/6 ГГц и подбираются оптимизатором по профилю, числу AP, измеренному
шуму и нагрузке. Защита: гистерезис по времени и уровню сигнала, cooldown,
лимит попыток, обнаружение ping-pong, минимальное время ассоциации. Band
steering предпочитает 5/6 ГГц для сильных двухдиапазонных клиентов и
никогда не отключает 2.4 ГГц.

## Multi-AP

```bash
roamctl setup                         # на AP-контроллере
```

```bash
roamctl multiap copy-id 192.168.1.3   # установить ключ контроллера (пароль спросит ssh)
```

```bash
roamctl multiap add office 192.168.1.3
```

```bash
roamctl multiap install office        # при необходимости скопировать roamctl на AP
```

```bash
roamctl multiap sync                  # поэтапная синхронизация + neighbor reports
```

AP изменяются **по одной**, каждая в собственной транзакции с backup,
watchdog и health check. При первой ошибке развёртывание
останавливается; недоступные AP пропускаются. См.
[docs/multi-ap.md](docs/multi-ap.md).

## Backup, откат и восстановление

* Backup `/etc/config`, `/etc/roamctl`, отдельных конфигов hostapd,
  списка пакетов, MDID и состояния сервисов с проверкой SHA-256
  (`/etc/roamctl/backups`, права 700, хранятся последние 10).
* Каждое изменение: backup → постоянная метка *pending* → отделённый
  watchdog (`setsid`) → применение → проверки (BSS hostapd, радио, UCI,
  шлюз) → подтверждение. При провале проверок backup восстанавливается
  сразу; если roamctl завершится (например, оборвётся SSH по Wi-Fi),
  watchdog восстановит его по истечении срока (180 с); после потери
  питания восстановление выполнит init-скрипт при загрузке.

```bash
roamctl backup list
```

```bash
roamctl rollback   # восстанавливает только wireless/roaming-конфигурацию
```

`roamctl rollback --full <id>` восстанавливает весь `/etc/config`
(после этого перезагрузите устройство).

## Диагностика

```bash
roamctl diag
```

Статусы: `PASS`, `WARN`, `FAIL`, `NOT SUPPORTED`, `NOT TESTED` — каждый
с пояснением. Проверяется работающая система, а не только UCI.

Live-тест роуминга (нужны реальный клиент и минимум два BSS):

```bash
roamctl test live --client aa:bb:cc:dd:ee:ff --duration 90 --ip 192.168.1.50
```

Фиксируются BSSID до/после, сигнал, длительность перерыва ассоциации,
потери ping и самый длинный перерыв, а также признак FT по журналу
hostapd. Без клиента выводится
`CONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED`.

## Удаление

```bash
roamctl uninstall                         # откатить изменения конфигурации
```

```bash
sh /usr/lib/roamctl/install/uninstall.sh  # удалить программу
```

## Известные ограничения

* Решение о роуминге принимает клиент; многие IoT-устройства игнорируют
  802.11k/v, некоторые старые клиенты плохо работают с 802.11r.
* Пороги usteer глобальные (SNR с разными предположениями о шуме для
  диапазонов); исключение клиентов требует версии usteer с
  `aggressiveness_mac_list`.
* Native-backend использует только BTM, без межточечных измерений
  сигнала (сбор beacon reports не используется).
* Live-тест опрашивает раз в секунду: перерыв ассоциации — верхняя
  оценка с точностью 1 с. Для Multi-AP нужна синхронизация часов (NTP).
* MediaTek Filogic, MT7621, Qualcomm и Broadcom проверены только
  в mock-окружении — **на реальном оборудовании проверка ещё не
  проводилась**.
* При почти заполненном флеше usteer может не поместиться; тогда roamctl
  использует встроенный steering-backend.

## Разработка и тесты

```bash
tests/run.sh             # все наборы тестов
```

```bash
tests/run.sh --busybox   # BusyBox ash + апплеты BusyBox
```

Лицензия: [MIT](LICENSE).
