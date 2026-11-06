# Multi-AP management

## Model

* One AP (or any Linux host with roamctl, `ssh`, and access to the APs)
  is the **controller**; the others are **members**. Each member runs its
  own roamctl ("agent"), so all checks and the transaction/rollback logic
  run locally on every AP.
* Members are stored in `/etc/config/roamctl` as `config ap` sections.
* The controller owns the roaming groups (SSID → MDID, FT key model,
  feature flags) and pushes them; members translate them into their own
  interfaces (matching SSID, verified security and passphrase).

## SSH

* Public key authentication only. The controller key is created in
  `/etc/roamctl/ssh` (OpenSSH ed25519 or dropbear format, depending on the
  installed client). `roamctl multiap copy-id <host>` appends it to the
  member's `/etc/dropbear/authorized_keys`; `ssh` itself asks for the
  password once — roamctl never receives or stores it.
* Host keys are pinned on first use (`accept-new` / dropbear `-y`) and
  verified afterwards.
* Remote commands are fixed `roamctl agent <verb>` calls with validated
  arguments. Secrets (FT keys, DAWN secret) travel on stdin of the
  encrypted session, never on the remote command line.

## Workflow

```bash
roamctl setup                          # controller
```

```bash
roamctl multiap discover               # optional: suggestions (scan + LAN)
```

```bash
roamctl multiap copy-id 192.168.1.3
```

```bash
roamctl multiap add office 192.168.1.3 --user root --port 22
```

```bash
roamctl multiap install office         # if roamctl is not installed there
```

```bash
roamctl multiap sync
```

```bash
roamctl multiap check
```

### What `sync` does

1. Refreshes the controller itself (steering parameters depend on the
   number of APs, e.g. usteer leaves local mode).
2. For each member, one after another:
   * probe (`agent info`): reachability, OpenWrt version, groups with
     security/passphrase fingerprints, MDID, FT key fingerprint;
   * compatibility check — different passphrase or security means the
     member is **not** merged (reported, untouched);
   * push the payload (`agent apply`): the member creates its own backup,
     arms its watchdog, applies, reloads wireless, runs health checks and
     confirms or rolls back;
   * on failure the rollout **stops**: the remaining members keep their
     working configuration.
   Unreachable members are skipped; nothing else is changed because of
   them.
3. Collects the own neighbor report of every BSS on every AP, merges them
   and distributes the database (`agent nr-own` / `agent nr-set`).

### Adding / removing APs

* New AP: `add` + `sync`. It receives the existing MDID and FT key of
  each group (never a new one).
* `roamctl multiap remove <name>` removes it from the controller and
  withdraws its neighbor entries from the other APs on the next sync
  (immediately on the controller).

### Periodic neighbor refresh (optional)

Neighbor lists follow channel changes automatically on each AP (daemon).
To propagate changes between APs regularly, add a cron job on the
controller:

```bash
echo '*/30 * * * * /usr/sbin/roamctl -q -y multiap sync --nr-only' >> /etc/crontabs/root && /etc/init.d/cron restart
```

## Requirements

* All APs on the same L2 network (bridge) for FT key exchange
  (R0KH/R1KH, ethertype 0x890d) and usteer/DAWN messages.
* Identical SSID, security mode and passphrase per roaming SSID.
* Synchronised clocks (NTP) for meaningful live test timelines.
