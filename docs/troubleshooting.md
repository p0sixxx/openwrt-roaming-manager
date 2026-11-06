# Troubleshooting

Start with:

```bash
roamctl diag
```

```bash
roamctl -v detect
```

```bash
logread -e roamctl; logread -e hostapd | tail -n 50
```

The roamctl log is `/tmp/roamctl.log` (secrets are masked).

## Setup was rolled back

`roamctl` restores the previous configuration when a health check fails
after `wifi reload`. The reason is printed (`health: ...`) and stored in
`/etc/roamctl/last_rollback`.

| Message | Meaning / action |
|---|---|
| `hostapd: only N of M BSS active after reload` | hostapd rejected the new configuration on a radio. Check `logread -e hostapd` for "unknown configuration item" or "Line N"; run `roamctl detect` to see the detected hostapd features. Try `--no-11r` to isolate. |
| `wireless: radioX was up before and is down now` | same as above for a whole radio |
| `network: default gateway unreachable after change` | the bridge/uplink did not recover; check the wired uplink |
| `uci commit failed` | flash full or read-only overlay (`df -h /overlay`) |

## Watchdog / pending change

`roamctl status` shows `WARNING: an unconfirmed change is pending` while
a change is being verified. If the device rebooted in that state the
previous configuration is restored automatically at boot.

## "No interface eligible for roaming"

* The interface is disabled, not in `ap` mode, open/OWE or detected as
  guest/IoT/isolated. `roamctl detect` lists the reason per interface.
* Include it explicitly: `roamctl setup --include <section>`.

## SSID conflicts

`SSID 'X': passphrase differs between interfaces` or `security mode
differs`: roaming requires identical SSID, security and passphrase on all
interfaces (and APs) of a group. roamctl never changes passphrases; make
them identical in LuCI and run `roamctl setup` again.

## Mobility Domain conflicts

```bash
roamctl mdid show
```

```bash
roamctl mdid random <group> && roamctl multiap sync
```

## 802.11r enabled but clients do a full reconnect

* Check `roamctl test live --client <mac>`: "full 4-way handshake
  observed" means the client does not use FT.
* For SAE/EAP groups verify that all APs are on the same L2 network
  (R0KH/R1KH frames, ethertype 0x890d, travel over the bridge) and that
  `roamctl multiap check` reports consistent FT keys.
* Some clients refuse FT-SAE; WPA2-PSK FT is the most compatible mode.

## Steering does nothing

* `roamctl steer status` — backend running?
* Most steering is BTM based; clients without BTM (see the client survey
  in `roamctl diag`) are never forced in the default profile.
* usteer: `ubus call usteer remote_info` must show the other APs in
  multi-AP setups (UDP 16720 must be allowed on the LAN bridge).

## Multi-AP

| Symptom | Action |
|---|---|
| `unreachable over SSH` | `roamctl multiap copy-id <host>`; check dropbear runs on the member; `ssh root@<host>` from the controller |
| `roamctl: not found` on the member | `roamctl multiap install <name>` |
| `different passphrase - not merged` | align SSID/security/passphrase on the member |
| `apply failed ... rolled back` | the member's own health check failed; log in and inspect `logread -e roamctl` there |

## Package installation fails

The reason is recorded and shown (`no internet connectivity`, `DNS
resolution failed`, `package not available in configured feeds`). Roaming
features are configured anyway; steering falls back to the native backend.
