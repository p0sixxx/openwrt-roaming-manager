# shellcheck shell=sh
# OpenWrt Roaming Manager - wireless configuration and runtime detection
#
# Reads every wifi-iface section, the runtime state reported by netifd
# (ubus network.wireless status) and the BSSIDs of running interfaces.

wl_list_ifaces() {
	uci_cache_ensure wireless
	printf '%s' "$ORM_WL_SHOW" | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface$/\1/p'
}

wl_cache_load() {
	uci_cache_drop
	uci_cache_ensure wireless
}

wl_cache_reset() {
	uci_cache_drop
}

wl_get() {
	# wl_get SECTION OPTION [DEFAULT]
	uci_cached_get wireless "$1" "$2" "${3:-}"
	return 0
}

# Normalise the UCI "encryption" value to a security family:
#   psk  : WPA2-Personal (psk2, psk2+ccmp, psk, psk-mixed)
#   sae  : WPA3-Personal (sae)
#   sae-mixed : WPA2/WPA3 transition (sae-mixed, psk2+sae ...)
#   eap  : WPA2/WPA3-Enterprise
#   owe  : Enhanced Open
#   open : no encryption
#   wep  : legacy, unsupported
wl_security_family() {
	case "$1" in
	none | '') printf open ;;
	owe*) printf owe ;;
	sae-mixed* | psk2+sae* | psk3-mixed*) printf sae-mixed ;;
	sae* | psk3*) printf sae ;;
	psk* | wpa-psk*) printf psk ;;
	wpa* | eap*) printf eap ;;
	wep*) printf wep ;;
	*) printf unknown ;;
	esac
}

# Heuristic: is this interface a guest / IoT / isolated network that must
# not be touched without explicit permission?
wl_is_special_iface() {
	local _sp_net _sp_ssid _sp_iso
	# wl_is_special_iface SECTION
	_sp_net=$(lower "$(wl_get "$1" network)")
	_sp_ssid=$(lower "$(wl_get "$1" ssid)")
	_sp_iso=$(wl_get "$1" isolate 0)
	case "$_sp_net" in
	*guest* | *iot* | *gast* | *hotspot*) return 0 ;;
	esac
	case "$_sp_ssid" in
	*guest* | *iot* | *gast* | *-smart* | *hotspot*) return 0 ;;
	esac
	[ "$_sp_iso" = 1 ] && return 0
	return 1
}

wl_iface_runtime() {
	local _rt_sec _rt_if _rt_bssid _rt_up
	# wl_iface_runtime SECTION -> sets ifname / bssid caps
	_rt_sec=$1
	_rt_if=''
	if [ -n "${ORM_WSTATUS:-}" ]; then
		# ifname may precede "section" inside the object: collect all, decide at END
		_rt_if=$(printf '%s' "$ORM_WSTATUS" | json_flatten | awk -v s="$_rt_sec" '
			{ p = $0; sub(/=.*/, "", p); v = substr($0, length(p) + 2); val[p] = v }
			p ~ /\.interfaces\.[0-9]+\.section$/ && v == s { b = p; sub(/section$/, "ifname", b); hit = b }
			END { if (hit != "" && (hit in val)) print val[hit] }')
	fi
	[ -n "$_rt_if" ] || _rt_if=$(wl_get "$_rt_sec" ifname)
	caps_set "iface.$_rt_sec.ifname" "$_rt_if"
	_rt_bssid=''
	if [ -n "$_rt_if" ]; then
		_rt_bssid=$(cat "$(orm_path "/sys/class/net/$_rt_if/address")" 2>/dev/null)
		if [ -z "$_rt_bssid" ] && have_cmd iw; then
			_rt_bssid=$(iw dev "$_rt_if" info 2>/dev/null | sed -n 's/^[[:blank:]]*addr \([0-9a-fA-F:]*\).*/\1/p' | head -n1)
		fi
	fi
	caps_set "iface.$_rt_sec.bssid" "$(lower "$_rt_bssid")"
	_rt_up=0
	if [ -n "$_rt_if" ] && have_cmd ubus && ubus list "hostapd.$_rt_if" >/dev/null 2>&1; then
		_rt_up=1
	fi
	caps_set "iface.$_rt_sec.hostapd" "$_rt_up"
}

wl_detect_all() {
	local _ifaces _s _dev _enc _key _o
	wl_cache_load
	local _ifaces _s _dev _enc _key _o
	[ -n "${ORM_WSTATUS:-}" ] || {
		have_cmd ubus && ORM_WSTATUS=$(ubus call network.wireless status 2>/dev/null)
	}
	_ifaces=$(wl_list_ifaces | tr '\n' ' ' | sed 's/ $//')
	caps_set iface.list "$_ifaces"
	for _s in $_ifaces; do
		_dev=$(wl_get "$_s" device)
		_enc=$(wl_get "$_s" encryption none)
		_key=$(wl_get "$_s" key)
		[ -n "$_key" ] || _key=$(wl_get "$_s" sae_password)
		caps_set "iface.$_s.device" "$_dev"
		caps_set "iface.$_s.band" "$(caps_get "radio.$_dev.band")"
		caps_set "iface.$_s.mode" "$(wl_get "$_s" mode ap)"
		caps_set "iface.$_s.ssid" "$(wl_get "$_s" ssid)"
		caps_set "iface.$_s.network" "$(wl_get "$_s" network)"
		caps_set "iface.$_s.encryption" "$_enc"
		caps_set "iface.$_s.security" "$(wl_security_family "$_enc")"
		caps_set "iface.$_s.keyfp" "$([ -n "$_key" ] && secret_fingerprint "$_key")"
		caps_set "iface.$_s.disabled" "$(wl_get "$_s" disabled 0)"
		caps_set "iface.$_s.radio_disabled" "$(wl_get "$_dev" disabled 0)"
		if wl_is_special_iface "$_s"; then
			caps_set "iface.$_s.special" 1
		else
			caps_set "iface.$_s.special" 0
		fi
		# Existing roaming related settings
		for _o in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local \
			ieee80211k rrm_neighbor_report rrm_beacon_report ieee80211v bss_transition \
			wnm_sleep_mode nasid r1_key_holder; do
			caps_set "iface.$_s.uci_$_o" "$(wl_get "$_s" "$_o")"
		done
		wl_iface_runtime "$_s"
	done
}
