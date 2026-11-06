# Compatibility

## Verification status — read first

| Platform | Scenario | Verified in mock environment | Verified on real hardware |
|---|---|---|---|
| MediaTek Filogic 830 (MT7986, mt7915e), OpenWrt 24.10, opkg | `filogic-2410` | yes | **no** |
| MediaTek Filogic 820 (MT7981, mt7915e), OpenWrt 25.12, apk | `filogic-25` | yes | **no** |
| MediaTek Filogic 880 (MT7988 + MT7996, 6 GHz, WPA3) | `filogic-mt7988-6g` | yes | **no** |
| Qualcomm IPQ8074 (ath11k), full wpad | `qualcomm-ipq807x` | yes | **no** |
| Broadcom BCM2711 (brcmfmac, fullmac) | `broadcom-rpi4` | yes (reported as not supported) | **no** |
| Qualcomm Atheros ath79 (ath9k/ath10k), OpenWrt 22.03 | `legacy-2203` | yes (best effort) | **no** |
| MediaTek MT7987 | detection only | partially | **no** |

The mock environment emulates `uci`, `ubus`, `iw`, `iwinfo`, hostapd,
netifd (`wifi`), `opkg`, `apk`, `logread`, `ping`, `ssh`. It reproduces
the documented interfaces of OpenWrt but it is not a substitute for real
hardware. Please report results from real devices (see CONTRIBUTING.md).

## OpenWrt releases

| Release | Package manager | netifd wireless handler | Status |
|---|---|---|---|
| 25.x / SNAPSHOT | apk (apk-tools v3) | ucode (`/usr/share/ucode/wifi`), JSON schema | supported |
| 24.10 | opkg | ucode, JSON schema | supported |
| 23.05 | opkg | shell (`/lib/netifd/hostapd.sh`) | best effort |
| 22.03 | opkg | shell | best effort |
| ≤ 21.02 | opkg | shell | unsupported |

Differences handled:

* opkg vs apk (`list-installed` vs `list --installed`, `install` vs
  `add`, `download` vs `fetch`).
* Legacy shell handlers honour `bss_transition` only together with
  `ieee80211v=1`; roamctl writes both when the handler knows them.
* The set of UCI options is read from the installed handler; options the
  handler does not know are never written.

## hostapd / wpad variants

| Package | 802.11r | 802.11k | 802.11v | SAE | EAP |
|---|---|---|---|---|---|
| `wpad-basic-mbedtls` / `-wolfssl` / `-openssl` | yes | yes | yes | yes | no |
| `wpad-mbedtls` / `wpad-openssl` / `wpad-wolfssl` (full) | yes | yes | yes | yes | yes |
| `wpad-mini` / `hostapd-mini` | no | no | no | no | no |

The table reflects OpenWrt's build configuration, but roamctl never
relies on it: it probes `hostapd -v11r`, `-vsae`, `-veap` and the ubus
methods exported by the running daemon. Replacing the backend (e.g.
`wpad-mini` → `wpad-basic-mbedtls`) is only done on explicit request
(`roamctl backend replace <pkg>`), with confirmation, downloading the new
package before removing the old one.

## Drivers

| Class | Examples | 802.11k/v/r in AP mode |
|---|---|---|
| softmac (mac80211) | mt76 (mt7603e, mt7615e, mt76x2e, mt7915e, mt7921, mt7996e), ath9k, ath10k, ath11k, ath12k, rtw88, rtw89, mwlwifi | yes (hostapd implements MLME) |
| fullmac | brcmfmac, mwifiex | no (authentication in firmware) |
| unknown | anything else | decided by runtime probes only |

## Security modes

| UCI `encryption` | Family | FT AKM | FT key model |
|---|---|---|---|
| `psk2`, `psk2+ccmp`, `psk-mixed` | psk | FT-PSK | `ft_psk_generate_local=1` (or shared with `--ft-key-mode shared`) |
| `sae` | sae | FT-SAE | R0KH/R1KH shared key |
| `sae-mixed`, `psk2+sae` | sae-mixed | FT-PSK + FT-SAE | R0KH/R1KH shared key |
| `wpa2`, `wpa3` (EAP) | eap | FT-EAP | R0KH/R1KH shared key (RADIUS must be reachable from every AP) |
| `owe`, `none` | owe/open | — | FT not applicable; interface skipped unless included for 11k/v |
| `wep` | wep | — | unsupported |

## Steering backends

| Backend | Package | OpenWrt feed | Notes |
|---|---|---|---|
| usteer | `usteer` | core packages | default; options verified through `ubus call usteer get_config`; `aggressiveness` (newer versions) is used to restrict steering to BTM recommendations |
| DAWN | `dawn` | packages feed | alternative; option names located in the installed `/etc/config/dawn` |
| native | built in | — | used when no package can be installed |

## Client compatibility notes

* Apple iOS/macOS, Android ≥ 9 and Windows 10/11 with current drivers
  support 802.11k/v/r with WPA2-PSK; FT-SAE support varies by vendor.
* Some older clients (and some IoT chipsets) fail to associate when FT
  AKMs are advertised. Keep such devices on a separate SSID or exclude the
  interface (`--exclude`).
* FT over the DS is disabled by default because of poor client support.
