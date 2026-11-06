# Architecture

roamctl is written in POSIX shell for BusyBox ash (OpenWrt) and dash.
`local` is used for function variables (supported by ash, dash and bash,
and used throughout OpenWrt's own shell libraries). There are no
dependencies beyond what every OpenWrt image ships: BusyBox, `uci`,
`ubus`, `iwinfo`; `iw` is optional (more hardware detail).

## Layout

```
roamctl                     CLI: argument parsing, commands, menu, agent, daemon
core/
  common.sh                 paths ($ORM_SYSROOT aware), atomic writes, locking,
                            key/value store, CSPRNG, validation helpers
  logger.sh                 levels, colours, syslog, secret masking, progress
  json.sh                   awk JSON flattener (no jsonfilter dependency)
  report.sh                 PASS/WARN/FAIL/NOT SUPPORTED/NOT TESTED records
  system_detect.sh          release, package manager, board, SoC, kernel
  hardware_detect.sh        wiphys, drivers (softmac/fullmac), bands, standards, radios
  wireless_detect.sh        wifi-iface sections, security family, BSSIDs, runtime ifnames
  compatibility.sh          six layer capability decision per BSS
  package_manager.sh        opkg/apk, preflight, idempotent install, backend replace
  config_engine.sh          change plan, journal of original values, group detection
  backup_manager.sh         verified backups, restore, retention, service state
  rollback_manager.sh       health checks, transactions, watchdog, boot check
  orchestrator.sh           setup/repair/agent pipeline, summary
roaming/
  mobility_domain.sh        MDID generation, persistence, adoption, conflicts, scan
  ieee80211k.sh             RRM options, client RRM capability decoding
  ieee80211v.sh             BTM options, BTM requests, client BTM capability
  ieee80211r.sh             FT options per key model
  neighbor_report.sh        neighbor DB, validation, install, self-healing
  roaming_validator.sh      verification against the running hostapd
steering/
  backend_interface.sh      backend API and dispatcher
  steering_manager.sh       selection, exclusivity, installation, fallback
  steering_optimizer.sh     per band parameters from profile/topology/noise/load
  policy.sh                 native decision engine (pure logic, unit tested)
  usteer_backend.sh         usteer
  dawn_backend.sh           DAWN
  native_backend.sh         built-in BTM steering
  band_steering.sh          band preference, client include/exclude lists
multiap/
  ssh_manager.sh            key based SSH (OpenSSH/dropbear), fixed agent verbs
  key_manager.sh            FT key models and storage
  topology_manager.sh       member APs, probing, consistency checks
  ap_discovery.sh           over-the-air and LAN discovery
  ap_sync.sh                payload, staged rollout, neighbor distribution
diagnostics/                hardware, packages, config, hostapd, steering,
                            connectivity, client survey and live test
config/defaults.conf        base parameters; config/profiles/*.conf
files/roamctl.init          procd service (boot check, daemon)
install/                    installer / uninstaller
tests/                      mock OpenWrt, unit/integration/regression tests
```

## Data flow

1. **Detection** (`detect_everything`) writes facts into a capability
   store (`/var/run/roamctl/caps`, `key=value`). Run-scoped facts
   (`run.*`) survive re-detection within one invocation.
2. **Compatibility** (`compat_eval_iface`) decides `can_11k`, `can_11v`,
   `can_11r` and FT modes for every interface and stores a reason for
   each negative decision:

   | Layer | Source |
   |---|---|
   | hardware | `iw phy` "Supported interface modes: AP" |
   | driver | `/sys/class/ieee80211/<phy>/device/driver` → softmac/fullmac |
   | kernel | `/sys/module/mac80211` |
   | backend | installed wpad/hostapd package, option names known by the netifd handler (`/lib/netifd/hostapd.sh` ≤ 23.05, ucode `/usr/share/ucode/wifi`, schema `/usr/share/schema`) |
   | hostapd | `hostapd -v<feature>` (OpenWrt patch, used by LuCI), ubus methods of the running BSS (`rrm_nr_*`, `bss_transition_request`) |
   | BSS | security family (psk, sae, sae-mixed, eap, owe, open) |

3. **Groups**: candidate interfaces (eligible, not guest/IoT/open unless
   included) grouped by SSID; security and passphrase fingerprint must be
   identical, otherwise the SSID is reported as a conflict.
4. **Pending groups** (`/var/run/roamctl/groups.pending`): MDID, origin,
   FT key model and per-feature flags. Nothing is written yet.
5. **Plan**: `plan_set`/`plan_list`/`plan_del` collect UCI changes for
   `wireless`, `roamctl`, `usteer`/`dawn`; unchanged values are skipped
   (idempotency). The plan is shown before confirmation; secrets are
   masked.
6. **Transaction** (`transaction_apply`): baseline → backup → pending
   marker → detached watchdog → UCI set (journaled) → commit → post hook
   (steering services) → `wifi reload` → settle → health check →
   confirm, or restore immediately.
7. **Post**: neighbor DB collection (always) and installation (static
   mode), validation against the running hostapd, diagnostics, summary.

## Persistent state

| Path | Content |
|---|---|
| `/etc/config/roamctl` | global settings, groups (`config group`), member APs (`config ap`), steering parameters |
| `/etc/roamctl/journal` | original value of every option roamctl changed, packages it installed, service states (mode 600) |
| `/etc/roamctl/keys/` | FT keys, DAWN secret (dir 700, files 600) |
| `/etc/roamctl/ssh/` | controller SSH identity and pinned host keys (700) |
| `/etc/roamctl/backups/` | backups (700) |
| `/etc/roamctl/neighbors.db` | neighbor report database |
| `/etc/roamctl/pending` | unconfirmed change marker (boot-time rollback) |
| `/var/run/roamctl/` | capability store, report, lock, daemon pid (RAM) |
| `/tmp/roamctl.log` | log (RAM, secrets masked) |

## Extending

* **New steering backend**: add `steering/<name>_backend.sh` implementing
  the operations listed in `backend_interface.sh`, add the name to
  `STEER_BACKENDS` and source the file in `roamctl`.
* **New hardware/driver**: add the driver name to `hw_driver_class`
  (softmac/fullmac) and the SoC compatible to `sysdet_soc`; capabilities
  are still decided by runtime probes.
* **New UCI option**: add it to `compat_detect_uci_opts`; write it only
  when `uciopt.<name>` is not `0`.
