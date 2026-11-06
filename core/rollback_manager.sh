# shellcheck shell=sh
# OpenWrt Roaming Manager - rollback manager and recovery watchdog
#
# Commit-confirm model (like LuCI's "apply with rollback"):
#   1. a backup is created
#   2. a persistent "pending" marker is written to flash (/etc/roamctl)
#   3. a detached watchdog process is started (survives SSH loss)
#   4. the new configuration is applied and wireless reloaded
#   5. health checks run; on success the change is confirmed and the
#      watchdog exits. On failure the backup is restored immediately.
#   6. if roamctl itself dies (e.g. SSH session over Wi-Fi drops), the
#      watchdog restores the backup once the deadline passes.
#   7. if the device loses power while pending, the init script restores
#      the backup at the next boot (rollback_boot_check).

pending_file() {
	printf '%s/pending' "$ORM_ETC"
}

# ---------------------------------------------------------------- health
# Count BSSes known to hostapd via ubus.
health_bss_count() {
	have_cmd ubus || {
		echo 0
		return
	}
	ubus list 'hostapd.*' 2>/dev/null | grep -c '^hostapd\.'
}

health_radios_up() {
	local _ws _r
	# prints names of radios with "up": true
	_ws=$(ubus call network.wireless status 2>/dev/null) || return 0
	for _r in $(caps_get radio.list); do
		[ "$(json_get "$_ws" "$_r.up")" = true ] && printf '%s ' "$_r"
	done
}

health_gateway() {
	ip -4 route show default 2>/dev/null | awk '/^default/ {print $3; exit}'
}

health_gateway_ok() {
	local _gw
	_gw=$(health_gateway)
	[ -n "$_gw" ] || return 1
	ping -c 1 -W 2 "$_gw" >/dev/null 2>&1
}

# Snapshot of the state before a change (stored in $ORM_STATE/baseline)
health_baseline() {
	local _bf
	_bf="$ORM_STATE/baseline"
	ensure_dir "$ORM_STATE"
	{
		printf 'bss=%s\n' "$(health_bss_count)"
		printf 'radios=%s\n' "$(health_radios_up)"
		if health_gateway_ok; then printf 'gw=1\n'; else printf 'gw=0\n'; fi
	} >"$_bf"
}

# Wait until netifd finished (re)configuring wireless.
wireless_settle() {
	local _timeout _want_bss _t _ws
	_timeout=${ORM_SETTLE_TIMEOUT:-60}
	_want_bss=${1:-0}
	_t=0
	sleep "${ORM_SETTLE_MIN:-3}"
	while [ "$_t" -lt "$_timeout" ]; do
		_ws=$(ubus call network.wireless status 2>/dev/null)
		case "$_ws" in
		*'"pending": true'* | *'"pending":true'*) ;;
		*)
			[ "$(health_bss_count)" -ge "$_want_bss" ] && return 0
			;;
		esac
		sleep 2
		_t=$((_t + 2))
	done
	return 1
}

# health_check -> 0 if healthy compared with the baseline. Failed checks
# are printed to stdout, one per line.
health_check() {
	local _bf _b_bss _b_radios _b_gw _hc_fail _n _now_radios _r
	_bf="$ORM_STATE/baseline"
	_b_bss=$(kv_get "$_bf" bss 0)
	_b_radios=$(kv_get "$_bf" radios)
	_b_gw=$(kv_get "$_bf" gw 0)
	_hc_fail=0
	if [ -n "$(orm_uci changes wireless 2>/dev/null)" ]; then
		echo "uci: uncommitted wireless changes remain"
		_hc_fail=1
	fi
	_n=$(health_bss_count)
	if [ "$_n" -lt "$_b_bss" ]; then
		echo "hostapd: only $_n of $_b_bss BSS active after reload"
		_hc_fail=1
	fi
	if [ "$_b_bss" -gt 0 ] && [ "$_n" -eq 0 ]; then
		echo "hostapd: no BSS running"
		_hc_fail=1
	fi
	_now_radios=$(health_radios_up)
	for _r in $_b_radios; do
		list_contains "$_now_radios" "$_r" || {
			echo "wireless: $_r was up before and is down now"
			_hc_fail=1
		}
	done
	if [ "$_b_gw" = 1 ] && ! health_gateway_ok; then
		# give the bridge a moment (STP/learning) before failing
		sleep 3
		health_gateway_ok || {
			echo "network: default gateway unreachable after change"
			_hc_fail=1
		}
	fi
	return $_hc_fail
}

# --------------------------------------------------------------- reload
wireless_reload() {
	[ "$ORM_DRYRUN" = 1 ] && return 0
	log_info "Reloading wireless configuration..."
	wifi reload >>"$ORM_LOG" 2>&1 || wifi >>"$ORM_LOG" 2>&1
}

# ------------------------------------------------------------- watchdog
rollback_arm() {
	local _deadline _self
	# rollback_arm BACKUP_ID TIMEOUT
	_deadline=$(($(now) + $2))
	{
		printf 'id=%s\n' "$1"
		printf 'deadline=%s\n' "$_deadline"
		printf 'pid=%s\n' "$$"
	} | atomic_write "$(pending_file)" 600
	[ "$ORM_DRYRUN" = 1 ] && return 0
	# Detach completely: new session, no controlling terminal, HUP ignored
	_self=${ORM_SELF:-roamctl}
	if have_cmd setsid; then
		setsid "$_self" __watchdog "$1" "$_deadline" </dev/null >/dev/null 2>&1 &
	else
		(trap '' HUP; exec "$_self" __watchdog "$1" "$_deadline") </dev/null >/dev/null 2>&1 &
	fi
	kv_set "$(pending_file)" watchdog "$!"
	log_debug "watchdog armed for backup $1 (deadline in ${2}s)"
}

rollback_confirm() {
	local _wd
	_wd=$(kv_get "$(pending_file)" watchdog)
	rm -f "$(pending_file)"
	[ -n "$_wd" ] && kill "$_wd" 2>/dev/null
	log_debug "change confirmed, watchdog disarmed"
	return 0
}

rollback_is_pending() {
	[ -f "$(pending_file)" ]
}

# Runs detached. Polls until the deadline; if the change has not been
# confirmed (pending file still references our backup) it rolls back.
rollback_watchdog() {
	local _id _deadline
	_id=$1 _deadline=$2
	trap '' HUP INT
	while [ "$(now)" -lt "$_deadline" ]; do
		[ "$(kv_get "$(pending_file)" id)" = "$_id" ] || exit 0
		sleep 1
	done
	[ "$(kv_get "$(pending_file)" id)" = "$_id" ] || exit 0
	ORM_SYSLOG=1
	log_error "Configuration change was not confirmed in time - rolling back to backup $_id"
	rollback_now "$_id" watchdog
}

# Restore a backup and bring wireless back up.
rollback_now() {
	local _id _why
	_id=$1 _why=${2:-manual}
	if ! backup_restore "$_id"; then
		log_error "Rollback failed: backup $_id unusable"
		return 1
	fi
	rm -f "$(pending_file)"
	wireless_reload
	wireless_settle 0 || true
	kv_set "$ORM_ETC/last_rollback" id "$_id"
	kv_set "$ORM_ETC/last_rollback" reason "$_why"
	kv_set "$ORM_ETC/last_rollback" time "$(now)"
	log_warn "Rolled back to backup $_id ($_why)"
	return 0
}

# Called from the init script at boot.
rollback_boot_check() {
	local _id
	rollback_is_pending || return 0
	_id=$(kv_get "$(pending_file)" id)
	ORM_SYSLOG=1
	log_error "Unconfirmed roamctl change found at boot - restoring backup $_id"
	backup_restore "$_id" && rm -f "$(pending_file)"
	kv_set "$ORM_ETC/last_rollback" id "$_id"
	kv_set "$ORM_ETC/last_rollback" reason boot
}

# Transactional apply of the current plan:
#   backup -> arm -> uci apply+commit -> reload -> settle -> health -> confirm
# Returns 0 on success, 1 on failure (system restored).
transaction_apply() {
	local _reason _post_hook _bid _tmo _want _fails _l
	_reason=${1:-apply}
	_post_hook=${2:-}
	if [ "$ORM_DRYRUN" = 1 ]; then
		log_info "[dry-run] no changes written"
		return 0
	fi
	health_baseline
	_bid=${ORM_TXN_BACKUP:-}
	if [ -z "$_bid" ]; then
		_bid=$(backup_create "$_reason") || {
			log_error "Backup failed - refusing to change configuration"
			return 1
		}
	fi
	caps_set run.backup "$_bid"
	_tmo=$(roam_get global.watchdog_timeout 180)
	is_uint "$_tmo" || _tmo=180
	rollback_arm "$_bid" "${ORM_WATCHDOG_TIMEOUT:-$_tmo}"
	trap '' HUP

	if ! plan_apply; then
		log_error "Applying UCI changes failed"
		cfg_revert
		rollback_now "$_bid" uci-error
		return 1
	fi
	if ! cfg_commit; then
		log_error "uci commit failed"
		rollback_now "$_bid" uci-commit
		return 1
	fi
	if [ -n "$_post_hook" ]; then
		"$_post_hook" || log_warn "post-apply hook reported problems"
	fi
	if list_contains "$ORM_CHANGED_CONFIGS" wireless || [ "${ORM_FORCE_RELOAD:-0}" = 1 ]; then
		wireless_reload
		_want=$(kv_get "$ORM_STATE/baseline" bss 0)
		wireless_settle "$_want" || log_warn "wireless did not settle within timeout"
	fi
	_fails=$(health_check)
	if [ -n "$_fails" ]; then
		printf '%s\n' "$_fails" | while IFS= read -r _l; do log_error "health: $_l"; done
		log_error "Critical checks failed - restoring previous configuration"
		rollback_now "$_bid" health-check
		caps_set run.rolled_back 1
		return 1
	fi
	rollback_confirm
	trap - HUP
	log_ok "Configuration applied and verified"
	return 0
}
