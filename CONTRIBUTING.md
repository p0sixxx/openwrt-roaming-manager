# Contributing

Thank you for helping! Reports from real hardware are especially welcome.

## Ground rules

* POSIX shell for BusyBox ash and dash. `local` is allowed (and required
  for every function variable — a regression test enforces it). No Bash
  features (`[[ ]]`, arrays, `<<<`, `${x,,}`, `source`, `function`).
* Use POSIX regex classes (`[[:blank:]]`) — musl/BusyBox `sed` does not
  support `\t` in brackets or `\|`.
* Never use unsafe `eval`, never put secrets in logs, arguments or the
  repository. Validate everything that comes from users or remote APs.
* Never enable a feature based on a UCI option alone: add a capability
  probe and a validation against the running system.
* Every change needs tests in the mock environment; never add a test that
  passes without checking a real condition.

## Workflow

1. Fork, create a feature branch (`feat/...`, `fix/...`).
2. Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`,
   `ci:`).
3. Run locally:

   ```bash
   shellcheck -x roamctl core/*.sh roaming/*.sh steering/*.sh multiap/*.sh diagnostics/*.sh install/*.sh
   ```

   ```bash
   tests/ci/check_syntax.sh && tests/ci/check_structure.sh && tests/ci/check_secrets.sh
   ```

   ```bash
   tests/run.sh && tests/run.sh --busybox
   ```

4. Open a pull request against `main`; CI must be green.

## Reporting hardware results

Open an issue with: device, OpenWrt version, `roamctl detect --raw`,
`roamctl diag` and, if possible, `roamctl test live` output. Remove
BSSIDs/SSIDs if you consider them private.

## Releases

Version in `core/common.sh` (`ORM_VERSION`, SemVer) and a matching
`CHANGELOG.md` entry; pushing tag `vX.Y.Z` runs the full verification and
publishes the release. No release is created when a check fails.
