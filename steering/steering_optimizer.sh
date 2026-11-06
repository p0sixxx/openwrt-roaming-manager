# shellcheck shell=sh
# OpenWrt Roaming Manager - steering optimizer
#
# Computes the effective steering parameters from:
#   defaults.conf + profile + topology (AP count, bands) + measured noise
#   floor per radio + current client load.
# Channels, channel width, TX power, country and regulatory domain are
# never changed here (see "roamctl rf" for the advanced, confirmed mode).
#
# Results are stored as caps "opt.<key>" and persisted in the
# roamctl.steering UCI section so the native daemon can use them.

opt_conf_value() {
	# opt_conf_value FILE KEY
	sed -n "s/^$2=\([-0-9A-Za-z_.]*\).*/\1/p" "$1" 2>/dev/null | tail -n1
}

opt_default() {
	local _v
	_v=$(opt_conf_value "$ORM_ROOT/config/defaults.conf" "$1")
	printf '%s' "${_v:-$2}"
}

opt_profile_file() {
	local _pr _f
	_pr=${1:-balanced}
	case "$_pr" in
	*[!a-z0-9-]*) _pr=balanced ;;
	esac
	_f="$ORM_ROOT/config/profiles/$_pr.conf"
	[ -f "$_f" ] || _f="$ORM_ROOT/config/profiles/balanced.conf"
	printf '%s' "$_f"
}

opt_profile_value() {
	local _v
	_v=$(opt_conf_value "$(opt_profile_file "$1")" "$2")
	printf '%s' "${_v:-$3}"
}

# Measured noise floor of a radio (dBm) via iwinfo, empty if unknown
opt_radio_noise() {
	local _phy _s _if _n
	_phy=$(caps_get "radio.$1.phy")
	for _s in $(caps_get iface.list); do
		[ "$(caps_get "iface.$_s.device")" = "$1" ] || continue
		_if=$(caps_get "iface.$_s.ifname")
		[ -n "$_if" ] || continue
		_n=$(iwinfo "$_if" info 2>/dev/null | sed -n 's/.*Noise: \(-[0-9]*\) dBm.*/\1/p' | head -n1)
		if [ -n "$_n" ] && [ "$_n" -lt -40 ] && [ "$_n" -gt -120 ]; then
			printf '%s' "$_n"
			return 0
		fi
	done
	[ -n "$_phy" ] || return 1
	return 1
}

# Number of associated clients of a BSS
opt_bss_clients() {
	local _j
	_j=$(ubus call "hostapd.$1" get_clients 2>/dev/null) || {
		echo 0
		return
	}
	json_keys "$_j" clients | grep -c :
}

clamp() {
	# clamp VALUE MIN MAX
	if [ "$1" -lt "$2" ]; then echo "$2"; elif [ "$1" -gt "$3" ]; then echo "$3"; else echo "$1"; fi
}

# opt_compute PROFILE AP_COUNT
opt_compute() {
	local _prof _aps _roff _hoff _dens _nexp _bands _r _b _n _nadj _min _pref _hy _k _tot _nb _s _c _lt _avg
	_prof=${1:-balanced} _aps=${2:-1}
	is_uint "$_aps" || _aps=1
	_roff=$(opt_profile_value "$_prof" rssi_offset 0)
	_hoff=$(opt_profile_value "$_prof" hyst_offset 0)

	# Density: a single AP has no AP alternative, steer only when really bad.
	# Dense deployments (3+ APs) can roam earlier.
	if [ "$_aps" -le 1 ]; then _dens=-4
	elif [ "$_aps" -ge 3 ]; then _dens=2
	else _dens=0; fi

	_nexp=$(opt_default noise_expected -92)
	_bands=''
	for _r in $(caps_get radio.list); do
		[ "$(caps_get "radio.$_r.disabled")" = 1 ] && continue
		_b=$(caps_get "radio.$_r.band")
		case "$_b" in 2g | 5g | 6g) ;; *) continue ;; esac
		list_contains "$_bands" "$_b" || _bands="$_bands $_b"
		_n=$(opt_radio_noise "$_r") || _n=''
		if [ -n "$_n" ]; then
			caps_set "opt.noise_$_b" "$_n"
		fi
	done
	caps_set opt.bands "${_bands# }"

	for _b in 2g 5g 6g; do
		_n=$(caps_get "opt.noise_$_b")
		_nadj=0
		if [ -n "$_n" ] && [ "$_n" -gt "$_nexp" ]; then
			_nadj=$(clamp $((_n - _nexp)) 0 8)
		fi
		_min=$(($(opt_default "rssi_min_$_b" -75) + _roff + _dens + _nadj))
		_pref=$(($(opt_default "rssi_pref_$_b" -65) + _nadj))
		_min=$(clamp "$_min" -88 -60)
		# preferred must stay above min by at least the hysteresis
		_hy=$(clamp $(($(opt_default "hyst_$_b" 6) + _hoff)) 3 12)
		[ "$_pref" -lt $((_min + _hy)) ] && _pref=$((_min + _hy))
		caps_set "opt.rssi_min_$_b" "$_min"
		caps_set "opt.rssi_pref_$_b" "$_pref"
		caps_set "opt.hyst_$_b" "$_hy"
	done
	caps_set opt.band_steer_rssi_2g "$(($(opt_default band_steer_rssi_2g -60) - _roff))"
	caps_set opt.band_target_min_5g "$(opt_default band_target_min_5g -70)"
	caps_set opt.band_target_min_6g "$(opt_default band_target_min_6g -68)"

	for _k in cooldown retry_limit pingpong_max low_samples; do
		caps_set "opt.$_k" "$(opt_profile_value "$_prof" "$_k" "$(opt_default "$_k" 3)")"
	done
	caps_set opt.pingpong_window "$(opt_default pingpong_window 600)"
	caps_set opt.min_assoc_time "$(opt_default min_assoc_time 30)"
	caps_set opt.interval "$(opt_default interval 15)"
	caps_set opt.kick_mode "$(opt_profile_value "$_prof" kick_mode none)"
	caps_set opt.band_steering "$(opt_profile_value "$_prof" band_steering 1)"
	caps_set opt.usteer_aggressiveness "$(opt_profile_value "$_prof" usteer_aggressiveness 1)"

	# Load: threshold scales with the current average clients per BSS
	_tot=0 _nb=0
	for _s in $(caps_get iface.list); do
		[ "$(caps_get "iface.$_s.hostapd")" = 1 ] || continue
		_c=$(opt_bss_clients "$(caps_get "iface.$_s.ifname")")
		_tot=$((_tot + _c))
		_nb=$((_nb + 1))
	done
	_lt=$(opt_default load_threshold 20)
	if [ "$_nb" -gt 0 ]; then
		_avg=$((_tot / _nb))
		[ $((_avg * 3 / 2)) -gt "$_lt" ] && _lt=$((_avg * 3 / 2))
		caps_set opt.clients_total "$_tot"
	fi
	caps_set opt.load_threshold "$_lt"
	caps_set opt.load_diff "$(opt_default load_diff 5)"
	caps_set opt.profile "$_prof"
	caps_set opt.aps "$_aps"
}

# Persist computed values for the native daemon (roamctl.steering)
opt_plan_persist() {
	local _k
	orm_uci -q get roamctl.steering >/dev/null || {
		[ "$ORM_DRYRUN" = 1 ] || {
			orm_uci set roamctl.steering=steering
			orm_uci commit roamctl
		}
	}
	for _k in rssi_min_2g rssi_min_5g rssi_min_6g rssi_pref_2g rssi_pref_5g rssi_pref_6g \
		hyst_2g hyst_5g hyst_6g band_steer_rssi_2g band_target_min_5g band_target_min_6g \
		cooldown retry_limit pingpong_window pingpong_max min_assoc_time low_samples \
		interval kick_mode band_steering load_threshold load_diff; do
		plan_set "roamctl.steering.$_k" "$(caps_get "opt.$_k")"
	done
}

# Print effective parameters
opt_show() {
	local _k
	printf '%-22s %8s %8s %8s\n' parameter 2.4GHz 5GHz 6GHz
	for _k in rssi_min rssi_pref hyst; do
		printf '%-22s %8s %8s %8s\n' "$_k" "$(caps_get "opt.${_k}_2g")" "$(caps_get "opt.${_k}_5g")" "$(caps_get "opt.${_k}_6g")"
	done
	for _k in band_steer_rssi_2g band_target_min_5g cooldown retry_limit pingpong_window pingpong_max \
		min_assoc_time low_samples load_threshold kick_mode profile aps; do
		printf '%-22s %s\n' "$_k" "$(caps_get "opt.$_k")"
	done
}
