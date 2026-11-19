# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- MediaTek MT7621 (ramips) support as additional access points: SoC
  detection, `mt7603e`/`mt76x2e`/`mt7615e` drivers, mock scenarios for
  Xiaomi 4A Gigabit (24.10) and Redmi AC2100 (25.12), mixed
  Filogic + MT7621 multi-AP test.
- Device resource detection (CPU cores, RAM, free flash, device class).
- Free flash check before package installation and in the installer;
  fewer backup generations on nearly full flash.
- Members report the steering backend they actually use to the
  controller.

### Changed
- Detection and the native steering daemon no longer spawn a process
  per lookup: in-memory capability store, generation checked `uci show`
  cache, in-memory steering state saved once per tick. Detection uses
  ~70 % fewer processes; a steering tick ~50 instead of ~1700 processes
  for 10 clients.
- Random numbers use BusyBox `hexdump` (always present on OpenWrt),
  `od` only as a fallback.
- `roamctl rollback` / `backup restore` restore only what roamctl manages
  (wireless, roamctl, usteer, dawn, /etc/roamctl); `--full` restores all
  of /etc/config.

### Verified against OpenWrt 25.12 sources
- wifi-scripts (ucode) options, defaults and hostapd config path,
  hostapd ubus API, LuCI feature probing, usteer config keys and
  aggressiveness levels.

### Fixed (OpenWrt 25.12)
- Option support is read from the ucode schema when present; the unused
  legacy shell handler made roamctl write `ieee80211v`, which 25.12 does
  not have.
- `nasid` (R0KH-ID) is set from the BSSID in shared FT key mode
  (WPA3/SAE), as 25.12 sets no default.
- Corrected usteer documentation: noise floor per radio; the aggressive
  profile (usteer aggressiveness 2) does disconnect clients.

### Added
- Deployment guide and test for Routerich AX3000 v1 + Netis NX30 V2.
- `wpad-basic-*` / `wpad-mini` are built without WNM (no 802.11v / BTM
  steering, verified in hostapd-basic.config): `setup` and `multiap sync`
  now remove them and install the full variant with the same TLS library
  (`wpad-basic-mbedtls` -> `wpad-mbedtls`), downloading first, forcing
  the removal if needed, with backup, health check and automatic
  reinstallation of the old package on failure. `--keep-wpad` opts out.
- Guest/IoT detection matches whole SSID words only.

### Changed
- Capability and steering state are kept in one shell variable per key
  (sanitised names). String stores were 5-25 ms per lookup in dash/ash;
  now ~35 µs. setup is ~10x faster.

### Fixed (code audit)
- The daemon rewrote `/etc/roamctl/neighbors.db` on flash every minute;
  it is now written only when neighbor data changes, under a lock.
- APs with a wireless uplink (client/WDS/mesh) were always rolled back:
  the health check now waits for the gateway (30 s, 90 s with a wireless
  uplink) and warns beforehand.
- Daemon and CLI shared one capability file; each process now uses its
  own file, removed on exit.
- `/tmp/roamctl.log` is rotated at 256 KB.

## [1.0.0] - 2026-11-06

First release.

### Added
- `roamctl` CLI with interactive menu, `setup`, `advanced`, `audit`,
  `repair`, `diag`, `test live`, `status`, `detect`, `backup`,
  `rollback`, `uninstall`, `mdid`, `nr`, `steer`, `multiap`, `rf`,
  `backend replace`.
- Hardware, wireless and system detection (OpenWrt 24.10/25.x, opkg/apk,
  MediaTek Filogic, Qualcomm, Broadcom, softmac/fullmac drivers).
- Six layer compatibility engine with per-interface reasons.
- 802.11k (RRM, neighbor/beacon reports) with a validated neighbor report
  database built from real `rrm_nr_get_own` data.
- 802.11v BSS Transition Management.
- 802.11r FT over the air/DS, FT-PSK (`ft_psk_generate_local`), FT-SAE and
  FT-EAP with a random R0KH/R1KH group key.
- Mobility Domain Manager (CSPRNG, persistent, adoption, conflicts, scan).
- Steering engine: usteer (default), DAWN, native BTM backend with policy
  engine (per-band thresholds, hysteresis, cooldown, retry limit,
  ping-pong protection, client lists, band steering, load awareness),
  optimizer and profiles.
- Multi-AP: key based SSH, discovery, consistency checks, staged rollout,
  FT key and neighbor report distribution, remote installation.
- Backups with SHA-256 verification, change journal, commit-confirm
  transactions with detached watchdog, boot-time rollback, locking.
- Diagnostics with PASS/WARN/FAIL/NOT SUPPORTED/NOT TESTED and a live
  roaming test.
- Mock OpenWrt test environment, unit/integration/regression tests,
  GitHub Actions CI and release workflow.

### Known limitations
- Verified in the mock environment only; not yet verified on real
  hardware.

[Unreleased]: https://github.com/p0sixxx/openwrt-roaming-manager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/p0sixxx/openwrt-roaming-manager/releases/tag/v1.0.0
