# shellcheck shell=sh
# OpenWrt Roaming Manager - usteer backend
#
# usteer (package "usteer", OpenWrt core feed) is a distributed client
# steering daemon. Instances on all APs exchange node/client information
# over UDP (port 16720) on the configured network, distribute 802.11k
# neighbor reports to hostapd and use hostapd's ubus API for BSS
# transition requests.
#
# Thresholds: usteer *_snr options accept either an SNR (positive, dB) or
# a signal level (negative, dBm). An SNR value is converted with a per
# band noise floor inside usteer (-98 dBm at 2.4 GHz, -95 dBm at 5 GHz),
# which yields band specific signal thresholds from one setting.
#
# Only options reported by the running usteer ("ubus call usteer
# get_config") are written, so unknown/renamed options of other usteer
# versions are never set.

usteer_be_package() { printf usteer; }

usteer_be_installed() {
	[ -x "$(orm_path /etc/init.d/usteer)" ] || pkg_is_installed usteer
}

usteer_be_running() {
	have_cmd ubus && ubus list usteer >/dev/null 2>&1
}

usteer_be_handles_nr() { return 0; }

usteer_be_features() {
	printf 'rssi-steering ap-steering band-steering load-balancing min-rssi hysteresis neighbor-reports multi-ap'
	usteer_has_key aggressiveness && printf ' btm-only-mode'
	usteer_has_key aggressiveness_mac_list && printf ' client-exclusion'
	return 0
}

# Keys supported by the installed usteer (cached per run)
usteer_config_keys() {
	local _j
	if [ -z "${USTEER_KEYS:-}" ]; then
		_j=$(ubus call usteer get_config 2>/dev/null) || return 1
		USTEER_KEYS=$(json_keys "$_j" "" | tr '\n' ' ')
	fi
	# shellcheck disable=SC2086
	printf '%s\n' $USTEER_KEYS
}

usteer_has_key() {
	usteer_config_keys | grep -qx "$1"
}

usteer_section() {
	local _sec
	_sec=$(orm_uci -X show usteer 2>/dev/null | sed -n 's/^usteer\.\([^.=]*\)=usteer$/\1/p' | head -n1)
	printf '%s' "${_sec:-@usteer[0]}"
}

# rssi (dBm) -> SNR relative to usteer's 5 GHz noise assumption
usteer_snr() {
	echo $(($1 - $(opt_default noise_ref_5g -95)))
}

usteer_be_configure() {
	local _t _sec _p _net _ssids _g _s _aps _old_ifs _min5 _hy _ag _excl _m
	# usteer must be running once to report its supported configuration
	if ! usteer_be_running; then
		[ "$ORM_DRYRUN" = 1 ] || "$(orm_path /etc/init.d/usteer)" start >/dev/null 2>&1
		_t=0
		while ! usteer_be_running && [ "$_t" -lt 10 ]; do
			sleep 1
			_t=$((_t + 1))
		done
	fi
	if ! usteer_config_keys >/dev/null 2>&1; then
		log_warn "usteer does not report its configuration; writing only basic options"
		USTEER_KEYS="network ssid_list local_mode"
	fi
	_sec=$(usteer_section)
	if ! orm_uci -q get "usteer.$_sec" >/dev/null 2>&1; then
		# config file without a section (fresh package) - create it
		[ "$ORM_DRYRUN" = 1 ] || {
			[ -f "$ORM_UCI_CONFDIR/usteer" ] || : >"$ORM_UCI_CONFDIR/usteer"
			orm_uci add usteer usteer >/dev/null
			orm_uci commit usteer
		}
		_sec=$(usteer_section)
	fi
	_p="usteer.$_sec"
	_set() {
		usteer_has_key "$1" && plan_set "$_p.$1" "$2"
	}

	# Network used for inter-AP communication: the network of the first
	# managed interface (usually "lan").
	_net=''
	_ssids=''
	for _g in $(roam_groups); do
		_ssids="$_ssids$(roam_get "$_g.ssid")$ORM_FS"
		for _s in $(roam_get "$_g.iface"); do
			[ -n "$_net" ] || _net=$(caps_get "iface.$_s.network" | cut -d' ' -f1)
		done
	done
	_set network "${_net:-lan}"
	_aps=$(caps_get opt.aps 1)
	if [ "$_aps" -le 1 ]; then _set local_mode 1; else _set local_mode 0; fi
	if usteer_has_key ssid_list && [ -n "$_ssids" ]; then
		_old_ifs=$IFS
		IFS=$ORM_FS
		# shellcheck disable=SC2086
		set -- ${_ssids%"$ORM_FS"}
		IFS=$_old_ifs
		plan_list "$_p.ssid_list" "$@"
	fi

	# Thresholds derived from the optimizer (5 GHz basis -> usteer SNR)
	_min5=$(caps_get opt.rssi_min_5g -75)
	_hy=$(caps_get opt.hyst_5g 6)
	_ag=$(caps_get opt.usteer_aggressiveness 1)
	_set signal_diff_threshold "$_hy"
	_set roam_scan_snr "$(usteer_snr $((_min5 + 3)))"
	if usteer_has_key aggressiveness; then
		_set aggressiveness "$_ag"
		if [ "$_ag" -ge 1 ] && [ "$_aps" -ge 2 ]; then
			_set roam_trigger_snr "$(usteer_snr "$_min5")"
		else
			_set roam_trigger_snr 0
		fi
		# clients excluded from steering
		if usteer_has_key aggressiveness_mac_list; then
			_excl=$(orm_uci -q get roamctl.steering.exclude_client)
			if [ -n "$_excl" ]; then
				# shellcheck disable=SC2046
				plan_list "$_p.aggressiveness_mac_list" $(for _m in $_excl; do printf '%s,0 ' "$_m"; done)
			fi
		fi
	else
		# Without aggressiveness control usteer's roam trigger may kick
		# clients that ignore BTM - keep it disabled in safe profiles.
		if [ "$(caps_get opt.kick_mode none)" = none ]; then
			_set roam_trigger_snr 0
			caps_set steer.usteer.note "usteer without 'aggressiveness': active roam trigger disabled to avoid forced disconnects"
		else
			_set roam_trigger_snr "$(usteer_snr "$_min5")"
		fi
	fi
	# never deny associations / kick on low signal in safe profiles
	_set min_connect_snr 0
	_set min_snr 0
	_set load_kick_enabled 0
	_set probe_steering 0
	_set assoc_steering 0
	if [ "$(caps_get opt.band_steering 1)" = 1 ]; then
		_set band_steering_threshold 5
		_set band_steering_min_snr "$(usteer_snr "$(caps_get opt.band_target_min_5g -70)")"
	else
		_set band_steering_threshold 0
	fi
	_set load_balancing_threshold "$(caps_get opt.load_diff 5)"
	_set max_neighbor_reports 8
	return 0
}

usteer_be_post_apply() {
	[ "$ORM_DRYRUN" = 1 ] && return 0
	svc_set_enabled usteer 1
}

usteer_be_enable() { svc_set_enabled usteer 1; }
usteer_be_disable() { svc_set_enabled usteer 0; }

usteer_be_test() {
	local _li _nodes _ri _rn _aps _cl _nc
	if ! usteer_be_installed; then
		report_add steering usteer FAIL "usteer is selected but not installed"
		return 1
	fi
	if ! usteer_be_running; then
		report_add steering usteer FAIL "usteer daemon is not running (ubus object 'usteer' missing)"
		return 1
	fi
	report_add steering usteer PASS "usteer daemon running"
	_li=$(ubus call usteer local_info 2>/dev/null)
	_nodes=$(json_keys "$_li" "" | grep -c .)
	if [ "$_nodes" -gt 0 ]; then
		report_add steering "usteer local nodes" PASS "$_nodes local BSS registered with usteer"
	else
		report_add steering "usteer local nodes" FAIL "usteer sees no local hostapd BSS"
	fi
	_ri=$(ubus call usteer remote_info 2>/dev/null)
	_rn=$(json_keys "$_ri" "" | grep -c .)
	_aps=$(roam_ap_count)
	if [ "$_aps" -gt 1 ]; then
		if [ "$_rn" -gt 0 ]; then
			report_add steering "usteer remote nodes" PASS "$_rn remote BSS discovered"
		else
			report_add steering "usteer remote nodes" WARN "no remote usteer nodes seen (check network '$(orm_uci -q get "usteer.$(usteer_section).network")' and UDP 16720)"
		fi
	else
		report_add steering "usteer remote nodes" "NOT TESTED" "standalone AP"
	fi
	_cl=$(ubus call usteer get_clients 2>/dev/null)
	if [ -n "$_cl" ]; then
		_nc=$(json_keys "$_cl" "" | grep -c :)
		report_add steering "usteer client data" PASS "$_nc client(s) tracked"
	else
		report_add steering "usteer client data" WARN "usteer get_clients returned nothing"
	fi
	return 0
}
