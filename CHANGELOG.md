# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
