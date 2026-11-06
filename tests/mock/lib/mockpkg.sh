#!/bin/sh
# Mock opkg / apk. State: $MOCK_DIR/pkg/{installed,available}; network
# availability: $MOCK_DIR/net/internet + net/dns.
pm=$1; shift
P="$MOCK_DIR/pkg"
mkdir -p "$P"; touch "$P/installed" "$P/available"
online() { [ -f "$MOCK_DIR/net/internet" ] && [ -f "$MOCK_DIR/net/dns" ]; }
avail() { grep -qx "$1" "$P/available"; }
log() { echo "$pm $*" >>"${MOCK_LOG:-/dev/null}"; }
install_pkg() {
	grep -qx "$1" "$P/installed" || echo "$1" >>"$P/installed"
	"$MOCK_LIB/postinst.sh" "$1"
}
cmd=$1; shift
log "$cmd $*"
case "$pm:$cmd" in
opkg:list-installed) while read -r p; do echo "$p - 1.0-r1"; done <"$P/installed" ;;
apk:list)
	case "$1" in
	--installed) while read -r p; do echo "$p-1.0-r1 aarch64_cortex-a53 {$p} (GPL-2.0) [installed]"; done <"$P/installed" ;;
	--available) avail "$2" && echo "$2-1.0-r1 aarch64_cortex-a53 {$2} (GPL-2.0)" ;;
	esac ;;
opkg:update | apk:update)
	online || { echo "Failed to download the package list" >&2; exit 1; }
	touch "$P/updated" ;;
opkg:list) [ -f "$P/updated" ] && avail "$1" && echo "$1 - 1.0-r1 - description" ;;
opkg:info) avail "$1" && printf 'Package: %s\nVersion: 1.0-r1\nArchitecture: %s\n' "$1" "$(cat "$MOCK_DIR/pkgarch" 2>/dev/null || echo aarch64_cortex-a53)" ;;
opkg:install | apk:add)
	for p in "$@"; do
		case "$p" in -*) continue ;; esac
		online || { echo "Unknown package '$p'." >&2; exit 255; }
		grep -qx "$p" "$P/install_fail" 2>/dev/null && { echo "Collected errors: $p" >&2; exit 255; }
		avail "$p" || { echo "Unknown package '$p'." >&2; exit 255; }
		install_pkg "$p"
	done ;;
opkg:remove | apk:del)
	for p in "$@"; do grep -vx "$p" "$P/installed" >"$P/i.tmp"; mv "$P/i.tmp" "$P/installed"; done ;;
opkg:download) online && avail "$1" && touch "$1_1.0-r1.ipk" ;;
apk:fetch) online && avail "$3" && touch "$2/$3-1.0-r1.apk" ;;
*) echo "mock $pm: unsupported $cmd" >&2; exit 1 ;;
esac
exit 0
