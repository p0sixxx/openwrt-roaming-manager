# shellcheck shell=sh
# OpenWrt Roaming Manager - AP discovery
#
# Finds other access points of the network:
#  * over the air: BSSIDs broadcasting a roaming group SSID (iwinfo scan)
#    -> BSSID, channel, signal (topology/RSSI information)
#  * on the LAN: usteer remote nodes, DHCP leases and the neighbour table,
#    filtered to hosts answering on the SSH port
# Discovered hosts are only *suggested*; adding an AP to a group is an
# explicit "roamctl multiap add" with SSH key verification.

# Over-the-air scan: "bssid channel signal ssid" for an interface
disc_scan_iface() {
	have_cmd iwinfo || return 1
	iwinfo "$1" scan 2>/dev/null | awk '
		/Cell [0-9]+ - Address:/ { if (b != "") print b, ch, sig, ssid; b = tolower($NF); ch = ""; sig = ""; ssid = "" }
		/ESSID:/ { s = $0; sub(/.*ESSID: "?/, "", s); sub(/"$/, "", s); ssid = s }
		/Channel:/ { for (i = 1; i <= NF; i++) if ($i == "Channel:") ch = $(i + 1) }
		/Signal:/ { for (i = 1; i <= NF; i++) if ($i == "Signal:") sig = $(i + 1) }
		END { if (b != "") print b, ch, sig, ssid }'
}

# Foreign BSSIDs with a roaming group SSID -> $ORM_STATE/scan_bss
disc_scan() {
	local _out _own _s _scanned _if _res _b _ch _sig _ssid _g
	_out="$ORM_STATE/scan_bss"
	: >"$_out"
	_own=''
	for _s in $(caps_get iface.list); do
		_own="$_own $(caps_get "iface.$_s.bssid")"
	done
	_scanned=0
	for _s in $(caps_get iface.list); do
		[ "$(caps_get "iface.$_s.hostapd")" = 1 ] || continue
		_if=$(caps_get "iface.$_s.ifname")
		_res=$(disc_scan_iface "$_if") || continue
		_scanned=1
		printf '%s\n' "$_res" | while read -r _b _ch _sig _ssid; do
			[ -n "$_b" ] || continue
			list_contains "$_own" "$_b" && continue
			for _g in $(roam_groups); do
				[ "$(roam_get "$_g.ssid")" = "$_ssid" ] && printf '%s %s %s %s\n' "$_g" "$_b" "$_ch" "$_sig" >>"$_out"
			done
		done
	done
	sort -u "$_out" -o "$_out" 2>/dev/null
	[ "$_scanned" = 1 ]
}

# Hosts on the LAN that might be OpenWrt APs
disc_lan_candidates() {
	local _ip _ap
	{
		# usteer remote node addresses (most reliable: they run usteer)
		if have_cmd ubus && ubus list usteer >/dev/null 2>&1; then
			ubus call usteer remote_info 2>/dev/null | grep -Eo '[0-9]{1,3}(\.[0-9]{1,3}){3}'
		fi
		awk '{print $3}' "$(orm_path /tmp/dhcp.leases)" 2>/dev/null
		ip -4 neigh show 2>/dev/null | awk '$0 ~ /lladdr/ && $0 !~ /FAILED/ {print $1}'
	} | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u | while read -r _ip; do
		# skip ourselves and already managed APs
		ip -4 addr show 2>/dev/null | grep -q "inet $_ip/" && continue
		for _ap in $(roam_aps); do
			[ "$(orm_uci -q get "roamctl.$_ap.host")" = "$_ip" ] && continue 2
		done
		if have_cmd nc; then
			nc -z -w 2 "$_ip" 22 >/dev/null 2>&1 || continue
		fi
		printf '%s\n' "$_ip"
	done
}
