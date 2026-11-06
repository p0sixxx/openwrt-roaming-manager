#!/bin/sh
# Fail if the repository contains private keys, tokens or real credentials.
cd "$(dirname "$0")/../.." || exit 1
rc=0
files=$(git ls-files 2>/dev/null || find . -type f ! -path './.git/*')
for f in $files; do
	[ -f "$f" ] || continue
	case "$f" in tests/ci/check_secrets.sh) continue ;; esac
	if grep -nE -- '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}' "$f"; then
		echo "possible secret in $f"; rc=1
	fi
	# long hex strings (FT keys) are only allowed in test fixtures
	case "$f" in tests/*) continue ;; esac
	if grep -nE '(^|[^0-9a-fA-F])[0-9a-f]{64}([^0-9a-fA-F]|$)' "$f"; then
		echo "256-bit hex string (key material?) in $f"; rc=1
	fi
done
# no real router configuration committed
for f in $files; do
	case "$f" in
	*/etc/config/* | etc/config/* | *.ftkey | */id_dropbear | */id_ed25519 | */known_hosts) echo "forbidden file: $f"; rc=1 ;;
	esac
done
[ "$rc" = 0 ] && echo "no secrets found"
exit $rc
