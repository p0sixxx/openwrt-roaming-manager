#!/bin/sh
# OpenWrt Roaming Manager - remove the program
#
# Run "roamctl uninstall" first to revert the roaming configuration.
# This script removes the program files only; backups in
# /etc/roamctl/backups are kept unless --purge is given.

PREFIX=''
PURGE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--prefix) PREFIX=$2; shift ;;
	--purge) PURGE=1 ;;
	*) echo "unknown option $1" >&2; exit 1 ;;
	esac
	shift
done

if [ -z "$PREFIX" ] && [ -f /etc/config/roamctl ]; then
	echo "Roaming configuration still active. Run 'roamctl uninstall' first." >&2
	exit 1
fi
[ -z "$PREFIX" ] && [ -x /etc/init.d/roamctl ] && {
	/etc/init.d/roamctl stop 2>/dev/null
	/etc/init.d/roamctl disable 2>/dev/null
}
rm -f "$PREFIX/usr/sbin/roamctl" "$PREFIX/etc/init.d/roamctl" "$PREFIX/lib/upgrade/keep.d/roamctl"
rm -rf "$PREFIX/usr/lib/roamctl" "$PREFIX/var/run/roamctl"
if [ "$PURGE" = 1 ]; then
	rm -rf "$PREFIX/etc/roamctl"
	echo "Removed roamctl and its backups."
else
	echo "Removed roamctl. Backups kept in /etc/roamctl/backups (use --purge to delete)."
fi
