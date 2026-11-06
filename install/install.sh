#!/bin/sh
# OpenWrt Roaming Manager installer
#
#   sh install/install.sh            install from this source tree
#   sh install/install.sh --prefix /tmp/root   (staging / testing)
#
# Installs:
#   /usr/lib/roamctl/   modules, profiles, defaults, uninstaller
#   /usr/sbin/roamctl   command
#   /etc/init.d/roamctl service (boot-time rollback check, daemon)
# Nothing in /etc/config is changed and no package is installed: run
# "roamctl setup" afterwards.

set -e
SRC=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=''
while [ $# -gt 0 ]; do
	case "$1" in
	--prefix) PREFIX=$2; shift ;;
	-h | --help) sed -n '2,13p' "$0"; exit 0 ;;
	*) echo "unknown option $1" >&2; exit 1 ;;
	esac
	shift
done

LIB="$PREFIX/usr/lib/roamctl"
echo "Installing OpenWrt Roaming Manager $(sed -n 's/^ORM_VERSION="\(.*\)"/\1/p' "$SRC/core/common.sh") to ${PREFIX:-/}"

[ -f "$SRC/roamctl" ] && [ -d "$SRC/core" ] || { echo "source tree incomplete" >&2; exit 1; }

# fresh copy of the code; configuration and state are untouched
rm -rf "$LIB.new"
mkdir -p "$LIB.new"
for d in core roaming steering multiap diagnostics config install files; do
	cp -R "$SRC/$d" "$LIB.new/"
done
cp "$SRC/roamctl" "$LIB.new/roamctl"
cp "$SRC/LICENSE" "$LIB.new/" 2>/dev/null || true
find "$LIB.new" -type f -name '*.sh' -exec chmod 644 {} \;
chmod 755 "$LIB.new/roamctl" "$LIB.new/install/install.sh" "$LIB.new/install/uninstall.sh"
rm -rf "$LIB.old"
[ -d "$LIB" ] && mv "$LIB" "$LIB.old"
mv "$LIB.new" "$LIB"
rm -rf "$LIB.old"

mkdir -p "$PREFIX/usr/sbin" "$PREFIX/etc/init.d"
cat >"$PREFIX/usr/sbin/roamctl.tmp" <<'EOF'
#!/bin/sh
ORM_ROOT=/usr/lib/roamctl
export ORM_ROOT
exec /usr/lib/roamctl/roamctl "$@"
EOF
chmod 755 "$PREFIX/usr/sbin/roamctl.tmp"
mv -f "$PREFIX/usr/sbin/roamctl.tmp" "$PREFIX/usr/sbin/roamctl"
cp "$SRC/files/roamctl.init" "$PREFIX/etc/init.d/roamctl"
chmod 755 "$PREFIX/etc/init.d/roamctl"

# keep the program across sysupgrade (configuration in /etc/config is
# kept by default)
if [ -d "$PREFIX/lib/upgrade/keep.d" ] || [ -z "$PREFIX" ]; then
	mkdir -p "$PREFIX/lib/upgrade/keep.d"
	printf '/usr/lib/roamctl/\n/usr/sbin/roamctl\n/etc/init.d/roamctl\n/etc/roamctl/\n' >"$PREFIX/lib/upgrade/keep.d/roamctl"
fi

if [ -z "$PREFIX" ]; then
	/etc/init.d/roamctl enable 2>/dev/null || true
fi
echo "Done. Next step: roamctl setup   (or 'roamctl audit' to only analyse)"
