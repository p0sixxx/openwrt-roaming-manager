# shellcheck shell=sh
# OpenWrt Roaming Manager - IEEE 802.11v BSS Transition Management
#
# UCI "bss_transition=1" advertises BSS Transition support (Extended
# Capabilities bit 19) so hostapd answers BTM Queries and can send BTM
# Requests. Legacy shell handlers (<= 23.05) only honour it together with
# "ieee80211v=1", so both are written when the handler knows them.
# WNM-Sleep mode is not enabled by default (historic key reinstallation
# issues; only in advanced mode with wnm_sleep_mode_no_keys).

v_plan_iface() {
	local _s _p
	_s=$1
	_p="wireless.$_s"
	if [ "$(caps_get "iface.$_s.can_11v")" != 1 ]; then
		log_debug "802.11v skipped on $_s: $(caps_get "iface.$_s.why_11v")"
		return 1
	fi
	[ "$(caps_get uciopt.ieee80211v)" = 1 ] && plan_set "$_p.ieee80211v" 1
	plan_set "$_p.bss_transition" 1
	if [ "${ORM_WNM_SLEEP:-0}" = 1 ] && [ "$(caps_get uciopt.wnm_sleep_mode_no_keys)" = 1 ]; then
		plan_set "$_p.wnm_sleep_mode" 1
		plan_set "$_p.wnm_sleep_mode_no_keys" 1
	fi
	return 0
}

v_plan_disable() {
	plan_set "wireless.$1.bss_transition" 0
}

# Does a client support BTM? Extended Capabilities octet 2, bit 3 (bit 19)
# v_client_btm EXTCAP_BYTE2
v_client_btm() {
	is_uint "${1:-}" || return 1
	[ $(($1 & 8)) -ne 0 ]
}

# Send a BSS Transition Management Request.
# v_btm_request IFNAME MAC DISASSOC(0/1) VALIDITY NR_HEX...
# Uses "bss_transition_request" (hostapd 2.10+ ubus) and falls back to
# "wnm_disassoc_imminent" only when disassociation imminent is requested.
v_btm_request() {
	local _if _mac _dis _val _nl _n _d _methods
	_if=$1 _mac=$2 _dis=$3 _val=${4:-100}
	shift 4
	_nl=''
	for _n in "$@"; do
		_nl="${_nl}${_nl:+,}\"$_n\""
	done
	_d=false
	[ "$_dis" = 1 ] && _d=true
	_methods=$(compat_bss_methods "$_if" | tr '\n' ' ')
	if list_contains "$_methods" bss_transition_request; then
		ubus call "hostapd.$_if" bss_transition_request \
			"{\"addr\":\"$_mac\",\"disassociation_imminent\":$_d,\"disassociation_timer\":0,\"validity_period\":$_val,\"abridged\":true,\"neighbors\":[$_nl]}" >/dev/null 2>&1
		return $?
	fi
	if [ "$_dis" = 1 ] && list_contains "$_methods" wnm_disassoc_imminent; then
		ubus call "hostapd.$_if" wnm_disassoc_imminent \
			"{\"addr\":\"$_mac\",\"duration\":$_val,\"abridged\":true,\"neighbors\":[$_nl]}" >/dev/null 2>&1
		return $?
	fi
	return 2
}
