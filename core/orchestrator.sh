# shellcheck shell=sh
# OpenWrt Roaming Manager - orchestrator
#
# Ties the engines together for "setup", "repair" and the multi-AP agent:
#
#   detect -> groups (pending) -> plan -> show -> confirm
#     -> backup -> packages -> steering plan -> transaction (watchdog,
#        health check, rollback) -> services -> neighbor reports
#     -> validation -> summary
#
# Pending group records ($ORM_STATE/groups.pending, $ORM_FS separated):
#   gid ssid mdid mdid_origin ft_key_mode 11k 11v 11r ft_mode

groups_pending_file() {
	printf '%s/groups.pending' "$ORM_STATE"
}

# Interfaces of a group on this AP (from the group detection), in order
orch_group_ifaces() {
	# orch_group_ifaces GID
	printf '%s\n' "${ORCH_DETECTED_GROUPS:-}" | awk -F "$ORM_FS" -v g="$1" '$1 == g { print $3; exit }'
}

# Managed SSIDs / interfaces: the pending plan while a change is being
# prepared (groups are not committed yet), the stored config otherwise.
orch_managed_ssids() {
	local _pf _g _ssid _r
	_pf=$(groups_pending_file)
	if [ -s "$_pf" ] && [ -n "${ORCH_DETECTED_GROUPS:-}" ]; then
		while IFS="$ORM_FS" read -r _g _ssid _r; do
			[ -n "$(orch_group_ifaces "$_g")" ] && printf '%s\n' "$_ssid"
		done <"$_pf"
	else
		for _g in $(roam_groups); do roam_get "$_g.ssid"; echo; done
	fi
}

orch_managed_ifaces() {
	local _pf _g _r
	_pf=$(groups_pending_file)
	if [ -s "$_pf" ] && [ -n "${ORCH_DETECTED_GROUPS:-}" ]; then
		while IFS="$ORM_FS" read -r _g _r; do
			orch_group_ifaces "$_g" | tr ' ' '\n'
		done <"$_pf"
	else
		for _g in $(roam_groups); do roam_get "$_g.iface" | tr ' ' '\n'; done
	fi
}

orch_detect_groups() {
	ORCH_DETECTED_GROUPS=$(cfg_detect_groups)
	caps_reload
}

# Build pending groups for this AP (setup / repair).
# Honors ORM_ENABLE_11K/11V/11R (1/0), ORM_FT_MODE (air/ds),
# ORM_FT_KEY_MODE (auto/local/shared) and ORM_ONLY_SSID.
orch_pending_local() {
	local _pf _g _ssid _ifs _first _sec _mdo _md _origin _km _fm _k _v _r _s
	_pf=$(groups_pending_file)
	ensure_dir "$ORM_STATE"
	: >"$_pf"
	printf '%s\n' "$ORCH_DETECTED_GROUPS" | while IFS="$ORM_FS" read -r _g _ssid _ifs; do
		[ -n "$_g" ] || continue
		if [ -n "${ORM_ONLY_SSID:-}" ] && [ "$_ssid" != "$ORM_ONLY_SSID" ]; then
			continue
		fi
		_first=${_ifs%% *}
		_sec=$(caps_get "iface.$_first.security")
		# shellcheck disable=SC2086
		_mdo=$(mdid_ensure "$_g" "$_ssid" $_ifs) || continue
		_md=${_mdo%% *} _origin=${_mdo#* }
		_km=$(roam_get "$_g.ft_key_mode")
		if [ -z "$_km" ] || [ "${ORM_FT_KEY_MODE:-auto}" != auto ]; then
			_km=$(ft_key_mode_for "$_sec" "${ORM_FT_KEY_MODE:-auto}")
		fi
		# security may have changed since the last run
		[ "$_km" = local ] && [ "$_sec" != psk ] && _km=$(ft_key_mode_for "$_sec")
		_fm=${ORM_FT_MODE:-$(roam_get "$_g.ft_mode" air)}
		_k=0 _v=0 _r=0
		for _s in $_ifs; do
			[ "$(caps_get "iface.$_s.can_11k")" = 1 ] && _k=1
			[ "$(caps_get "iface.$_s.can_11v")" = 1 ] && _v=1
			[ "$(caps_get "iface.$_s.can_11r")" = 1 ] && _r=1
		done
		[ "${ORM_ENABLE_11K:-1}" = 0 ] && _k=0
		[ "${ORM_ENABLE_11V:-1}" = 0 ] && _v=0
		[ "${ORM_ENABLE_11R:-1}" = 0 ] && _r=0
		[ "$_r" = 1 ] || _km=none
		printf '%s\n' "$_g$ORM_FS$_ssid$ORM_FS$_md$ORM_FS$_origin$ORM_FS$_km$ORM_FS$_k$ORM_FS$_v$ORM_FS$_r$ORM_FS$_fm" >>"$_pf"
	done
}

# Pending records from the stored configuration (repair / sync)
orch_pending_from_config() {
	local _pf _g
	orch_detect_groups
	_pf=$(groups_pending_file)
	: >"$_pf"
	for _g in $(roam_groups); do
		printf '%s\n' "$_g$ORM_FS$(roam_get "$_g.ssid")$ORM_FS$(roam_get "$_g.mdid")${ORM_FS}existing$ORM_FS$(roam_get "$_g.ft_key_mode" local)$ORM_FS$(roam_get "$_g.ieee80211k" 0)$ORM_FS$(roam_get "$_g.ieee80211v" 0)$ORM_FS$(roam_get "$_g.ieee80211r" 0)$ORM_FS$(roam_get "$_g.ft_mode" air)" >>"$_pf"
	done
}

# Turn pending groups into a UCI plan (roamctl + wireless).
orch_plan_groups() {
	local _pf _g _ssid _md _origin _km _k _v _r _fm _ifs _p _s
	uci_cache_warm
	_pf=$(groups_pending_file)
	ORCH_GROUP_COUNT=0
	[ -s "$_pf" ] || return 1
	roam_cfg_init
	while IFS="$ORM_FS" read -r _g _ssid _md _origin _km _k _v _r _fm; do
		[ -n "$_g" ] || continue
		_ifs=$(orch_group_ifaces "$_g")
		if [ -z "$_ifs" ]; then
			log_warn "No eligible interface for SSID '$_ssid' on this AP - group skipped"
			continue
		fi
		if [ "$_k$_v$_r" = 000 ]; then
			log_warn "SSID '$_ssid': none of 802.11k/v/r is supported on its interfaces - not managed"
			continue
		fi
		ORCH_GROUP_COUNT=$((ORCH_GROUP_COUNT + 1))
		if [ "$_km" = shared ]; then
			ft_key_ensure "$_g" || return 1
		fi
		_p="roamctl.$_g"
		plan_set "$_p" group
		plan_set "$_p.ssid" "$_ssid"
		plan_set "$_p.mdid" "$_md"
		[ "$_origin" != existing ] && plan_set "$_p.mdid_origin" "$_origin"
		plan_set "$_p.ft_key_mode" "$_km"
		plan_set "$_p.ft_mode" "$_fm"
		plan_set "$_p.ieee80211k" "$_k"
		plan_set "$_p.ieee80211v" "$_v"
		plan_set "$_p.ieee80211r" "$_r"
		# shellcheck disable=SC2086
		plan_list "$_p.iface" $_ifs
		for _s in $_ifs; do
			[ "$_r" = 1 ] && r_plan_iface "$_s" "$_g" "$_md" "$_km" "$_fm"
			[ "$_k" = 1 ] && k_plan_iface "$_s"
			[ "$_v" = 1 ] && v_plan_iface "$_s"
		done
	done <"$_pf"
	[ "$ORCH_GROUP_COUNT" -gt 0 ]
}

orch_show_header() {
	local _i _r _band _bn _phy _f _m _be
	[ "$ORM_QUIET" = 1 ] && return 0
	banner "OPENWRT ROAMING MANAGER"
	{
		printf '\nDevice:    %s\n' "$(caps_get board.model)"
		printf 'Platform:  %s%s\n' "$(caps_get soc.family)" "$([ "$(caps_get soc.model)" != unknown ] && printf ' (%s)' "$(caps_get soc.model)")"
		printf 'OpenWrt:   %s (%s, %s)\n' "$(caps_get os.version)" "$(caps_get os.target)" "$(caps_get os.support)"
		printf 'Kernel:    %s\n' "$(caps_get kernel.version)"
		printf 'hostapd:   %s %s\n' "$(caps_get hostapd.package)" "$(caps_get hostapd.version)"
		printf 'Packages:  %s\n' "$(caps_get pkg.manager)"
		printf '\nDetected radios:\n'
		_i=0
		for _r in $(caps_get radio.list); do
			_i=$((_i + 1))
			_band=$(caps_get "radio.$_r.band")
			case "$_band" in 2g) _bn="2.4 GHz" ;; 5g) _bn="5 GHz" ;; 6g) _bn="6 GHz" ;; *) _bn=$_band ;; esac
			_phy=$(caps_get "radio.$_r.phy")
			printf '  [%d] %-7s %-8s %-6s driver=%s (%s)%s\n' "$_i" "$_bn" "$_r" "$_phy" \
				"$(caps_get "phy.$_phy.driver")" "$(caps_get "phy.$_phy.driver_class")" \
				"$([ "$(caps_get "radio.$_r.disabled")" = 1 ] && printf ' [disabled]')"
		done
		printf '\nCapabilities:\n'
		for _f in 11k 11v 11r; do
			case "$(caps_get "compat.$_f")" in
			all) _m="+" ;; some) _m="~" ;; *) _m="-" ;; esac
			printf '  [%s] 802.%s\n' "$_m" "$_f"
		done
		for _m in ft-psk ft-sae ft-eap; do
			if list_contains "$(caps_get compat.ft_modes)" "$_m"; then printf '  [+] %s\n' "$(upper "$_m")"; fi
		done
		printf '\nSteering:\n'
		for _be in usteer dawn; do
			if [ "$(caps_get "steer.$_be.running")" = 1 ]; then printf '  [+] %s running\n' "$_be"
			elif [ "$(caps_get "steer.$_be.installed")" = 1 ]; then printf '  [~] %s installed (inactive)\n' "$_be"
			else printf '  [ ] %s not installed\n' "$_be"; fi
		done
		printf '\n'
	} >&2
}

# List interfaces and why they are (not) managed
orch_show_ifaces() {
	local _s _st
	{
		printf 'Wireless interfaces:\n'
		for _s in $(caps_get iface.list); do
			_st="managed"
			if [ "$(caps_get "iface.$_s.eligible")" != 1 ]; then _st="skipped: $(caps_get "iface.$_s.why_eligible")"
			elif list_contains "${ORM_EXCLUDE:-}" "$_s"; then _st="skipped: excluded on command line"
			elif [ "$(caps_get "iface.$_s.special")" = 1 ] && ! list_contains "${ORM_INCLUDE:-}" "$_s"; then
				_st="skipped: guest/IoT/isolated network (use --include $_s)"
			else
				case "$(caps_get "iface.$_s.security")" in
				open | owe | wep | unknown)
					list_contains "${ORM_INCLUDE:-}" "$_s" || _st="skipped: security '$(caps_get "iface.$_s.encryption")' not suitable" ;;
				esac
			fi
			printf '  %-18s %-24s %-5s %-10s %s\n' "$_s" "'$(caps_get "iface.$_s.ssid")'" \
				"$(caps_get "iface.$_s.band")" "$(caps_get "iface.$_s.encryption")" "$_st"
		done
		printf '\n'
	} >&2
}

orch_show_plan() {
	local _g _ssid _md _origin _km _k _v _r _fm _c
	{
		printf 'Roaming groups:\n'
		while IFS="$ORM_FS" read -r _g _ssid _md _origin _km _k _v _r _fm; do
			[ -n "$_g" ] || continue
			printf "  '%s'  MDID %s (%s)  11k=%s 11v=%s 11r=%s  FT keys=%s  FT=%s  interfaces: %s\n" \
				"$_ssid" "$_md" "$_origin" "$_k" "$_v" "$_r" "$_km" "$_fm" "$(orch_group_ifaces "$_g")"
		done <"$(groups_pending_file)"
		_c=$(cfg_conflicts)
		if [ -n "$_c" ]; then
			printf '\nConflicts (not configured automatically):\n'
			printf '%s\n' "$_c" | sed 's/^/  ! /'
			printf '  -> make SSID, encryption and passphrase identical on all interfaces of a roaming network,\n'
			printf '     or exclude interfaces with --exclude <section>.\n'
		fi
		printf '\nSteering backend: %s (profile %s)\n' "${ORCH_BACKEND:-none}" "$(caps_get opt.profile balanced)"
		[ -n "$(caps_get steer.fallback_reason)" ] && printf '  note: %s\n' "$(caps_get steer.fallback_reason)"
		if [ -n "${ORCH_INSTALL:-}" ]; then
			printf 'Packages to install: %s\n' "$ORCH_INSTALL"
		fi
		printf '\nPlanned configuration changes:\n'
		plan_show
		printf '\n'
	} >&2
}

# Determine packages the steering backend needs (not installed yet)
orch_packages_needed() {
	local _pk
	ORCH_INSTALL=''
	[ "${ORCH_BACKEND:-none}" = none ] && return 0
	if ! steer_call "$ORCH_BACKEND" installed; then
		_pk=$(steer_call "$ORCH_BACKEND" package)
		[ -n "$_pk" ] && ORCH_INSTALL="$_pk"
	fi
}

orch_global_plan() {
	plan_set roamctl.global.profile "$(caps_get opt.profile balanced)"
	plan_set roamctl.global.steering_backend "${ORM_BACKEND_REQ:-auto}"
	[ -n "${ORM_NR_MODE:-}" ] && plan_set roamctl.global.nr_mode "$ORM_NR_MODE"
	opt_plan_persist
}

# Post-commit hook executed inside the transaction (before reload)
orch_post_commit() {
	local _daemon
	steer_post_apply
	_daemon=0
	[ "$(roam_get global.native_steering)" = 1 ] && _daemon=1
	[ "$(nr_effective_mode)" = static ] && _daemon=1
	orm_uci set "roamctl.global.daemon=$_daemon"
	orm_uci commit roamctl
	svc_set_enabled roamctl 1
	return 0
}

# Main apply path. Assumes detection + pending groups are done.
# Returns 0 on success.
orch_apply() {
	local _aps _req _be _rc _s _n
	plan_reset
	orch_plan_groups || {
		log_error "No roaming group can be configured on this AP"
		return 1
	}
	_aps=$(roam_ap_count)
	opt_compute "${ORM_PROFILE:-$(roam_get global.profile balanced)}" "$_aps"
	orch_global_plan
	_req=${ORM_BACKEND_REQ:-$(roam_get global.steering_backend auto)}
	ORCH_BACKEND=$(steer_select "$_req") || {
		log_error "Invalid steering backend '$_req'"
		return 1
	}
	orch_packages_needed
	# When the backend software is already present its configuration is
	# part of the plan shown to the user (and of the idempotency check).
	ORCH_STEER_PLANNED=0
	# (usteer must be running to report its options; it is not started
	# before the user confirmed, so then planning happens after confirm)
	if [ -z "$ORCH_INSTALL" ] && { [ "$ORCH_BACKEND" != usteer ] || steer_call usteer running; }; then
		steer_plan "$ORCH_BACKEND"
		ORCH_STEER_PLANNED=1
	fi
	[ "${ORM_INTERACTIVE_SHOW:-1}" = 1 ] && orch_show_plan

	if [ "$ORM_DRYRUN" = 1 ]; then
		log_info "Dry run - nothing was changed."
		return 0
	fi
	if [ "$(plan_count)" -eq 0 ] && [ -z "$ORCH_INSTALL" ] && [ -z "${ORM_STEER_DISABLE:-}" ] &&
		steer_backend_healthy "$ORCH_BACKEND"; then
		log_ok "Roaming configuration is already up to date - nothing to change"
		return 0
	fi
	confirm "Apply this configuration?" || {
		log_warn "Aborted by user - no changes made."
		return 2
	}

	health_baseline
	ORM_TXN_BACKUP=$(backup_create pre-setup) || {
		log_error "Backup failed - refusing to change configuration"
		return 1
	}
	caps_set run.backup "$ORM_TXN_BACKUP"

	# Packages (may fall back to the native backend)
	_be=$(steer_prepare "$ORCH_BACKEND")
	caps_reload
	if [ "$_be" != "$ORCH_BACKEND" ]; then
		ORCH_BACKEND=$_be
	elif [ -n "$ORCH_INSTALL" ] && [ "$_be" != native ]; then
		# keep the freshly installed daemon stopped until configured
		svc_set_enabled "$(steer_service_name "$_be")" 0
	fi
	steer_detect_backends
	[ "$ORCH_STEER_PLANNED" = 1 ] || steer_plan "$ORCH_BACKEND"

	transaction_apply setup orch_post_commit
	_rc=$?
	ORM_TXN_BACKUP=''
	[ "$_rc" -eq 0 ] || return 1

	# refresh runtime view (ifnames/BSSIDs may have changed after reload)
	wl_detect_all
	for _s in $(caps_get iface.list); do compat_eval_iface "$_s"; done
	# The neighbor DB is always maintained (validation, multi-AP, native
	# steering); hostapd lists are installed by roamctl only in static mode.
	_n=$(nr_collect_local local)
	log_debug "collected $_n own neighbor report(s)"
	if [ "$(nr_effective_mode)" = static ]; then
		nr_apply_local || log_warn "Some neighbor lists could not be installed"
	fi
	return 0
}

# Final summary block
orch_summary() {
	local _g _ftm _mds
	uci_cache_warm
	_st() { status_color "$1"; }
	_feat() {
		# enabled if at least one group enables it
		for _g in $(roam_groups); do
			[ "$(roam_get "$_g.$1")" = 1 ] && { printf ENABLED; return; }
		done
		printf DISABLED
	}
	_ftm=''
	for _g in $(roam_groups); do
		[ "$(roam_get "$_g.ieee80211r")" = 1 ] || continue
		case "$(roam_get "$_g.ft_mode" air)" in ds) _ftm="FT over the DS" ;; *) _ftm="FT over the Air" ;; esac
	done
	_mds=''
	for _g in $(roam_groups); do _mds="$_mds $(upper "$(roam_get "$_g.mdid")")"; done
	{
		printf '\n'
		banner "ROAMING SUMMARY"
		printf '\n802.11k:       %s\n' "$(_st "$(_feat ieee80211k)")"
		printf '802.11v:       %s\n' "$(_st "$(_feat ieee80211v)")"
		printf '802.11r:       %s\n' "$(_st "$(_feat ieee80211r)")"
		[ -n "$_ftm" ] && printf 'FT Mode:       %s\n' "$_ftm"
		printf 'Mobility ID:  %s\n' "${_mds:- -}"
		printf 'Steering:      %s\n' "$(_st "$(steer_status_line)")"
		printf 'Backend:       %s\n' "$(roam_get global.steering_backend_active none)"
		printf '\n'
		printf 'Configuration: %s\n' "$(_st "$(report_category_status config)")"
		printf 'Hostapd:       %s\n' "$(_st "$(report_category_status hostapd)")"
		printf 'Connectivity:  %s\n' "$(_st "$(report_category_status connectivity)")"
		printf '802.11k:       %s\n' "$(_st "$(report_category_status 11k)")"
		printf '802.11v:       %s\n' "$(_st "$(report_category_status 11v)")"
		printf '802.11r:       %s\n' "$(_st "$(report_category_status 11r)")"
		printf 'Steering:      %s\n' "$(_st "$(report_category_status steering)")"
		[ "$(roam_ap_count)" -gt 1 ] && printf 'Multi-AP:      %s\n' "$(_st "$(report_category_status multiap)")"
		printf '\nLive Roaming:  %s\n' "$(_st "$(report_category_status live)")"
		if [ -n "$(caps_get run.backup)" ]; then
			printf '\nBackup:        %s (%s)\n' "$(_st CREATED)" "$(caps_get run.backup)"
		fi
		if [ "$(caps_get run.rolled_back)" = 1 ]; then
			printf 'Rollback:      %s\n' "$(_st PERFORMED)"
		fi
		if [ "$(report_category_status live)" != PASS ] && ! report_has_fail; then
			printf '\nCONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED\n'
		fi
		printf '%s\n' "=================================================="
	} >&2
}
