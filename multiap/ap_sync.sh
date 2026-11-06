# shellcheck shell=sh
# OpenWrt Roaming Manager - Multi-AP configuration synchronisation
#
# Rollout is staged: one AP at a time. Every member applies the change
# inside its own transaction (backup -> watchdog -> apply -> health check
# -> confirm or rollback). The rollout stops at the first member that
# fails, so a bad change can never take down all APs at once. An
# unreachable AP is skipped and reported; other APs are not modified
# because of it.
#
# Payload (stdin of "roamctl agent apply"), $ORM_FS separated lines:
#   orm-sync 1
#   global  <profile> <backend> <nr_mode>
#   group   <gid> <ssid> <mdid> <ft_key_mode> <11k> <11v> <11r> <ft_mode>
#   ftkey   <gid> <64 hex>            (secret, only over SSH stdin)
#   dawn    <shared_key> <iv>         (secret, only if DAWN is used)
#   end

sync_payload() {
	local _F _g _k
	_F=$ORM_FS
	printf 'orm-sync%s1\n' "$_F"
	printf 'global%s%s%s%s%s%s\n' "$_F" "$(roam_get global.profile balanced)" "$_F" \
		"$(roam_get global.steering_backend_active none)" "$_F" "$(roam_get global.nr_mode auto)"
	for _g in $(roam_groups); do
		printf 'group%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$_F" "$_g" "$_F" "$(roam_get "$_g.ssid")" \
			"$_F" "$(roam_get "$_g.mdid")" "$_F" "$(roam_get "$_g.ft_key_mode" local)" \
			"$_F" "$(roam_get "$_g.ieee80211k" 0)" "$_F" "$(roam_get "$_g.ieee80211v" 0)" \
			"$_F" "$(roam_get "$_g.ieee80211r" 0)" "$_F" "$(roam_get "$_g.ft_mode" air)"
		if [ "$(roam_get "$_g.ft_key_mode")" = shared ]; then
			_k=$(ft_key_read "$_g") && printf 'ftkey%s%s%s%s\n' "$_F" "$_g" "$_F" "$_k"
		fi
	done
	if [ -f "$(dawn_secret_file)" ]; then
		printf 'dawn%s%s%s%s\n' "$_F" "$(kv_get "$(dawn_secret_file)" shared_key)" "$_F" "$(kv_get "$(dawn_secret_file)" iv)"
	fi
	printf 'end\n'
}

# Parse and validate a payload on the member; writes groups.pending and
# key files. Returns 1 on any malformed input (nothing is changed).
sync_payload_import() {
	local _pend _tmp _hdr _end _keys _dawn _t _a _b _c _d _e _f _g _h _x _kv
	_pend="$ORM_STATE/groups.pending"
	_tmp="$_pend.tmp"
	ensure_dir "$ORM_STATE"
	: >"$_tmp"
	_hdr=0 _end=0 _keys='' _dawn=''
	SYNC_PROFILE='' SYNC_BACKEND='' SYNC_NRMODE=''
	while IFS="$ORM_FS" read -r _t _a _b _c _d _e _f _g _h; do
		case "$_t" in
		orm-sync) [ "$_a" = 1 ] && _hdr=1 ;;
		global)
			case "$_a" in conservative | balanced | aggressive | iot-safe) SYNC_PROFILE=$_a ;; *) return 1 ;; esac
			case "$_b" in usteer | dawn | native | none) SYNC_BACKEND=$_b ;; *) return 1 ;; esac
			case "$_c" in auto | static | backend | off) SYNC_NRMODE=$_c ;; *) return 1 ;; esac
			;;
		group)
			printf '%s' "$_a" | grep -Eq '^g_[0-9a-f]{8}$' || return 1
			[ "$(group_id_for_ssid "$_b")" = "$_a" ] || return 1
			mdid_valid "$_c" || return 1
			case "$_d" in local | shared | none) ;; *) return 1 ;; esac
			for _x in "$_e" "$_f" "$_g"; do case "$_x" in 0 | 1) ;; *) return 1 ;; esac; done
			case "$_h" in air | ds) ;; *) return 1 ;; esac
			printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' "$_a" "$ORM_FS" "$_b" "$ORM_FS" "$_c" "$ORM_FS" synced \
				"$ORM_FS" "$_d" "$ORM_FS" "$_e" "$ORM_FS" "$_f" "$ORM_FS" "$_g" "$ORM_FS" "$_h" >>"$_tmp"
			;;
		ftkey)
			printf '%s' "$_a" | grep -Eq '^g_[0-9a-f]{8}$' || return 1
			ft_key_valid "$_b" || return 1
			_keys="$_keys $_a:$_b"
			;;
		dawn)
			printf '%s%s' "$_a" "$_b" | grep -Eq '^[0-9a-f]+$' || return 1
			_dawn="$_a $_b"
			;;
		end) _end=1 ;;
		'') ;;
		*) return 1 ;;
		esac
	done
	[ "$_hdr" = 1 ] && [ "$_end" = 1 ] || return 1
	mv -f "$_tmp" "$_pend"
	for _kv in $_keys; do
		ft_key_write "${_kv%%:*}" "${_kv#*:}" || return 1
	done
	if [ -n "$_dawn" ]; then
		ensure_dir "$ORM_KEY_DIR" 0700
		# shellcheck disable=SC2086
		set -- $_dawn
		printf 'shared_key=%s\niv=%s\n' "$1" "$2" | atomic_write "$(dawn_secret_file)" 600
	fi
	return 0
}

# Push configuration to one AP; prints agent output.
sync_ap() {
	local _ap
	_ap=$1
	sync_payload | ssh_agent "$_ap" apply
}

# Staged rollout to all enabled member APs.
# Returns number of failed APs (0 = all good).
sync_all() {
	local _failed _skipped _ok _order _total _i _ap _conf _crc _l _res _why
	_failed=0 _skipped=0 _ok=0
	_order=$(roam_aps_enabled)
	_total=$(printf '%s\n' "$_order" | grep -c .)
	_i=0
	for _ap in $_order; do
		_i=$((_i + 1))
		progress "$_i" "$_total" "$_ap"
		log_step "[$_i/$_total] $_ap ($(orm_uci -q get "roamctl.$_ap.host"))"
		if ! topo_probe_ap "$_ap"; then
			log_warn "$_ap is unreachable - skipped, its configuration is untouched"
			report_add multiap "$_ap" FAIL "unreachable over SSH; not synchronised"
			_skipped=$((_skipped + 1))
			continue
		fi
		_conf=$(topo_check_ap "$_ap")
		_crc=$?
		[ -n "$_conf" ] && printf '%s\n' "$_conf" | while IFS= read -r _l; do log_warn "$_l"; done
		if [ "$_crc" -ne 0 ]; then
			report_add multiap "$_ap" FAIL "configuration conflict - not merged: $(printf '%s' "$_conf" | tr '\n' ';')"
			_failed=$((_failed + 1))
			continue
		fi
		_res=$(sync_ap "$_ap" 2>/dev/null)
		if printf '%s\n' "$_res" | grep -qx 'result=ok'; then
			report_add multiap "$_ap" PASS "synchronised (backup $(printf '%s\n' "$_res" | sed -n 's/^backup=//p'))"
			_ok=$((_ok + 1))
		else
			_why=$(printf '%s\n' "$_res" | sed -n 's/^error=//p' | head -n1)
			report_add multiap "$_ap" FAIL "apply failed${_why:+: $_why}; AP rolled back to its previous configuration"
			_failed=$((_failed + 1))
			log_error "$_ap failed - stopping rollout so remaining APs keep their working configuration"
			break
		fi
	done
	caps_set sync.ok "$_ok"
	caps_set sync.failed "$_failed"
	caps_set sync.skipped "$_skipped"
	return $((_failed + _skipped))
}

# Collect own neighbor reports from all APs and distribute the merged DB.
sync_neighbors() {
	local _ap _entries _l _b _h
	nr_collect_local local >/dev/null
	for _ap in $(roam_aps_enabled); do
		[ "$(caps_get "remote.$_ap.reachable" 1)" = 1 ] || continue
		_entries=$(ssh_agent "$_ap" nr-own </dev/null 2>/dev/null) || continue
		# entries are re-labelled with the AP section name and validated
		printf '%s\n' "$_entries" | awk -F "$ORM_FS" -v OFS="$ORM_FS" -v h="$_ap" 'NF >= 8 { $2 = h; print }' |
			while IFS= read -r _l; do
				_b=$(printf '%s' "$_l" | cut -d"$ORM_FS" -f4)
				_h=$(printf '%s' "$_l" | cut -d"$ORM_FS" -f6)
				is_mac "$_b" && nr_validate "$_b" "$_h" && printf '%s\n' "$_l"
			done | nr_db_merge_host "$_ap"
	done
	# push merged DB; members translate "local" entries back on import
	for _ap in $(roam_aps_enabled); do
		[ "$(caps_get "remote.$_ap.reachable" 1)" = 1 ] || continue
		if awk -F "$ORM_FS" -v OFS="$ORM_FS" -v h="$_ap" '{ if ($2 == "local") $2 = "controller"; print }' "$(nr_db)" |
			ssh_agent "$_ap" nr-set 2>/dev/null | grep -qx 'result=ok'; then
			report_add multiap "$_ap neighbors" PASS "neighbor reports distributed"
		else
			report_add multiap "$_ap neighbors" FAIL "neighbor report distribution failed"
		fi
	done
	[ "$(nr_effective_mode)" = static ] && nr_apply_local
	return 0
}
