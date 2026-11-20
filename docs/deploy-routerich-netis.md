# Установка: Routerich AX3000 v1 + Netis NX30 V2 (OpenWrt 25.12)

Схема: **Routerich AX3000 v1** — главный роутер и контроллер roamctl,
**Netis NX30 V2** — вторая точка доступа («тупая» AP). Оба на MediaTek
MT7981B с драйвером `mt7915e` и `wpad-basic-mbedtls`, ванильная OpenWrt
25.12. Это первый запуск roamctl на реальном железе, поэтому делаем
всё по кабелю и по шагам.

Тот же результат без roamctl, только `apk`/`uci`/`wifi`:
[manual-setup-routerich-netis.md](manual-setup-routerich-netis.md).

## 0. Что проверено заранее

Логика roamctl сверена с исходниками OpenWrt 25.12, hostapd, usteer и
LuCI:

* ucode-скрипты Wi-Fi 25.12 знают `ieee80211r`, `mobility_domain`,
  `ft_over_ds` (по умолчанию 0), `ft_psk_generate_local`, `r0kh`/`r1kh`,
  `nasid`, `ieee80211k`, `bss_transition`; опции `ieee80211v` в 25.12 нет
  (roamctl её не пишет);
* конфиг hostapd пишется в `/var/run/hostapd-phyN.conf`;
* `hostapd -v11r` / `-vsae` проверяются так же, как это делает LuCI;
* ubus-методы hostapd (`rrm_nr_get_own`, `rrm_nr_set`,
  `bss_transition_request`, `get_clients`) и их параметры совпадают;
* usteer сам раздаёт соседей 802.11k (`rrm_nr_set`). В usteer из фида
  25.12 (2025-10-04) **нет опции `aggressiveness`**, а его триггер
  роуминга между точками (`roam_scan_snr`/`roam_trigger_snr`) после BTM
  отключает клиента через 10 с — даже не поддерживающего BTM. Поэтому
  roamctl в профилях кроме `aggressive` этот триггер выключает: usteer
  раздаёт списки соседей и мягко (BTM без отключения) переводит клиентов
  с 2.4 на 5 ГГц, а переход между точками выбирает сам клиент (802.11k +
  быстрый 802.11r);
* **`wpad-basic-mbedtls` (стоит в образе по умолчанию) собран без WNM**
  (`#CONFIG_WNM=y` в `hostapd-basic.config`): нет 802.11v и BTM-steering.
  Поэтому roamctl **удаляет `wpad-basic-mbedtls` и ставит полный
  `wpad-mbedtls`** на обеих точках (сначала скачивает оба пакета через
  `apk fetch`, при отказе удаляет старый принудительно, ставит новый из
  файла с `--allow-untrusted` — OpenWrt подписывает только индекс, файл
  сверен с ним при скачивании; при любой ошибке ставит basic обратно из
  скачанного файла без сети и восстанавливает конфигурацию). Отключить:
  `--keep-wpad`.

Сценарий «Routerich + NX30» прогнан в тестовой среде (WPA2 и WPA2/WPA3).

## 1. Подготовка сети

Адреса: Routerich — `192.168.73.1/24` (шлюз, DNS, DHCP), NX30 —
`192.168.73.3/24` без DHCP (до перенастройки — `192.168.1.1` по
умолчанию).

1. **Соедините NX30 с Routerich кабелем: LAN ↔ LAN** — после
   перенастройки NX30 (см. ниже). Беспроводной
   аплинк возможен, но не рекомендуется (при каждом изменении Wi-Fi он
   пропадает на 5–30 с).
2. Все дальнейшие действия выполняйте с ПК, **подключённого кабелем**.

### Routerich AX3000 (главный)

В LuCI → Network → Wireless задайте для обоих радио:

* одинаковые **SSID** и **пароль** (их же потом поставим на NX30);
* шифрование **WPA2-PSK** (`psk2`) — самый совместимый вариант для
  802.11r. WPA2/WPA3 (`sae-mixed`) тоже поддерживается: roamctl сам
  создаст общий ключ FT;
* **страна** (Country) — та же, что будет на NX30;
* каналы: 2,4 ГГц — 1, 6 или 11; 5 ГГц — например 36 (без DFS).

### Netis NX30 V2 (вторая точка)

Сначала, пока ПК в сети Routerich, убедитесь, что `192.168.73.3`
свободен: он вне пула DHCP Routerich (LuCI → Network → Interfaces → LAN
→ DHCP Server; например, при `start=100`, `limit=150` пул —
192.168.73.100–249) и не занят статической арендой. С ПК (Windows) адрес
не должен отвечать и не должен быть в ARP-таблице:

```bash
ping -n 2 192.168.73.3
```

```bash
arp -a
```

Затем подключите ПК кабелем к NX30 (по умолчанию 192.168.1.1, **до**
подключения к Routerich — иначе в сети окажется второй DHCP-сервер) и
выполните по SSH:

В 25.12 адрес LAN — список `адрес/префикс` (`list ipaddr
'192.168.1.1/24'`); без префикса netifd ставит маску /32 и точка теряет
связь с сетью. Поэтому старый адрес удаляется и новый добавляется с `/24`:

```bash
uci -q delete network.lan.ipaddr; uci -q delete network.lan.netmask; uci add_list network.lan.ipaddr='192.168.73.3/24'
```

```bash
uci set network.lan.gateway='192.168.73.1'
```

```bash
uci add_list network.lan.dns='192.168.73.1'
```

```bash
uci set dhcp.lan.ignore='1'
```

```bash
uci commit network && uci commit dhcp
```

```bash
/etc/init.d/odhcpd disable && /etc/init.d/odhcpd stop
```

Задайте на NX30 в LuCI Wireless те же **SSID, пароль, шифрование и
страну**, что на Routerich, но **другие каналы**: 2,4 ГГц — 11 (если на
Routerich 1), 5 ГГц — например 149 или 44 (не тот же, что на Routerich).

Перезагрузите NX30, подключите кабелем к LAN Routerich (WAN-порт NX30
не используется), подключите ПК к Routerich и проверьте с Routerich:

```bash
ping -c 3 192.168.73.3
```

С NX30 должен быть доступен интернет (нужен для установки usteer):

```bash
ssh root@192.168.73.3 'ping -c 2 downloads.openwrt.org'
```

Время на обоих должно совпадать (NTP включён по умолчанию).

## 2. Установка roamctl на Routerich

На Routerich (нужен интернет):

```bash
cd /tmp && wget -O roamctl.tar.gz https://github.com/p0sixxx/openwrt-roaming-manager/archive/refs/heads/claude/bold-brown-u5ufeu.tar.gz
```

```bash
tar -xzf roamctl.tar.gz && sh openwrt-roaming-manager-claude-bold-brown-u5ufeu/install/install.sh
```

Если `wget` не может скачать по HTTPS — скачайте архив на ПК и
передайте так (из папки с распакованным архивом на ПК):

```bash
tar -czf - . | ssh root@192.168.73.1 'mkdir -p /tmp/orm && tar -xzf - -C /tmp/orm && sh /tmp/orm/install/install.sh'
```

## 3. Анализ и настройка Routerich

```bash
roamctl audit
```

Проверьте в выводе:

* `Platform: MediaTek Filogic 820` (MT7981), драйверы `(softmac)`;
* `Capabilities: [+] 802.11k [+] 802.11v [+] 802.11r [+] FT-PSK`;
* в «Roaming groups» — ваш SSID и оба интерфейса (2,4 и 5 ГГц);
* в «Planned configuration changes» нет ничего про SSID, пароль, каналы.

Если всё так:

```bash
roamctl setup
```

roamctl заменит `wpad-basic-mbedtls` на `wpad-mbedtls` (Wi-Fi пропадёт
на несколько секунд), создаст backup, установит usteer, применит настройки,
перезапустит Wi-Fi (клиенты переподключатся) и проверит работу. Если
проверка не пройдёт — он сам вернёт прежнюю конфигурацию. Ожидаемый итог:
`802.11k/802.11v/802.11r: PASS`, `Live Roaming: NOT TESTED`.

## 4. Подключение NX30

```bash
roamctl multiap copy-id 192.168.73.3
```

(ssh один раз спросит пароль root NX30.)

```bash
roamctl multiap add nx30 192.168.73.3
```

(Сообщение «roamctl is not installed there» здесь нормально — следующий
шаг его устанавливает.)

```bash
roamctl multiap install nx30
```

```bash
roamctl multiap sync
```

```bash
roamctl multiap check
```

`sync` сначала обновит Routerich (usteer перейдёт из локального режима в
сетевой), затем на NX30 заменит `wpad-basic-mbedtls` на `wpad-mbedtls`,
настроит её в отдельной транзакции с собственным backup и откатом,
установит там usteer и раздаст списки соседей.
Ожидаемо: `PASS ap_nx30 wpad`, `PASS ap_nx30 synchronised`,
`MDID and FT keys consistent`.

Проверить пакет на обеих точках:

```bash
apk list --installed | grep -E '^(wpad|hostapd)'
```

Должен быть только `wpad-mbedtls-…`.

## 5. Проверка

На каждой точке:

```bash
roamctl diag
```

Соседи 802.11k (на Routerich должно быть 3 записи: свой второй диапазон и
два BSS NX30):

```bash
ubus call hostapd.phy1-ap0 rrm_nr_list
```

usteer видит вторую точку:

```bash
ubus call usteer remote_info
```

Живой тест с телефоном (MAC — в `roamctl diag`, раздел Client
capabilities, или в LuCI). Запустите на Routerich и пройдите с телефоном
от одной точки к другой:

```bash
roamctl test live --client aa:bb:cc:dd:ee:ff --duration 120 --ip 192.168.73.50
```

Хороший результат: переход `BSSID Routerich -> BSSID NX30`,
`FT used: reassociation without 4-way handshake`, короткий перерыв по
ping. Если `full 4-way handshake observed` — телефон не использует
802.11r (роуминг работает, но медленнее).

## 6. Если что-то пошло не так

* Откат последней настройки на конкретной точке (только Wi-Fi и
  роуминг, остальное не трогается):

  ```bash
  roamctl rollback
  ```

* Полностью убрать настройки roamctl:

  ```bash
  roamctl uninstall
  ```

  (на NX30 выполнить отдельно).

* Если потерян доступ по Wi-Fi — подключитесь кабелем: watchdog через
  3 минуты сам вернёт прежнюю конфигурацию, если изменение не было
  подтверждено.

## 7. Что прислать, если нужна помощь

Выполнить на проблемной точке и прислать вывод (пароли из конфига
hostapd отфильтрованы):

```bash
roamctl detect --raw; roamctl diag; logread | grep -E 'hostapd|usteer|roamctl' | tail -n 150
```

```bash
grep -vE 'passphrase|psk=|sae_password|r0kh|r1kh' /var/run/hostapd-phy*.conf
```
