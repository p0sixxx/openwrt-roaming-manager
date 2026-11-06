# shellcheck shell=sh
# OpenWrt Roaming Manager - native steering backend
#
# Built-in backend for systems where neither usteer nor DAWN can be
# installed. It drives hostapd directly over ubus:
#   * reads associated clients, signal and capabilities (get_clients)
#   * decides with the policy engine (steering/policy.sh)
#   * sends 802.11v BSS Transition Management requests with a ranked
#     candidate list built from real neighbor reports
# Clients without BTM support are left alone unless the administrator
# explicitly sets roamctl.steering.kick_mode=deauth.
#
# It runs inside the "roamctl" procd service (roamctl daemon).

native_be_package() { printf ''; }

native_be_installed() { return 0; }

native_be_running() {
	local _pid
	[ "$(orm_uci -q get roamctl.global.native_steering)" = 1 ] || return 1
	_pid=$(cat "$ORM_STATE/daemon.pid" 2>/dev/null)
	[ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

native_be_handles_nr() { return 1; }

native_be_features() {
	printf 'rssi-steering ap-steering band-steering load-balancing min-rssi preferred-rssi hysteresis cooldown retry-limit client-blacklist client-whitelist ping-pong-prevention per-band-thresholds'
}

native_be_configure() {
	plan_set roamctl.global.native_steering 1
	plan_set roamctl.global.daemon 1
	return 0
}

native_be_post_apply() {
	[ "$ORM_DRYRUN" = 1 ] && return 0
	svc_set_enabled roamctl 1
}

native_be_enable() {
	orm_uci set roamctl.global.native_steering=1
	orm_uci commit roamctl
	svc_set_enabled roamctl 1
}

native_be_disable() {
	local _init
	orm_uci set roamctl.global.native_steering=0
	orm_uci commit roamctl
	_init=$(orm_path /etc/init.d/roamctl)
	[ -x "$_init" ] && "$_init" restart >/dev/null 2>&1
	return 0
}

# ------------------------------------------------------------ tick
# Extended capabilities octet 2 of a client from a flattened get_clients
native_client_field() {
	# native_client_field FLATFILE MAC FIELD
	awk -v k="clients.$2.$3=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}

# "mac seconds" pairs from iw station dump
native_conn_times() {
	have_cmd iw || return 0
	iw dev "$1" station dump 2>/dev/null | awk '
		/^Station / { mac = tolower($2) }
		/connected time:/ { print mac, $3 }'
}

native_bss_load() {
	local _f
	_f="$ORM_STATE/native.load"
	awk -v b="$1" '$1 == b { print $2; exit }' "$_f" 2>/dev/null
}

# Build candidate lines "bssid band load signal local" for a group/BSS
native_candidates() {
	local _cb _cband _chost _cload _loc
	# native_candidates GROUP OWN_BSSID OWN_LOAD
	awk -F "$ORM_FS" -v g="$1" -v b="$2" '$1 == g && $4 != b { print $4, $7, $2 }' "$(nr_db)" 2>/dev/null |
		while read -r _cb _cband _chost; do
			if [ "$_chost" = local ]; then
				_cload=$(native_bss_load "$_cb")
				_loc=1
			else
				_cload=$(awk -v b="$_cb" '$1 == b { print $2; exit }' "$ORM_ETC/peers.load" 2>/dev/null)
				_loc=0
			fi
			printf '%s %s %s - %s\n' "$_cb" "$_cband" "${_cload:-$3}" "$_loc"
		done
}

native_nr_hex() {
	# native_nr_hex GROUP BSSID
	awk -F "$ORM_FS" -v g="$1" -v b="$2" '$1 == g && $4 == b { print $6; exit }' "$(nr_db)"
}

native_tick() {
	local _now _kick _g _s _if _bss _band _flat _load _times _cands _mac _sig _ext2 _btm _conn _dec _act _why _hexes _t _hx _dis
	_now=$(now)
	_kick=$(pol_cfg kick_mode none)
	ensure_dir "$ORM_STATE"
	# per-BSS client counts (used for load decisions)
	: >"$ORM_STATE/native.load.tmp"
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			[ -n "$_if" ] || continue
			printf '%s %s\n' "$(caps_get "iface.$_s.bssid")" "$(opt_bss_clients "$_if")" >>"$ORM_STATE/native.load.tmp"
		done
	done
	mv -f "$ORM_STATE/native.load.tmp" "$ORM_STATE/native.load"

	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			_bss=$(caps_get "iface.$_s.bssid")
			_band=$(caps_get "iface.$_s.band")
			[ -n "$_if" ] && [ -n "$_bss" ] || continue
			_flat="$ORM_STATE/native.clients"
			ubus call "hostapd.$_if" get_clients 2>/dev/null | json_flatten >"$_flat" || continue
			_load=$(native_bss_load "$_bss")
			_times=$(native_conn_times "$_if")
			_cands=$(native_candidates "$_g" "$_bss" "${_load:-0}")
			# shellcheck disable=SC2013
			for _mac in $(awk -F. '/^clients\./ { print $2 }' "$_flat" | sort -u); do
				is_mac "$_mac" || continue
				_mac=$(lower "$_mac")
				[ "$(native_client_field "$_flat" "$_mac" assoc)" = false ] && continue
				_sig=$(native_client_field "$_flat" "$_mac" signal)
				_ext2=$(native_client_field "$_flat" "$_mac" extended_capabilities.2)
				_btm=0
				v_client_btm "$_ext2" && _btm=1
				_conn=$(printf '%s\n' "$_times" | awk -v m="$_mac" '$1 == m { print $2; exit }')
				[ -n "$_conn" ] || _conn=$(pol_cfg min_assoc_time 30)
				pol_observe "$_mac" "$_bss" "$_band" "$_now"
				_dec=$(pol_decide "$_mac" "$_band" "${_sig:-x}" "$_btm" "$_conn" "${_load:-0}" "$_now" "$_cands")
				# shellcheck disable=SC2086
				set -- $_dec
				_act=$1 _why=$2
				shift 2
				if [ "$_act" = steer ]; then
					_hexes=''
					for _t in "$@"; do
						_hx=$(native_nr_hex "$_g" "$_t")
						[ -n "$_hx" ] && _hexes="$_hexes $_hx"
					done
					_dis=0
					[ "$_kick" = disassoc-imminent ] || [ "$_kick" = deauth ] && _dis=1
					# shellcheck disable=SC2086
					if v_btm_request "$_if" "$_mac" "$_dis" 100 $_hexes; then
						pol_record_steer "$_mac" "$_now"
						ORM_SYSLOG=1 log_info "steer: BTM request to $_mac on $_if ($_why, signal ${_sig} dBm) -> $*"
					else
						log_debug "steer: BTM request to $_mac failed"
						pol_record_steer "$_mac" "$_now"
					fi
				elif [ "$_why" = no-btm-support ] && [ "$_kick" = deauth ] &&
					[ "$(pol_get "$_mac" low_count 0)" -ge $(($(pol_cfg low_samples 3) * 2)) ] &&
					[ $((_now - $(pol_get "$_mac" last_steer 0))) -ge "$(pol_cfg cooldown 120)" ] &&
					[ -n "$(pol_rank_candidates "$_band" "${_sig:-0}" 0 "$_cands" weak)" ]; then
					# explicit opt-in only: disconnect a legacy client stuck on a bad link
					ubus call "hostapd.$_if" del_client "{\"addr\":\"$_mac\",\"reason\":5,\"deauth\":false,\"ban_time\":0}" >/dev/null 2>&1
					pol_record_steer "$_mac" "$_now"
					ORM_SYSLOG=1 log_warn "steer: disassociated legacy client $_mac on $_if (kick_mode=deauth)"
				fi
			done
		done
	done
}

native_be_test() {
	local _ok _tot _g _s _if
	if [ "$(orm_uci -q get roamctl.global.native_steering)" != 1 ]; then
		report_add steering native FAIL "native steering not enabled in /etc/config/roamctl"
		return 1
	fi
	if native_be_running; then
		report_add steering native PASS "roamctl steering daemon running"
	else
		report_add steering native FAIL "roamctl steering daemon not running"
		return 1
	fi
	_ok=0 _tot=0
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			[ -n "$_if" ] || continue
			_tot=$((_tot + 1))
			ubus call "hostapd.$_if" get_clients >/dev/null 2>&1 && _ok=$((_ok + 1))
		done
	done
	if [ "$_tot" -gt 0 ] && [ "$_ok" = "$_tot" ]; then
		report_add steering "client data" PASS "client information readable on $_ok BSS"
	else
		report_add steering "client data" FAIL "client information readable on $_ok of $_tot BSS"
	fi
	return 0
}
