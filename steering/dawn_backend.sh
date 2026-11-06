# shellcheck shell=sh
# OpenWrt Roaming Manager - DAWN backend (alternative)
#
# DAWN (package "dawn", OpenWrt packages feed) is a decentralized
# steering controller using hostapd ubus. It scores APs per band
# ("802_11g" = 2.4 GHz, "802_11a" = 5 GHz metric sections) and can
# distribute neighbor reports (set_hostapd_nr).
#
# DAWN's configuration layout changed between releases, so roamctl never
# assumes section names: options are located by name in the installed
# /etc/config/dawn and only existing options are modified. Its inter-AP
# messages are encrypted with shared_key/iv when use_symm_enc=1; roamctl
# generates random values per roaming group and synchronises them.

dawn_be_package() { printf dawn; }

dawn_be_installed() {
	[ -x "$(orm_path /etc/init.d/dawn)" ] || pkg_is_installed dawn
}

dawn_be_running() {
	have_cmd ubus && ubus list dawn >/dev/null 2>&1
}

dawn_be_handles_nr() {
	local _p
	_p=$(dawn_find_opt set_hostapd_nr | head -n1)
	[ -n "$_p" ] && [ "$(orm_uci -q get "$_p")" != 0 ]
}

dawn_be_features() {
	printf 'rssi-steering ap-steering band-steering load-balancing min-rssi per-band-thresholds neighbor-reports multi-ap'
}

# Paths (config.section.option) of an option anywhere in /etc/config/dawn
dawn_find_opt() {
	orm_uci -X show dawn 2>/dev/null | sed -n "s/^\(dawn\.[^.=]*\.$1\)=.*/\1/p"
}

# Section (2.4 or 5 GHz metric) owning per-band options
dawn_band_section() {
	local _pat
	# dawn_band_section 2g|5g
	_pat=802_11a
	[ "$1" = 2g ] && _pat=802_11g
	orm_uci -X show dawn 2>/dev/null | sed -n "s/^dawn\.\([^.=]*${_pat}[^.=]*\)=.*/\1/p" | head -n1
}

dawn_secret_file() {
	printf '%s/dawn.secret' "$ORM_KEY_DIR"
}

dawn_secret_ensure() {
	local _k _iv
	[ -f "$(dawn_secret_file)" ] && return 0
	[ "$ORM_DRYRUN" = 1 ] && return 0
	_k=$(random_hex 16) || return 1
	_iv=$(random_hex 8) || return 1
	ensure_dir "$ORM_KEY_DIR" 0700
	printf 'shared_key=%s\niv=%s\n' "$_k" "$_iv" | atomic_write "$(dawn_secret_file)" 600
}

dawn_be_configure() {
	local _dp _b _sec _g1 _s1 _net _bc
	_setp() {
		# _setp OPTION VALUE -> every occurrence of OPTION
		for _dp in $(dawn_find_opt "$1"); do plan_set "$_dp" "$2"; done
	}
	if [ ! -f "$ORM_UCI_CONFDIR/dawn" ]; then
		log_warn "DAWN configuration file missing; DAWN defaults will be used"
		return 0
	fi
	# Kicking (forced disassociation) off unless the profile asks for it
	case "$(caps_get opt.kick_mode none)" in
	none) _setp kicking 0 ;;
	*) _setp kicking 1 ;;
	esac
	_setp use_station_count 1
	# Per band signal thresholds
	for _b in 2g 5g; do
		_sec=$(dawn_band_section "$_b")
		[ -n "$_sec" ] || continue
		orm_uci -q get "dawn.$_sec.low_rssi_val" >/dev/null && plan_set "dawn.$_sec.low_rssi_val" "$(caps_get "opt.rssi_min_$_b")"
		orm_uci -q get "dawn.$_sec.rssi_val" >/dev/null && plan_set "dawn.$_sec.rssi_val" "$(caps_get "opt.rssi_pref_$_b")"
	done
	# neighbor reports from DAWN's view of the network
	[ -n "$(dawn_find_opt set_hostapd_nr)" ] && _setp set_hostapd_nr 2
	# encrypted inter-AP communication with a group secret
	if [ -n "$(dawn_find_opt use_symm_enc)" ]; then
		dawn_secret_ensure
		_setp use_symm_enc 1
		if [ -f "$(dawn_secret_file)" ]; then
			_setp shared_key "$(kv_get "$(dawn_secret_file)" shared_key)"
			_setp iv "$(kv_get "$(dawn_secret_file)" iv)"
		fi
	fi
	# broadcast address of the LAN bridge
	_s1=$(orch_managed_ifaces | head -n1)
	_net=$(caps_get "iface.$_s1.network" lan)
	_bc=$(ip -4 addr show dev "br-${_net%% *}" 2>/dev/null | sed -n 's/.* brd \([0-9.]*\).*/\1/p' | head -n1)
	[ -n "$_bc" ] && [ -n "$(dawn_find_opt broadcast_ip)" ] && _setp broadcast_ip "$_bc"
	return 0
}

dawn_be_post_apply() {
	[ "$ORM_DRYRUN" = 1 ] && return 0
	svc_set_enabled dawn 1
}

dawn_be_enable() { svc_set_enabled dawn 1; }
dawn_be_disable() { svc_set_enabled dawn 0; }

dawn_be_test() {
	local _hm _nw _n
	if ! dawn_be_installed; then
		report_add steering dawn FAIL "DAWN is selected but not installed"
		return 1
	fi
	if ! dawn_be_running; then
		report_add steering dawn FAIL "DAWN daemon is not running (ubus object 'dawn' missing)"
		return 1
	fi
	report_add steering dawn PASS "DAWN daemon running"
	_hm=$(ubus call dawn get_hearing_map 2>/dev/null)
	if [ -n "$_hm" ]; then
		report_add steering "dawn hearing map" PASS "DAWN collects probe data"
	else
		report_add steering "dawn hearing map" WARN "DAWN hearing map empty"
	fi
	_nw=$(ubus call dawn get_network 2>/dev/null)
	_n=$(json_keys "$_nw" "" | grep -c .)
	if [ "$(roam_ap_count)" -gt 1 ]; then
		if [ "$_n" -gt 1 ]; then
			report_add steering "dawn network" PASS "$_n APs visible to DAWN"
		else
			report_add steering "dawn network" WARN "DAWN sees no other AP"
		fi
	else
		report_add steering "dawn network" "NOT TESTED" "standalone AP"
	fi
	return 0
}
