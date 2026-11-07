# shellcheck shell=sh
# OpenWrt Roaming Manager - Compatibility Engine
#
# Decides which roaming features can be enabled, per BSS, by checking
# six independent layers. A feature is only reported as supported if
# every layer agrees - an UCI option existing is never enough:
#
#   1. hardware   - the wiphy supports AP mode
#   2. driver     - softmac (mac80211) vs fullmac drivers
#   3. kernel     - mac80211/cfg80211 present
#   4. backend    - installed wpad/hostapd package and the netifd handler
#                   that translates UCI to hostapd.conf knows the option
#   5. hostapd    - compiled features (hostapd -v<feature>) and the ubus
#                   methods exported by the running daemon
#   6. BSS        - security mode of the concrete interface
#
# Every negative decision stores a human readable reason.

# Directories containing the netifd wireless handler (shell in <=23.05,
# ucode in 24.10+) and the UCI schema (24.10+).
compat_handler_paths() {
	local _p _full
	for _p in /lib/netifd/hostapd.sh /lib/netifd/wireless /usr/share/hostap \
		/usr/share/ucode/wifi /usr/share/schema /lib/wifi /usr/share/wifi-scripts; do
		_full=$(orm_path "$_p")
		[ -e "$_full" ] && printf '%s\n' "$_full"
	done
}

# compat_uci_opt OPTION -> 1 (handler knows it), 0 (handler present but
# option unknown) or "unknown" (no handler found to inspect).
compat_uci_opt() {
	local _paths
	_paths=$(compat_handler_paths)
	if [ -z "$_paths" ]; then
		printf unknown
		return 0
	fi
	# shellcheck disable=SC2086
	if grep -rqsw -- "$1" $_paths 2>/dev/null; then
		printf 1
	else
		printf 0
	fi
}

compat_detect_uci_opts() {
	local _o
	for _o in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local \
		reassociation_deadline r0_key_lifetime r1_key_holder pmk_r1_push r0kh r1kh nasid \
		ieee80211k rrm_neighbor_report rrm_beacon_report ieee80211v bss_transition \
		wnm_sleep_mode wnm_sleep_mode_no_keys time_advertisement; do
		caps_set "uciopt.$_o" "$(compat_uci_opt "$_o")"
	done
}

compat_hostapd_binary() {
	local _b
	for _b in hostapd wpad; do
		if have_cmd "$_b"; then
			command -v "$_b"
			return 0
		fi
	done
	return 1
}

# Probe compiled hostapd features. OpenWrt patches hostapd so that
# "hostapd -v<feature>" exits 0 if the feature is built in (this is what
# LuCI uses). Upstream hostapd exits 1, so the probe is conservative.
compat_detect_hostapd() {
	local _bin _f _ver
	_bin=$(compat_hostapd_binary) || _bin=''
	caps_set hostapd.binary "${_bin:-none}"
	if [ -z "$_bin" ]; then
		caps_set hostapd.version none
		for _f in 11r sae eap owe 11ax 11ac acs wep suiteb192; do
			caps_set "hostapd.feat.$_f" 0
		done
		return 1
	fi
	_ver=$("$_bin" -v 2>&1 | sed -En 's/.*(hostapd|wpad) v?([0-9][0-9.]*[^ ]*).*/\2/p' | head -n1)
	caps_set hostapd.version "${_ver:-unknown}"
	for _f in 11r sae eap owe 11ax 11ac acs wep suiteb192; do
		if "$_bin" "-v$_f" >/dev/null 2>&1; then
			caps_set "hostapd.feat.$_f" 1
		else
			caps_set "hostapd.feat.$_f" 0
		fi
	done
	return 0
}

# Installed hostapd/wpad package -> variant (mini/basic/full) and TLS lib
compat_detect_wpad_pkg() {
	local _pkg _variant _ssl
	_pkg=$(pkg_installed_list 2>/dev/null | grep -E '^(wpad|hostapd)(-[a-z0-9]+)*$' |
		grep -Ev '^(hostapd-utils|hostapd-common)$' | head -n1)
	caps_set hostapd.package "${_pkg:-none}"
	_variant=unknown _ssl=unknown
	case "$_pkg" in
	*-mini*) _variant=mini ;;
	*-basic*) _variant=basic ;;
	wpad-mesh-*) _variant=mesh ;;
	wpad | wpad-* | hostapd | hostapd-*) _variant=full ;;
	none | '') _variant=none ;;
	esac
	case "$_pkg" in
	*mbedtls*) _ssl=mbedtls ;;
	*openssl*) _ssl=openssl ;;
	*wolfssl*) _ssl=wolfssl ;;
	wpad | hostapd | wpad-mini | wpad-basic) _ssl=internal ;;
	esac
	caps_set hostapd.variant "$_variant"
	caps_set hostapd.ssl "$_ssl"
}

# ubus methods of a running BSS -> runtime 802.11k/v capability
compat_bss_methods() {
	# compat_bss_methods IFNAME
	have_cmd ubus || return 1
	ubus -v list "hostapd.$1" 2>/dev/null | sed -n 's/^[[:blank:]]*"\([a-z_]*\)":.*/\1/p'
}

# Per-BSS decision. Sets iface.<sec>.can_11k|can_11v|can_11r (1/0/unknown),
# iface.<sec>.ft_modes, iface.<sec>.why_* and iface.<sec>.eligible.
compat_eval_iface() {
	local _s _dev _phy _mode _sec _if _dclass _k _v _r _wk _wv _wr _elig _we _methods _ft
	_s=$1
	_dev=$(caps_get "iface.$_s.device")
	_phy=$(caps_get "radio.$_dev.phy")
	_mode=$(caps_get "iface.$_s.mode")
	_sec=$(caps_get "iface.$_s.security")
	_if=$(caps_get "iface.$_s.ifname")
	_dclass=$(caps_get "phy.$_phy.driver_class" unknown)
	_k=1 _v=1 _r=1
	_wk='' _wv='' _wr=''

	# Eligibility for roaming management at all
	_elig=1 _we=''
	if [ "$_mode" != ap ]; then
		_elig=0 _we="mode '$_mode' is not an access point"
	elif [ "$(caps_get "iface.$_s.disabled")" = 1 ] || [ "$(caps_get "iface.$_s.radio_disabled")" = 1 ]; then
		_elig=0 _we="interface or radio disabled"
	fi

	# Layer 1: hardware
	if [ "$(caps_get "phy.$_phy.ap" 1)" = 0 ]; then
		_k=0 _v=0 _r=0
		_wk="phy $_phy has no AP mode" _wv=$_wk _wr=$_wk
	fi
	# Layer 2/3: driver / kernel
	if [ "$_dclass" = fullmac ]; then
		_r=0 _wr="fullmac driver $(caps_get "phy.$_phy.driver") handles authentication in firmware; FT in AP mode is not available"
		_k=0 _wk="fullmac driver does not pass action frames for neighbor reports to hostapd"
		_v=0 _wv="fullmac driver does not support BSS Transition Management in AP mode"
	elif [ "$_dclass" = unknown ]; then
		_wk="driver unknown, verified at runtime" _wv=$_wk _wr=$_wk
	fi
	if [ "$_dclass" = softmac ] && [ "$(caps_get kernel.mac80211)" = 0 ] && [ -z "$ORM_SYSROOT" ]; then
		_wr="mac80211 kernel module not loaded"
	fi

	# Layer 4/5: backend & hostapd
	if [ "$(caps_get hostapd.binary)" = none ]; then
		_k=0 _v=0 _r=0
		_wk="no hostapd/wpad installed" _wv=$_wk _wr=$_wk
	else
		if [ "$_r" = 1 ] && [ "$(caps_get hostapd.feat.11r)" != 1 ]; then
			_r=0 _wr="installed $(caps_get hostapd.package) is built without IEEE 802.11r (hostapd -v11r failed)"
		fi
		if [ "$_r" = 1 ] && [ "$(caps_get uciopt.ieee80211r)" = 0 ]; then
			_r=0 _wr="netifd wireless handler does not support the 'ieee80211r' option"
		fi
		if [ "$_k" = 1 ] && [ "$(caps_get uciopt.ieee80211k)" = 0 ] && [ "$(caps_get uciopt.rrm_neighbor_report)" = 0 ]; then
			_k=0 _wk="netifd wireless handler does not support 802.11k options"
		fi
		if [ "$_v" = 1 ] && [ "$(caps_get uciopt.bss_transition)" = 0 ]; then
			_v=0 _wv="netifd wireless handler does not support the 'bss_transition' option"
		fi
		if [ "$(caps_get hostapd.variant)" = mini ]; then
			[ "$_k" = 1 ] && _k=0 _wk="wpad-mini lacks 802.11k support"
			[ "$_v" = 1 ] && _v=0 _wv="wpad-mini lacks 802.11v (WNM) support"
		fi
		# Runtime: methods exported by the running hostapd
		if [ -n "$_if" ] && [ "$(caps_get "iface.$_s.hostapd")" = 1 ]; then
			_methods=$(compat_bss_methods "$_if" | tr '\n' ' ')
			caps_set "iface.$_s.ubus_methods" "$_methods"
			if [ "$_k" = 1 ] && ! list_contains "$_methods" rrm_nr_get_own; then
				_k=0 _wk="hostapd on $_if exports no neighbor report (rrm_nr_*) methods"
			fi
			if [ "$_v" = 1 ] && ! list_contains "$_methods" bss_transition_request && ! list_contains "$_methods" wnm_disassoc_imminent; then
				_v=0 _wv="hostapd on $_if is built without WNM/BSS transition support"
			fi
		elif [ "$_elig" = 1 ]; then
			[ "$_k" = 1 ] && _wk="${_wk:-BSS not running; runtime support verified after apply}"
			[ "$_v" = 1 ] && _wv="${_wv:-BSS not running; runtime support verified after apply}"
		fi
	fi

	# Layer 6: security mode of the BSS
	_ft=''
	case "$_sec" in
	psk) _ft=ft-psk ;;
	sae)
		if [ "$(caps_get hostapd.feat.sae)" = 1 ]; then _ft=ft-sae; else
			[ "$_r" = 1 ] && _r=0 _wr="hostapd built without SAE"
		fi
		;;
	sae-mixed)
		_ft=ft-psk
		[ "$(caps_get hostapd.feat.sae)" = 1 ] && _ft="ft-psk ft-sae"
		;;
	eap)
		if [ "$(caps_get hostapd.feat.eap)" = 1 ]; then _ft=ft-eap; else
			[ "$_r" = 1 ] && _r=0 _wr="hostapd built without EAP"
		fi
		;;
	open | owe)
		[ "$_r" = 1 ] && _r=0 _wr="Fast Transition requires WPA2/WPA3 security (interface uses '$_sec')"
		;;
	wep | unknown)
		_r=0 _k=0 _v=0
		_wr="unsupported security mode '$(caps_get "iface.$_s.encryption")'" _wk=$_wr _wv=$_wr
		;;
	esac
	[ "$_r" = 1 ] || _ft=''

	caps_set "iface.$_s.eligible" "$_elig"
	caps_set "iface.$_s.why_eligible" "$_we"
	caps_set "iface.$_s.can_11k" "$_k"
	caps_set "iface.$_s.can_11v" "$_v"
	caps_set "iface.$_s.can_11r" "$_r"
	caps_set "iface.$_s.why_11k" "$_wk"
	caps_set "iface.$_s.why_11v" "$_wv"
	caps_set "iface.$_s.why_11r" "$_wr"
	caps_set "iface.$_s.ft_modes" "$_ft"
}

# Aggregate per-feature status over eligible interfaces: all/some/none
compat_aggregate() {
	local _feat _yes _tot _s _modes _m
	for _feat in 11k 11v 11r; do
		_yes=0 _tot=0
		for _s in $(caps_get iface.list); do
			[ "$(caps_get "iface.$_s.eligible")" = 1 ] || continue
			_tot=$((_tot + 1))
			[ "$(caps_get "iface.$_s.can_$_feat")" = 1 ] && _yes=$((_yes + 1))
		done
		if [ "$_tot" = 0 ] || [ "$_yes" = 0 ]; then
			caps_set "compat.$_feat" none
		elif [ "$_yes" = "$_tot" ]; then
			caps_set "compat.$_feat" all
		else
			caps_set "compat.$_feat" some
		fi
	done
	_modes=''
	for _s in $(caps_get iface.list); do
		for _m in $(caps_get "iface.$_s.ft_modes"); do
			list_contains "$_modes" "$_m" || _modes="$_modes $_m"
		done
	done
	caps_set compat.ft_modes "${_modes# }"
}

compat_detect_all() {
	local _s
	compat_detect_wpad_pkg
	compat_detect_hostapd
	compat_detect_uci_opts
	for _s in $(caps_get iface.list); do
		compat_eval_iface "$_s"
	done
	compat_aggregate
}

# Full detection pipeline used by every command.
detect_everything() {
	uci_cache_drop
	caps_reset
	sysdet_all
	pkg_detect_installed
	hw_detect_all
	wl_detect_all
	compat_detect_all
	steer_detect_backends
	caps_set detect.time "$(now)"
	uci_cache_warm
}
