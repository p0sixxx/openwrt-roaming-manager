#!/bin/sh
# Verify repository structure and module wiring.
cd "$(dirname "$0")/../.." || exit 1
rc=0
for f in roamctl README.md README_RU.md CHANGELOG.md CONTRIBUTING.md SECURITY.md LICENSE \
	install/install.sh install/uninstall.sh files/roamctl.init config/defaults.conf \
	config/profiles/balanced.conf docs/architecture.md docs/compatibility.md docs/troubleshooting.md \
	docs/testing.md docs/multi-ap.md .github/workflows/ci.yml .github/workflows/release.yml; do
	[ -f "$f" ] || { echo "missing: $f"; rc=1; }
done
[ -x roamctl ] || { echo "roamctl not executable"; rc=1; }
# every module sourced by roamctl exists and every module is sourced
for m in $(sed -n '/^for _m in /,/; do$/p' roamctl | grep -o '[a-z_]*/[a-z0-9_]*\.sh'); do
	[ -f "$m" ] || { echo "roamctl sources missing module $m"; rc=1; }
done
for m in core/*.sh roaming/*.sh steering/*.sh multiap/*.sh diagnostics/*.sh; do
	grep -q "$m" roamctl || { echo "module $m is not loaded by roamctl"; rc=1; }
done
# version consistency
v=$(sed -n 's/^ORM_VERSION="\(.*\)"/\1/p' core/common.sh)
grep -q "^## \[$v\]" CHANGELOG.md || { echo "CHANGELOG.md has no entry for $v"; rc=1; }
printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version $v is not SemVer"; rc=1; }
[ "$rc" = 0 ] && echo "structure OK (version $v)"
exit $rc
