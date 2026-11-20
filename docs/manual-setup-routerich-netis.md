# Ручная настройка роуминга: Routerich AX3000 v1 + Netis NX30 V2 (OpenWrt 25.12)

Без roamctl, только `apk`, `uci` и `wifi`. Все опции сверены с исходниками
OpenWrt 25.12 (ucode-скрипты Wi-Fi `ap.uc` и схема
`wireless.wifi-iface.json`).

**Всё выполнять с ПК, подключённого кабелем.** Wi-Fi на точке будет
пропадать на время шагов 2 и 3.

Адреса в этом гайде:

| Устройство | Адрес | Роль |
|---|---|---|
| Routerich AX3000 | `192.168.73.1/24` | основной роутер: шлюз, DNS, DHCP |
| Netis NX30 V2 | `192.168.73.3/24` | вторая точка («тупая» AP), без DHCP |
| Netis NX30 V2 до шага 1.4 | `192.168.1.1` | адрес по умолчанию |

**Порядок: включать по одной функции и проверять.** Польза 802.11k/v и
usteer зависит от клиентов: у части пользователей они ничего не дают или
мешают (BTM-запросы тормозят некоторые Windows-клиенты). Поэтому:

1. Минимум — только 802.11r: шаги 1 → 3.1–3.4 → 5. Хватает штатного
   `wpad-basic-mbedtls`, шаг 2 не нужен.
2. Если переходы между точками всё ещё плохие — добавить 802.11k/v и
   usteer: шаги 2 → 3.5 → 4 → 5.

---

## 1. Подготовка (на каждой точке)

### 1.1 Сохранить резервную копию и скачать её на ПК

На точке:

```bash
sysupgrade -b /tmp/backup-before-roaming.tar.gz
```

На ПК, Routerich:

```bash
scp -O root@192.168.73.1:/tmp/backup-before-roaming.tar.gz backup-routerich.tar.gz
```

NX30 — до шага 1.4, пока ПК подключён кабелем к его LAN и у него адрес
по умолчанию:

```bash
scp -O root@192.168.1.1:/tmp/backup-before-roaming.tar.gz backup-nx30.tar.gz
```

### 1.2 Проверить имена секций и радио

```bash
uci show wireless | grep -E '=wifi-iface|\.band=|\.device='
```

Ожидается: `wireless.default_radio0` на `radio0` с `band='2g'` и
`wireless.default_radio1` на `radio1` с `band='5g'`. **Если имена секций
другие — подставьте свои в шаге 3.**

### 1.3 Одинаковые параметры сети на обеих точках

В LuCI (Network → Wireless) на **обеих** точках для **обоих** радио:

* одинаковые SSID и пароль — **один SSID на 2.4 и 5 ГГц** (usteer
  раздаёт соседей 802.11k только точкам с тем же SSID);
* шифрование **только WPA2-PSK** (`psk2`), см. предупреждение ниже;
* одинаковая страна (с «driver default» радио может не включиться);
* **разные каналы без перекрытия**: например, Routerich — 1 и 36, NX30 —
  11 и 149; на 5 ГГц лучше без DFS;
* ширина 5 ГГц — **80 МГц** (`HE80`), не 160: на 160 МГц каналы
  перекрываются, а ожидание DFS может длиться до 10 минут;
* мощность (`txpower`) — ниже максимальной, чтобы зоны покрытия точек
  перекрывались умеренно: клиент тогда раньше уходит на ближнюю точку.
  Подбирается по месту; сильно занижать тоже нельзя.

> **WPA3 и 802.11r в 25.12.** При FT с `sae` на 25.12 часть клиентов
> (Android, iPhone) перестаёт переходить между точками
> ([openwrt/openwrt#22200](https://github.com/openwrt/openwrt/issues/22200));
> исправление сделано в main, в 25.12 его может не быть. Смешанный режим
> `sae-mixed` для роуминга тоже не рекомендуют. Пока используйте `psk2`.

Проверка:

```bash
uci show wireless | grep -E '\.ssid=|\.encryption=|\.country=|\.channel=|\.htmode=|\.txpower='
```

### 1.4 NX30 как вторая точка («тупая» AP)

Сначала, пока ПК ещё в сети Routerich, убедиться, что `192.168.73.3`
свободен: он вне пула DHCP Routerich (LuCI → Network → Interfaces → LAN
→ DHCP Server; например, при `start=100`, `limit=150` пул —
192.168.73.100–249) и не занят статической арендой (Network → DHCP and
DNS → Static Leases). Адрес не должен отвечать, и его не должно быть в
ARP-таблице ПК:

```bash
ping -n 2 192.168.73.3
```

```bash
arp -a
```

Затем подключить ПК кабелем к LAN NX30 (NX30 ещё на 192.168.1.1, к
Routerich **не** подключён) и выполнить на NX30.

В 25.12 адрес LAN хранится списком в формате `адрес/префикс`
(`list ipaddr '192.168.1.1/24'`), поэтому старый адрес удаляется и
новый добавляется **с `/24`** — без префикса точка получит маску /32 и
потеряет связь с сетью. Проверить, как сейчас:

```bash
uci show network.lan
```

```bash
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci add_list network.lan.ipaddr='192.168.73.3/24'
uci set network.lan.gateway='192.168.73.1'
uci add_list network.lan.dns='192.168.73.1'
uci set dhcp.lan.ignore='1'
uci commit network
uci commit dhcp
/etc/init.d/odhcpd disable
reboot
```

Затем соединить LAN NX30 с LAN Routerich (WAN-порт NX30 не
использовать), подключить ПК к Routerich и проверить с Routerich:

```bash
ping -c 3 192.168.73.3
```

С ПК (Windows) и доступ по SSH:

```bash
ping -n 3 192.168.73.3
```

```bash
ssh root@192.168.73.3
```

На NX30 — выход в интернет через Routerich:

```bash
ping -c 2 downloads.openwrt.org && apk update
```

---

### 1.5 Routerich: проверить аппаратный flow offload

На форуме OpenWrt сообщают, что аппаратный flow offload на главном
роутере ломает роуминг: после перехода трафик возобновляется через
десятки секунд. Проверка (только чтение):

```bash
uci show firewall | grep -i offload
```

Если там `flow_offloading_hw='1'` и после настройки роуминга клиенты
подвисают при переходе — выключить (вернуть: то же с `'1'`):

```bash
uci set firewall.@defaults[0].flow_offloading_hw='0' && uci commit firewall && /etc/init.d/firewall restart
```

---

## 2. Замена wpad-basic на полный wpad-mbedtls (на каждой точке)

Нужен для 802.11v и usteer (вторая часть порядка в начале гайда). Для
одного 802.11r этот шаг пропустить.

`wpad-basic-mbedtls` собран без WNM (`#CONFIG_WNM=y` в
`hostapd-basic.config`): нет 802.11v. Нужен полный `wpad-mbedtls`.

Проверить, что установлено:

```bash
apk list --installed | grep -E '^(wpad|hostapd)'
```

Замена (нужен интернет — на NX30 он идёт через Routerich). Сначала
скачиваются **оба** пакета: полный — для установки, basic — чтобы вернуть
его без сети, если что-то пойдёт не так:

```bash
apk update
```

```bash
mkdir -p /tmp/wpad && apk fetch -o /tmp/wpad wpad-mbedtls wpad-basic-mbedtls && ls /tmp/wpad
```

Должны появиться два файла: `wpad-mbedtls-….apk` и
`wpad-basic-mbedtls-….apk`. Только после этого:

```bash
apk del wpad-basic-mbedtls
```

```bash
apk add --allow-untrusted /tmp/wpad/wpad-mbedtls-*.apk
```

```bash
/etc/init.d/wpad enable && /etc/init.d/wpad restart && wifi reload
```

Почему `--allow-untrusted`: OpenWrt 25.12 подписывает только индекс
репозитория, а не сами `.apk`-файлы, и apk отказывается ставить локальный
файл без этого флага (`UNTRUSTED signature`). Файл, скачанный через
`apk fetch`, уже сверен с хешем из подписанного индекса.

Если `apk del` откажется удалять из-за зависимостей:

```bash
apk del --force-broken-world wpad-basic-mbedtls
```

Если `apk add` завершился ошибкой — вернуть basic из скачанного файла
(сеть не нужна), Wi-Fi заработает как раньше:

```bash
apk add --allow-untrusted /tmp/wpad/wpad-basic-mbedtls-*.apk && /etc/init.d/wpad restart && wifi reload
```

Проверка (через ~20 с после `wifi reload`). Должны быть `wpad-mbedtls-…`,
`11r ok` и строка `bss_transition_request` (имена интерфейсов — из
`ubus list 'hostapd.*'`; обычно `phy0-ap0` — 2.4 ГГц, `phy1-ap0` — 5 ГГц):

```bash
apk list --installed | grep -E '^(wpad|hostapd)'
```

```bash
hostapd -v11r && echo "11r ok"
```

```bash
ubus -v list hostapd.phy1-ap0 | grep -E 'bss_transition_request|rrm_nr_set'
```

---

## 3. 802.11r, затем 802.11k / 802.11v (на каждой точке)

### 3.1 Один раз придумать Mobility Domain

Без явного MD 25.12 вычисляет его из SSID — при одинаковом SSID он и так
совпадёт на обеих точках. Явный MD надёжнее (не зависит от версии
OpenWrt на точках) и удобнее в логах.

Выполнить **один раз** (на любой точке), запомнить результат — 4
hex-символа, например `a7c2`:

```bash
hexdump -n 2 -e '2/1 "%02x"' /dev/urandom; echo
```

### 3.2 Применить на Routerich

Подставьте свой MD вместо `a7c2`:

```bash
MD=a7c2
AP=routerich
for i in default_radio0 default_radio1; do
  uci set wireless.$i.ieee80211r='1'
  uci set wireless.$i.mobility_domain="$MD"
  uci set wireless.$i.ft_over_ds='0'
  uci set wireless.$i.ft_psk_generate_local='1'
  uci set wireless.$i.nasid="$AP-${i#default_}"
done
uci commit wireless
wifi reload
```

### 3.3 Применить на NX30

**Тот же MD**, другое имя точки:

```bash
MD=a7c2
AP=nx30
for i in default_radio0 default_radio1; do
  uci set wireless.$i.ieee80211r='1'
  uci set wireless.$i.mobility_domain="$MD"
  uci set wireless.$i.ft_over_ds='0'
  uci set wireless.$i.ft_psk_generate_local='1'
  uci set wireless.$i.nasid="$AP-${i#default_}"
done
uci commit wireless
wifi reload
```

Что это значит:

| Опция | Значение |
|---|---|
| `ieee80211r=1` | Fast Transition (добавляет FT-PSK) |
| `mobility_domain` | одинаковый на всех точках одной сети |
| `ft_over_ds=0` | FT over the Air — лучшая совместимость с клиентами |
| `ft_psk_generate_local=1` | ключи FT выводятся из пароля локально, обмен ключами между точками не нужен |
| `nasid` | уникальный идентификатор каждого BSS (R0KH-ID). Необязателен: без него 25.12 берёт BSSID; явное имя удобнее в логах |
| `ieee80211k=1` (шаг 3.5) | 802.11k: neighbor и beacon reports |
| `bss_transition=1` (шаг 3.5) | 802.11v BSS Transition Management (только с полным wpad) |

`reassociation_deadline` задавать не нужно: в 25.12 по умолчанию уже
20000 (старый совет с форума). `ieee80211w` для `psk2` не трогать —
`ieee80211w='2'` отключит клиентов без 802.11w.

### 3.4 Проверить, что hostapd это принял

На каждой точке. Должны быть `FT-PSK` в `wpa_key_mgmt` и ваш
`mobility_domain`; после шага 3.5 ещё `rrm_neighbor_report=1` и
`bss_transition=1`. Пароли эта команда не показывает:

```bash
grep -hE '^(interface|bss|wpa_key_mgmt|mobility_domain|ft_over_ds|ft_psk_generate_local|nas_identifier|rrm_neighbor_report|rrm_beacon_report|bss_transition)=' /var/run/hostapd-phy*.conf
```

Оба BSS запущены:

```bash
ubus list 'hostapd.*'
```

Если какого-то BSS нет — смотреть ошибку:

```bash
logread | grep -iE 'hostapd|wifi' | tail -n 40
```

### 3.5 Добавить 802.11k / 802.11v (после шага 2)

Только если после проверки одного 802.11r (шаг 5) переходы плохие. На
**обеих** точках:

```bash
for i in default_radio0 default_radio1; do
  uci set wireless.$i.ieee80211k='1'
  uci set wireless.$i.bss_transition='1'
done
uci commit wireless
wifi reload
```

Затем повторить проверку 3.4 и перейти к шагу 4.

---

## 4. usteer — steering и раздача соседей 802.11k (на каждой точке)

Без usteer точки не знают BSS друг друга, и списки соседей 802.11k
останутся пустыми. usteer из 25.12 (проверено по исходникам) сам
заполняет их через `rrm_nr_set` — но только BSS с тем же SSID, до 8
соседей; поэтому SSID на 2.4 и 5 ГГц должен быть один (шаг 1.3).
Установка:

```bash
apk add usteer
```

```bash
uci set usteer.@usteer[0].network='lan'
uci set usteer.@usteer[0].local_mode='0'
uci add_list usteer.@usteer[0].ssid_list='ВАШ_SSID'
uci commit usteer
/etc/init.d/usteer enable
/etc/init.d/usteer restart
```

Пороги роуминга (`roam_scan_snr`, `roam_trigger_snr`, `min_snr`) **не
задавайте**. Проверено по исходникам usteer из 25.12 (2025-10-04):

* опции `aggressiveness` в этой версии нет (она есть только в новом
  usteer) — её установка ни на что не влияет;
* по умолчанию usteer никого не отключает: раздаёт списки соседей 802.11k
  и раз в 2 минуты мягко (BTM без отключения) предлагает клиентам с
  поддержкой 802.11v перейти с 2.4 на 5 ГГц;
* если задать `roam_scan_snr` или `roam_trigger_snr`, usteer после BTM с
  флагом «disassociation imminent» **отключает клиента через 10 секунд**,
  даже если тот не поддерживает 802.11v.

Момент перехода между точками выбирает сам телефон — по спискам соседей
802.11k, с быстрым переходом 802.11r.

Проверка через 1–2 минуты. В `remote_info` должны быть BSS другой точки,
в `rrm_nr_list` — 3 записи:

```bash
ubus call usteer remote_info
```

```bash
ubus call hostapd.phy1-ap0 rrm_nr_list
```

usteer обменивается данными по UDP 16720 внутри LAN — по кабелю LAN↔LAN
(в том числе через промежуточный роутер-свитч) это работает без
настройки firewall.

Если с usteer стало хуже (задержки у Windows-клиентов, в логе
`BSS-TM-RESP ... status_code=7`) — сначала выключить 802.11v
(`bss_transition='0'` на обеих точках), а если не помогло — usteer:

```bash
/etc/init.d/usteer disable && /etc/init.d/usteer stop
```

---

## 5. Проверка роуминга с телефоном

На Routerich и на NX30 в двух окнах SSH:

```bash
logread -f | grep -iE 'associated|handshake|auth_alg|FT'
```

Пройдите с телефоном от одной точки к другой:

* на новой точке появится `associated`;
* `AP-STA-CONNECTED <MAC> auth_alg=ft` и **нет**
  `pairwise key handshake completed` — FT сработал (быстрый роуминг);
* `auth_alg=open` и `pairwise key handshake completed` — телефон
  переподключился без FT: связь работает, но переход медленнее. Часть
  клиентов (особенно стационарные и старые) FT не использует вообще.

`nl80211: kernel reports: key addition failed` при переходе на MediaTek
безвреден: так бывает при возврате на радио, где ключ клиента уже есть.

### 5.1 Если клиенты зависают после перехода

* Клиента после неудачного перехода не пускает на вторую точку
  несколько минут — проверить, что между точками нет проблемного
  свитча: на форуме OpenWrt причиной был неуправляемый свитч. Если NX30
  подключён через ещё один роутер (например, Keenetic как свитч), для
  проверки подключить NX30 к Routerich напрямую. Промежуточный роутер
  должен соединять точки LAN-портами одного моста, без DHCP и RA.
* Переход есть (`auth_alg=ft`), но трафик возобновляется через десятки
  секунд — проверить flow offload на Routerich (шаг 1.5).
* В логе `FT(RRB): Failed to decrypt` — точки обмениваются ключами FT и
  они не совпадают; с `ft_psk_generate_local='1'` (шаг 3) обмен не нужен,
  проверьте эту опцию в `/var/run/hostapd-phy*.conf`.

---

## 6. Откат

Только Wi-Fi — вернуть точку к исходному состоянию:

```bash
for i in default_radio0 default_radio1; do for o in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local nasid ieee80211k bss_transition; do uci -q delete wireless.$i.$o; done; done; uci commit wireless; wifi reload
```

Полностью — восстановить backup из шага 1.1 (LuCI → System →
Backup/Flash Firmware → Restore) или на точке:

```bash
sysupgrade -r /tmp/backup-before-roaming.tar.gz && reboot
```

`/tmp` очищается при перезагрузке (NX30 перезагружался в шаге 1.4). Если
файла там нет — скопировать с ПК (адрес точки — текущий):

```bash
scp -O backup-nx30.tar.gz root@192.168.73.3:/tmp/backup-before-roaming.tar.gz
```

```bash
scp -O backup-routerich.tar.gz root@192.168.73.1:/tmp/backup-before-roaming.tar.gz
```

Backup NX30 сделан до шага 1.4, поэтому его восстановление вернёт NX30
прежний адрес 192.168.1.1 и DHCP-сервер — отключите NX30 от Routerich
перед этим, иначе в сети 192.168.73.0/24 появится второй DHCP-сервер.
После перезагрузки NX30 доступен по 192.168.1.1 с ПК, подключённого
кабелем напрямую к нему.

Вернуть basic wpad (не обязательно, полный работает и без роуминга):

```bash
apk del wpad-mbedtls && apk add wpad-basic-mbedtls && /etc/init.d/wpad restart && wifi reload
```

---

## Что прислать, если что-то не так

```bash
apk list --installed | grep -E '^(wpad|hostapd|usteer)'; ubus list 'hostapd.*'; grep -hE '^(interface|bss|wpa_key_mgmt|mobility_domain|nas_identifier|rrm_neighbor_report|bss_transition)=' /var/run/hostapd-phy*.conf; logread | grep -iE 'hostapd|usteer' | tail -n 60
```
