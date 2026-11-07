# OpenWrt Roaming Manager (`roamctl`)

Seamless Wi-Fi roaming for OpenWrt in (almost) one step: `roamctl setup`
analyses the access point, decides what the hardware, driver and hostapd
build really support, shows a change plan, and — after confirmation —
configures **802.11k** (neighbor reports), **802.11v** (BSS transition
management), **802.11r** (fast BSS transition), client/band **steering**
and **multi-AP** synchronisation. Every change is backed up, applied
inside a transaction with a recovery watchdog and verified against the
running hostapd.

> **Important:** roaming is a client decision. roamctl configures the
> access points so that capable clients can roam quickly and are guided
> to better APs. It cannot force a client to roam, and it cannot promise
> loss-free transitions for clients that do not implement 802.11k/v/r.

[Русская версия](README_RU.md)

## Contents

- [Features](#features)
- [Compatibility](#compatibility)
- [Installation](#installation)
- [Quick start](#quick-start)
- [CLI](#cli)
- [How it works](#how-it-works)
- [802.11k / 802.11v / 802.11r](#80211k--80211v--80211r)
- [Mobility Domain and FT keys](#mobility-domain-and-ft-keys)
- [Steering (usteer, DAWN, native)](#steering-usteer-dawn-native)
- [Multi-AP](#multi-ap)
- [Backup, rollback and recovery](#backup-rollback-and-recovery)
- [Diagnostics](#diagnostics)
- [Uninstall](#uninstall)
- [Known limitations](#known-limitations)
- [Development and tests](#development-and-tests)

## Features

| Area | What roamctl does |
|---|---|
| Detection | OpenWrt release, package manager (opkg/apk), board, SoC (MediaTek Filogic MT7981/MT7986/MT7987/MT7988, Qualcomm IPQ, Broadcom, …), kernel, radios, bands, channels, drivers, BSSIDs, SSIDs, security |
| Compatibility engine | Six independent layers: hardware → driver (softmac/fullmac) → kernel → netifd handler/wpad package → hostapd build features and ubus methods → per-BSS security. A feature is enabled only if every layer agrees |
| 802.11k | `ieee80211k` (RRM, neighbor + beacon reports), real neighbor report entries collected from every BSS of the roaming group, kept up to date |
| 802.11v | `bss_transition` (+ `ieee80211v` for legacy handlers), BTM requests with ranked candidate lists |
| 802.11r | FT over the air (default) or over the DS, FT-PSK, FT-SAE, FT-EAP, `ft_psk_generate_local` or R0KH/R1KH shared key |
| Mobility Domain | CSPRNG MDID per roaming group, persisted, never regenerated, shared by all APs of the group, conflict detection (local, multi-AP, over the air) |
| Steering | usteer (default), DAWN (alternative) or the built-in native backend; per-band thresholds, hysteresis, cooldown, retry limit, ping-pong protection, client include/exclude lists, band steering, load awareness |
| Multi-AP | SSH key based management, discovery, consistency checks, staged rollout (one AP at a time), FT key and neighbor report distribution |
| Safety | Backup before every change, change journal, commit-confirm transactions with detached watchdog, boot-time rollback, lock against parallel runs, atomic file writes, secrets never logged |
| Diagnostics | Hardware, packages, configuration, running hostapd, 802.11k/v/r, steering, connectivity, client capability survey, live roaming test with a real client |

## Compatibility

| OpenWrt | Package manager | Status |
|---|---|---|
| 25.x / SNAPSHOT | apk | supported, tested in the mock environment |
| 24.10.x | opkg | supported, tested in the mock environment |
| 22.03 / 23.05 | opkg | best effort (legacy shell netifd handler) |
| ≤ 21.02 | opkg | not supported |

Hardware: any mac80211 (softmac) driver works. Primary targets are
MediaTek Filogic (MT7981, MT7986, MT7987, MT7988) for the main router and
**MediaTek MT7621 (ramips) for additional access points** (MT7603E,
MT7612E, MT7615E, MT7915E). On these MIPS devices roamctl checks free flash before installing packages, keeps
fewer backups, uses lighter daemon settings and avoids spawning
processes in its hot paths. Qualcomm ath9k/ath10k/ath11k/ath12k, Realtek
rtw88/rtw89 and others work as well. Fullmac drivers
(e.g. Broadcom `brcmfmac`) implement authentication in firmware: roamctl
reports 802.11r/k/v as *not supported* there instead of enabling them.

See [docs/compatibility.md](docs/compatibility.md) for the detailed
matrix, hostapd variants and what has (not) been verified on real
hardware.

## Installation

On the access point (about 250 KB of flash, no extra packages):

```bash
cd /tmp && wget -O roamctl.tar.gz https://github.com/p0sixxx/openwrt-roaming-manager/archive/refs/heads/main.tar.gz
```

```bash
tar -xzf roamctl.tar.gz && sh openwrt-roaming-manager-main/install/install.sh
```

From a release archive (recommended once released):

```bash
tar -xzf openwrt-roaming-manager-1.0.0.tar.gz && sh openwrt-roaming-manager-1.0.0/install/install.sh
```

From a workstation with a git checkout:

```bash
git clone https://github.com/p0sixxx/openwrt-roaming-manager.git
```

```bash
cd openwrt-roaming-manager && tar -czf - . | ssh root@192.168.1.1 'mkdir -p /tmp/orm && tar -xzf - -C /tmp/orm && sh /tmp/orm/install/install.sh'
```

The installer copies the program to `/usr/lib/roamctl`, creates
`/usr/sbin/roamctl` and the `roamctl` init service. It does not change
any configuration and installs no packages.

## Quick start

```bash
roamctl audit        # analyse only; shows exactly what setup would change
```

```bash
roamctl setup        # show plan, confirm, configure, verify
```

Non-interactive:

```bash
roamctl --yes setup
```

Example summary (statuses always reflect real checks):

```
==================================================
                 ROAMING SUMMARY
==================================================

802.11k:       ENABLED
802.11v:       ENABLED
802.11r:       ENABLED
FT Mode:       FT over the Air
Mobility ID:   A7C2
Steering:      ENABLED
Backend:       usteer

Configuration: PASS
Hostapd:       PASS
Connectivity:  PASS
802.11k:       PASS
802.11v:       PASS
802.11r:       PASS
Steering:      PASS

Live Roaming:  NOT TESTED

Backup:        CREATED (20261106-101734-b309)

CONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED
==================================================
```

## CLI

```
roamctl [options] [command]

setup | advanced | audit | repair | diag | status | detect
test live --client MAC [--duration S] [--ip IP] [--steer]
backup [create|list|verify ID|restore ID|delete ID] | rollback [ID]
uninstall
mdid [show|set GROUP HEX|random GROUP|scan]
nr [show|collect|apply]
steer [status|params|backend NAME|profile NAME|exclude MAC|include MAC|clear MAC]
multiap [list|add NAME HOST|remove NAME|copy-id HOST|install NAME|discover|status|sync|check]
rf [--apply]
backend replace PKG

-y/--yes  -n/--dry-run  -v/--verbose  -q/--quiet  --audit  --repair  --rollback
--profile conservative|balanced|aggressive|iot-safe
--backend auto|usteer|dawn|native|none   --ssid SSID
--include SECTION  --exclude SECTION  --no-11k --no-11v --no-11r
--ft-over-ds  --ft-key-mode auto|local|shared  --no-color  -V/--version  -h/--help
```

Without a command on a terminal, `roamctl` opens the interactive menu
(Automatic / Advanced / Audit / Repair / Multi-AP / Diagnostics /
Backup-Restore / Uninstall). Exit codes: `0` success, `1` error (changes
rolled back), `3` completed but diagnostics report a FAIL.

## How it works

```
detect ─► compatibility ─► roaming groups ─► plan ─► confirm
   ─► backup ─► packages ─► transaction (watchdog ─► UCI ─► wifi reload ─► health check)
   ─► confirm or rollback ─► neighbor reports ─► validation ─► summary
```

* **Roaming groups**: interfaces with the same SSID, security mode *and*
  passphrase (compared by fingerprint). Same SSID alone is not enough;
  conflicts are shown and never merged automatically.
* **Guest/IoT/isolated** interfaces and open/OWE networks are never
  touched unless included explicitly (`--include <section>`).
* SSID, passphrase, channel, width, TX power and country are never
  changed in the standard mode.
* Only UCI options the installed netifd handler understands are written,
  and the result is verified in the hostapd configuration that is
  actually running (`/var/run/hostapd-*.conf`) and via hostapd's ubus API.

Details: [docs/architecture.md](docs/architecture.md).

## 802.11k / 802.11v / 802.11r

* **802.11k**: `ieee80211k=1` → `rrm_neighbor_report=1`,
  `rrm_beacon_report=1`. Neighbor report entries come from
  `ubus call hostapd.<if> rrm_nr_get_own` of every BSS in the group
  (all bands, all APs); entries are validated (BSSID, operating class,
  channel, PHY type) and installed with `rrm_nr_set`, never including the
  BSS itself. With usteer/DAWN the backend distributes them; otherwise
  roamctl does (and re-installs them after hostapd restarts).
* **802.11v**: `bss_transition=1`. In the default profile BTM requests
  are *recommendations* without "disassociation imminent"; clients that
  do not support BTM are never disconnected.
* **802.11r**: `ieee80211r=1`, `mobility_domain`, `ft_over_ds=0`
  (over the air, best client compatibility; `--ft-over-ds` to change).
  WPA2-PSK uses `ft_psk_generate_local=1`; SAE, SAE/PSK mixed and EAP use
  R0KH/R1KH with a shared random key.

## Mobility Domain and FT keys

* MDID: 2 octets (4 hex chars) from `/dev/urandom` (getrandom-backed), one
  per roaming group, stored in `/etc/config/roamctl`, reused on every run,
  pushed to every member AP. `0000`, `ffff` and the hostapd example value
  are never used. An MDID already configured consistently on all member
  interfaces is adopted instead of being replaced.
* Conflicts: other roamctl groups, other local SSIDs, member APs, and —
  with `roamctl mdid scan` — nearby networks advertising the same MDID.
* Manual change: `roamctl mdid set <group> <hex4>` or
  `roamctl mdid random <group>` (then `roamctl multiap sync`).
* FT key (SAE/EAP): 256-bit random, `/etc/roamctl/keys/<group>.ftkey`
  (mode 600), written as wildcard `r0kh`/`r1kh` entries; transferred to
  member APs only on the stdin of the SSH session and compared by
  fingerprint. It is never printed or logged.

## Steering (usteer, DAWN, native)

| Backend | When | Notes |
|---|---|---|
| `usteer` | default | distributed, exchanges data over UDP 16720; roamctl writes only options reported by `ubus call usteer get_config` |
| `dawn` | `--backend dawn` | per-band metrics, encrypted inter-AP messages with a random group secret |
| `native` | fallback or `--backend native` | built-in policy engine using hostapd BTM directly |
| `none` | `--backend none` | roaming features only |

Only one steering daemon is ever active; a competing one is stopped and
disabled (its package is kept). Thresholds differ per band (2.4/5/6 GHz)
and are tuned by the optimizer for profile, AP count, measured noise and
load. Protection: time and signal hysteresis, cooldown, retry limit,
ping-pong detection, minimum association time. Band steering prefers
5/6 GHz for strong, dual-band capable clients and never disables 2.4 GHz.

```bash
roamctl steer params                      # effective per-band parameters
```

```bash
roamctl steer exclude aa:bb:cc:dd:ee:ff   # never steer this client
```

## Multi-AP

```bash
roamctl setup                         # on the controller AP
```

```bash
roamctl multiap copy-id 192.168.1.3   # install the controller key (ssh asks for the password)
```

```bash
roamctl multiap add office 192.168.1.3
```

```bash
roamctl multiap install office        # copy roamctl to the member if needed
```

```bash
roamctl multiap sync                  # staged rollout + neighbor reports
```

Members are changed **one at a time**, each inside its own transaction
with backup, watchdog and health check. The rollout stops at the first
failing AP; unreachable APs are skipped and reported. See
[docs/multi-ap.md](docs/multi-ap.md).

## Backup, rollback and recovery

* Backup of `/etc/config`, `/etc/roamctl`, standalone hostapd configs,
  package list, MDIDs and service state, with SHA-256 verification
  (`/etc/roamctl/backups`, mode 700, last 10 kept).
* Every change: backup → persistent *pending* marker → detached watchdog
  (`setsid`) → apply → health checks (hostapd BSSes, radios, UCI,
  gateway) → confirm. Failed checks restore the backup immediately; if
  roamctl dies (e.g. the SSH session over Wi-Fi drops) the watchdog
  restores it after the deadline (default 180 s); after a power loss the
  init script restores it at boot.

```bash
roamctl backup list
```

```bash
roamctl rollback                 # latest backup
```

## Diagnostics

```bash
roamctl diag
```

Statuses: `PASS`, `WARN`, `FAIL`, `NOT SUPPORTED`, `NOT TESTED` — every
line explains why. Checks use the running system (hostapd configuration
in use, ubus methods, installed neighbor lists, backend state), not just
UCI values.

Live roaming test (needs a real client and at least two BSSes):

```bash
roamctl test live --client aa:bb:cc:dd:ee:ff --duration 90 --ip 192.168.1.50
```

It records BSSID before/after, signal, association gap, ping loss and
longest interruption, and infers FT use from the hostapd log. Without a
client it reports `CONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED`.

## Uninstall

```bash
roamctl uninstall                         # revert configuration changes
```

```bash
sh /usr/lib/roamctl/install/uninstall.sh  # remove the program
```

`roamctl uninstall` restores the original value of every option roamctl
changed (from its journal), keeps unrelated later changes, restores
service states and offers to remove packages roamctl installed.

## Known limitations

* Roaming decisions are made by clients; many IoT devices ignore
  802.11k/v and some old clients mishandle 802.11r (exclude them or use
  a separate SSID).
* usteer thresholds are global (SNR based with per-band noise
  assumptions); per-client exclusion needs a usteer version with
  `aggressiveness_mac_list`.
* The native backend uses BTM only; it has no inter-AP signal
  measurements (beacon report collection is not used).
* The live test samples once per second; the association gap is an upper
  bound with 1 s resolution. Multi-AP live tests need synchronised clocks
  (NTP).
* MediaTek Filogic, MT7621, Qualcomm and Broadcom support has
  been verified in the mock environment only — **not yet on real
  hardware** (see [docs/compatibility.md](docs/compatibility.md)).
* If the flash is almost full usteer may not fit; roamctl then uses its
  built-in steering backend.

## Development and tests

```bash
tests/run.sh                 # all suites with /bin/sh
```

```bash
tests/run.sh --busybox       # BusyBox ash + BusyBox applets
```

See [docs/testing.md](docs/testing.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

License: [MIT](LICENSE).
