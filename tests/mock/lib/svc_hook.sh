#!/bin/sh
# Service side effects: ubus objects of steering daemons, daemon pid
U="$MOCK_DIR/ubus"

own_ssid() { sed -n 's/.*"value": \["[^"]*", "\([^"]*\)".*/\1/p' "$1"; }
own_entry() { sed -n 's/.*"value": \(\[.*\]\).*/\1/p' "$1"; }

# Like usteer: every node with usteer running learns the BSSes of all other
# usteer nodes (local and remote, same SSID) and installs them with
# rrm_nr_set. Fixtures: $MOCK_HOSTS/../main and $MOCK_HOSTS/<host>.
usteer_refresh_all() {
	mocks="$MOCK_DIR"
	if [ -n "${MOCK_HOSTS:-}" ]; then
		mocks="$(dirname "$MOCK_HOSTS")/main/mock"
		for h in "$MOCK_HOSTS"/*/mock; do [ -d "$h" ] && mocks="$mocks $h"; done
	fi
	active=''
	for m in $mocks; do [ -f "$m/svc/usteer.running" ] && active="$active $m"; done
	for m in $active; do
		for o in "$m"/ubus/hostapd.*; do
			[ -f "$o/rrm_nr_get_own.json" ] || continue
			ssid=$(own_ssid "$o/rrm_nr_get_own.json")
			list=''
			for m2 in $active; do
				for p in "$m2"/ubus/hostapd.*; do
					[ "$p" = "$o" ] && continue
					[ -f "$p/rrm_nr_get_own.json" ] || continue
					[ "$(own_ssid "$p/rrm_nr_get_own.json")" = "$ssid" ] || continue
					list="$list${list:+,}$(own_entry "$p/rrm_nr_get_own.json")"
				done
			done
			echo "{\"list\": [$list]}" >"$o/nr_list.state"
		done
	done
}
case "$1:$2" in
usteer:start)
	mkdir -p "$U/usteer"
	cp "${MOCK_USTEER_CONFIG:-$MOCK_LIB/usteer_get_config.json}" "$U/usteer/get_config.json"
	nodes='{'
	first=1
	for o in "$U"/hostapd.*; do
		[ -d "$o" ] || continue
		n=$(basename "$o"); n=${n#hostapd.}
		[ "$first" = 1 ] || nodes="$nodes,"
		first=0
		nodes="$nodes\"$n\":{\"freq\":5180,\"n_assoc\":0,\"noise\":-92,\"load\":0}"
	done
	echo "$nodes}" >"$U/usteer/local_info.json"
	cp "$MOCK_DIR/usteer_remote_info.json" "$U/usteer/remote_info.json" 2>/dev/null || echo '{}' >"$U/usteer/remote_info.json"
	echo '{}' >"$U/usteer/get_clients.json"
	usteer_refresh_all
	;;
usteer:stop) rm -rf "$U/usteer" ;;
dawn:start)
	mkdir -p "$U/dawn"
	echo '{}' >"$U/dawn/get_hearing_map.json"
	cp "$MOCK_DIR/dawn_network.json" "$U/dawn/get_network.json" 2>/dev/null || echo '{"lan":{}}' >"$U/dawn/get_network.json"
	;;
dawn:stop) rm -rf "$U/dawn" ;;
roamctl:start)
	d="$ORM_SYSROOT/var/run/roamctl"
	mkdir -p "$d"
	if [ "$(uci -c "$ORM_SYSROOT/etc/config" -q get roamctl.global.daemon)" = 1 ]; then
		echo "${MOCK_ALIVE_PID:-$$}" >"$d/daemon.pid"
	fi
	;;
roamctl:stop) rm -f "$ORM_SYSROOT/var/run/roamctl/daemon.pid" ;;
esac
exit 0
