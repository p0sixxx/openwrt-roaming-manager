#!/bin/sh
# Service side effects: ubus objects of steering daemons, daemon pid
U="$MOCK_DIR/ubus"
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
	# like usteer: install the other local BSSes of the same SSID as neighbors
	for o in "$U"/hostapd.*; do
		[ -f "$o/rrm_nr_get_own.json" ] || continue
		ssid=$(sed -n 's/.*"value": \["[^"]*", "\([^"]*\)".*/\1/p' "$o/rrm_nr_get_own.json")
		list=''
		for p in "$U"/hostapd.*; do
			[ "$p" = "$o" ] && continue
			[ -f "$p/rrm_nr_get_own.json" ] || continue
			pssid=$(sed -n 's/.*"value": \["[^"]*", "\([^"]*\)".*/\1/p' "$p/rrm_nr_get_own.json")
			[ "$pssid" = "$ssid" ] || continue
			e=$(sed -n 's/.*"value": \(\[.*\]\).*/\1/p' "$p/rrm_nr_get_own.json")
			list="$list${list:+,}$e"
		done
		echo "{\"list\": [$list]}" >"$o/nr_list.state"
	done
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
