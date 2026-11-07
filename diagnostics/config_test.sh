# shellcheck shell=sh
# Diagnostics: configuration validation (UCI level)

diag_config() {
	local _groups _g _ssid _md _label _ifs _bad _sec _fp _s _isec _ifp _mc _l _kf _mode
	uci_cache_warm
	if orm_uci show wireless >/dev/null 2>&1; then
		report_add config "UCI wireless" PASS "/etc/config/wireless parses"
	else
		report_add config "UCI wireless" FAIL "/etc/config/wireless cannot be parsed by uci"
		return 1
	fi
	if [ -n "$(orm_uci changes wireless 2>/dev/null)" ]; then
		report_add config "UCI pending" WARN "uncommitted changes in wireless (uci changes wireless)"
	fi
	_groups=$(roam_groups)
	if [ -z "$_groups" ]; then
		report_add config "roaming groups" WARN "roaming is not configured yet (run 'roamctl setup')"
		return 1
	fi
	for _g in $_groups; do
		_ssid=$(roam_get "$_g.ssid")
		_md=$(roam_get "$_g.mdid")
		_label="'$_ssid'"
		_ifs=$(roam_get "$_g.iface")
		_bad=''
		if [ -z "$_ifs" ]; then
			report_add config "$_label" FAIL "group has no interfaces"
			continue
		fi
		_sec='' _fp=''
		for _s in $_ifs; do
			if ! orm_uci -q get "wireless.$_s" >/dev/null; then
				_bad="$_bad; interface $_s no longer exists"
				continue
			fi
			[ "$(wl_get "$_s" ssid)" = "$_ssid" ] || _bad="$_bad; $_s SSID changed to '$(wl_get "$_s" ssid)'"
			_isec=$(caps_get "iface.$_s.security")
			_ifp=$(caps_get "iface.$_s.keyfp")
			[ -z "$_sec" ] && _sec=$_isec _fp=$_ifp
			[ "$_isec" = "$_sec" ] || _bad="$_bad; $_s encryption differs"
			[ "$_ifp" = "$_fp" ] || _bad="$_bad; $_s passphrase differs"
			if [ "$(roam_get "$_g.ieee80211r")" = 1 ] && [ "$(caps_get "iface.$_s.can_11r")" = 1 ]; then
				[ "$(wl_get "$_s" ieee80211r)" = 1 ] || _bad="$_bad; $_s ieee80211r not set"
				[ "$(lower "$(wl_get "$_s" mobility_domain)")" = "$_md" ] || _bad="$_bad; $_s mobility_domain '$(wl_get "$_s" mobility_domain)' != $_md"
				case "$(roam_get "$_g.ft_key_mode")" in
				shared)
					[ "$(ft_iface_key_fingerprint "$_s")" = "$(ft_key_fingerprint "$_g")" ] ||
						_bad="$_bad; $_s R0KH/R1KH key differs from group key" ;;
				local)
					[ "$(caps_get uciopt.ft_psk_generate_local)" = 0 ] ||
						[ "$(wl_get "$_s" ft_psk_generate_local)" = 1 ] || _bad="$_bad; $_s ft_psk_generate_local not set" ;;
				esac
			fi
			if [ "$(roam_get "$_g.ieee80211k")" = 1 ] && [ "$(caps_get "iface.$_s.can_11k")" = 1 ]; then
				[ "$(wl_get "$_s" ieee80211k)" = 1 ] || [ "$(wl_get "$_s" rrm_neighbor_report)" = 1 ] || _bad="$_bad; $_s 802.11k not set"
			fi
			if [ "$(roam_get "$_g.ieee80211v")" = 1 ] && [ "$(caps_get "iface.$_s.can_11v")" = 1 ]; then
				[ "$(wl_get "$_s" bss_transition)" = 1 ] || _bad="$_bad; $_s bss_transition not set"
			fi
		done
		if [ -n "$_bad" ]; then
			report_add config "$_label" FAIL "${_bad#; } (run 'roamctl repair')"
		else
			report_add config "$_label" PASS "MDID $_md, $_sec, $(printf '%s' "$_ifs" | wc -w | tr -d ' ') interface(s) consistent"
		fi
		if mdid_valid "$_md"; then :; else
			report_add config "$_label MDID" FAIL "invalid Mobility Domain '$_md'"
		fi
	done
	_mc=$(mdid_conflicts)
	if [ -n "$_mc" ]; then
		printf '%s\n' "$_mc" | while IFS= read -r _l; do report_add config "MDID conflict" FAIL "$_l"; done
	else
		report_add config "MDID uniqueness" PASS "no Mobility Domain conflicts detected"
	fi
	cfg_conflicts | while IFS= read -r _l; do
		[ -n "$_l" ] && report_add config "SSID conflict" WARN "$_l"
	done
	# key material protection
	for _kf in "$ORM_KEY_DIR"/*; do
		[ -f "$_kf" ] || continue
		_mode=$(stat -c %a "$_kf" 2>/dev/null)
		if [ -n "$_mode" ] && [ "$_mode" != 600 ] && [ "$_mode" != 400 ]; then
			report_add config "key permissions" FAIL "$(basename "$_kf") has mode $_mode (expected 600)"
		fi
	done
	return 0
}
