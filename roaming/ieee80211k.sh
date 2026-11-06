# shellcheck shell=sh
# OpenWrt Roaming Manager - IEEE 802.11k Radio Resource Management
#
# UCI "ieee80211k=1" makes the netifd handler emit
#   rrm_neighbor_report=1  - answer Neighbor Report Requests from clients
#   rrm_beacon_report=1    - request Beacon Reports (client side RSSI of
#                            neighbouring BSSes)
# and sets the RRM Enabled Capabilities element in beacons. If only the
# fine grained options are known by the handler, those are used instead.
#
# Neighbor report *content* is handled by neighbor_report.sh.

k_plan_iface() {
	local _s _p
	_s=$1
	_p="wireless.$_s"
	if [ "$(caps_get "iface.$_s.can_11k")" != 1 ]; then
		log_debug "802.11k skipped on $_s: $(caps_get "iface.$_s.why_11k")"
		return 1
	fi
	if [ "$(caps_get uciopt.ieee80211k)" != 0 ]; then
		plan_set "$_p.ieee80211k" 1
	fi
	[ "$(caps_get uciopt.rrm_neighbor_report)" = 1 ] && plan_set "$_p.rrm_neighbor_report" 1
	[ "$(caps_get uciopt.rrm_beacon_report)" = 1 ] && plan_set "$_p.rrm_beacon_report" 1
	return 0
}

k_plan_disable() {
	plan_set "wireless.$1.ieee80211k" 0
	plan_del "wireless.$1.rrm_neighbor_report"
	plan_del "wireless.$1.rrm_beacon_report"
}

# Decode RRM Enabled Capabilities (5 octets, as reported by hostapd
# get_clients "rrm": [b0,b1,b2,b3,b4]) -> words
k_client_rrm_caps() {
	local _b0 _o
	# k_client_rrm_caps B0 [B1..]
	_b0=${1:-0}
	is_uint "$_b0" || return 0
	_o=''
	[ $((_b0 & 2)) -ne 0 ] && _o="$_o neighbor-report"
	[ $((_b0 & 16)) -ne 0 ] && _o="$_o beacon-passive"
	[ $((_b0 & 32)) -ne 0 ] && _o="$_o beacon-active"
	[ $((_b0 & 64)) -ne 0 ] && _o="$_o beacon-table"
	printf '%s' "${_o# }"
}

# Request a Beacon Report from a client (802.11k measurement). Results
# are delivered by hostapd as ubus "beacon-report" notifications.
k_beacon_request() {
	# k_beacon_request IFNAME MAC [OPCLASS] [CHANNEL]
	ubus call "hostapd.$1" rrm_beacon_req \
		"{\"addr\":\"$2\",\"op_class\":${3:-0},\"channel\":${4:-255},\"duration\":100,\"mode\":1,\"bssid\":\"ff:ff:ff:ff:ff:ff\"}" >/dev/null 2>&1
}
