# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's
private vulnerability reporting ("Security" → "Report a vulnerability")
for `p0sixxx/openwrt-roaming-manager`. You will get an answer within
7 days.

## Security design

* **Secrets**: FT R0KH/R1KH keys (256-bit, kernel CSPRNG) and the DAWN
  secret are stored in `/etc/roamctl/keys` (dir 0700, files 0600). They
  also appear in `/etc/config/wireless` / `/etc/config/dawn`, like the
  Wi-Fi passphrase itself; roamctl keeps `/etc/config/wireless` at 0600
  when restoring it. Secrets are never printed, logged (a masking filter
  is applied to all log output) or passed as command line arguments.
* **Multi-AP**: public key SSH only; host keys pinned on first use; the
  remote side only runs fixed `roamctl agent` verbs with validated
  arguments; secrets are transferred on stdin of the encrypted session;
  passphrases are compared between APs by truncated SHA-256 fingerprints,
  never transferred.
* **Input validation**: host names, user names, ports, MAC addresses,
  section names, MDIDs, keys and the multi-AP payload are validated
  before use; no `eval` on external data.
* **Safe changes**: backups, journal, commit-confirm transactions with a
  detached watchdog and boot-time rollback protect against losing access
  to the device.
* **Steering**: the default profile never deauthenticates clients;
  forced disconnects require an explicit `kick_mode=deauth`.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | yes |
