# Testing

## Automated tests (no hardware needed)

```bash
tests/run.sh                         # unit + integration + regression, /bin/sh
```

```bash
TEST_SH=dash tests/run.sh unit       # one suite with dash
```

```bash
tests/run.sh --busybox               # BusyBox ash and BusyBox applets
```

```bash
tests/run.sh --filter multiap        # tests whose path matches a pattern
```

Requirements: POSIX shell, awk, python3 (only for the netifd/hostapd
mock), and for `--busybox` the *dynamic* `busybox` package (the static
build prefers its own applets over `$PATH`, unlike OpenWrt's BusyBox).

### Mock OpenWrt

`tests/mock/` builds a complete fake root filesystem per test
(`$ORM_SYSROOT`) plus mocked tools in `$PATH`:

| Mock | Behaviour |
|---|---|
| `uci` | real UCI file format, staging (`changes`/`commit`/`revert`), lists, anonymous sections, `-X` |
| `ubus` | objects as directories, static or scripted methods, call log |
| `wifi` (netifd + hostapd) | generates `/var/run/hostapd-*.conf` like the netifd handler (ucode or legacy rules), `network.wireless status`, `hostapd.<if>` ubus objects with `rrm_nr_*`, BTM methods, clients; can reject options (`SC_REJECT`) |
| `hostapd` | `-v`, `-v<feature>` |
| `iw`, `iwinfo` | phy info, dev list, scan, station data |
| `opkg`, `apk` | installed/available lists, network dependent, install failures, post-install side effects (init scripts, configs) |
| `ssh` | runs the remote command against another mock AP; `down` and `drop_during_apply` failure modes |
| `ping`, `nslookup`, `ip`, `logread` | network state flags |

Scenarios (`tests/mock/scenarios/*.sh`): Filogic 24.10 (opkg), Filogic
25.12 (apk), MT7988 tri-band 6 GHz WPA3, Qualcomm ath11k, Broadcom
brcmfmac, OpenWrt 22.03 ath79. Tests override details with `FXO_SC_*`
variables (e.g. `FXO_SC_RRM=0` — hostapd without 802.11k).

### Covered situations

OpenWrt 24.10/25.x, Filogic, Qualcomm, Broadcom, one/two/three APs,
hostapd versions/handlers, missing 802.11k, 802.11v or 802.11r, package
install failure, no internet, UCI commit error, hostapd rejecting the
configuration (rollback), SSH loss during a multi-AP rollout, repeated
runs (idempotency), manual and watchdog rollback, boot-time recovery,
MDID conflicts, different passwords and encryption between interfaces
and APs, inconsistent FT parameters, no steering backend, unreachable AP,
guest/IoT protection, secrets never logged, special SSIDs, anonymous UCI
sections, live roaming detection.

## Testing on real access points

Use at least two OpenWrt 24.10/25.x APs on the same wired LAN and the
same SSID/passphrase, and a client that supports 802.11k/v/r (a current
phone or laptop).

1. Install roamctl on both APs (`install/install.sh`, or
   `roamctl multiap install` from the controller).
2. On AP 1: `roamctl audit`, then `roamctl setup`. Keep a wired or
   console connection the first time.
3. `roamctl multiap copy-id <AP2-IP>` and
   `roamctl multiap add ap2 <AP2-IP>`, then `roamctl multiap sync`.
4. `roamctl multiap check` and `roamctl diag` on both APs: all PASS.
5. Find the client MAC (`roamctl diag` client survey or
   `ubus call hostapd.<if> get_clients`).
6. Start `roamctl test live --client <mac> --duration 120 --ip <client-ip>`
   on AP 1 and walk with the client from AP 1 to AP 2 (or use `--steer`
   while the client is on AP 1).
7. Expected: a transition AP1 → AP2, "FT used: reassociation without 4-way
   handshake" (for FT capable clients), ping loss ≤ 1 interruption.
8. Optional: `tcpdump -i br-lan ether proto 0x890d` on an AP shows
   R0KH/R1KH exchanges for SAE/EAP groups.
9. Test rollback: `roamctl backup list`, `roamctl rollback`, then
   `roamctl repair`.

Please report the device, OpenWrt version, `roamctl detect --raw`
(remove BSSIDs if you prefer) and the live test output in an issue.
