#!/bin/sh
# POSIX syntax check with every available shell (dash, BusyBox ash, bash --posix)
cd "$(dirname "$0")/../.." || exit 1
rc=0
files="roamctl install/install.sh install/uninstall.sh files/roamctl.init $(ls core/*.sh roaming/*.sh steering/*.sh multiap/*.sh diagnostics/*.sh)"
for sh in dash "busybox ash" "bash --posix"; do
	set -- $sh
	command -v "$1" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
	for f in $files; do
		$sh -n "$f" 2>/dev/null || { echo "syntax error ($sh): $f"; $sh -n "$f"; rc=1; }
	done
	echo "syntax OK: $sh"
done
# Bash-only constructs that would break BusyBox ash
if grep -nE '(^|[;&|[:space:]])\[\[[[:space:]]|^function |<<<|\$\{[a-zA-Z_]+\[|(^|[;&|[:space:]])(declare|source|typeset) |\$\{[^}]*(,,|\^\^)' $files | grep -v ':[[:space:]]*#'; then
	echo "bash-only syntax found"; rc=1
fi
exit $rc
