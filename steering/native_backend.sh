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
	[ "$(roam_get global.native_steering)" = 1 ] || return 1
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
# Cost per tick: per BSS one ubus call, one JSON parse and (with iw) one
# station dump; per client only shell builtins. State is saved once.

# Associated clients of a BSS -> lines "mac signal extcap2"
native_clients() {
	ubus call "hostapd.$1" get_clients 2>/dev/null | json_flatten | awk '
		/^clients\./ {
			p = $0; sub(/=.*/, "", p); v = substr($0, length(p) + 2)
			n = split(p, a, ".")
			if (n < 3) next
			m = tolower(a[2])
			if (!(m in seen)) { seen[m] = 1; order[++c] = m }
			f = a[3]
			if (f == "signal" && n == 3) sig[m] = v
			else if (f == "assoc" && n == 3) assoc[m] = v
			else if (f == "extended_capabilities" && n == 4 && a[4] == "2") ext[m] = v
		}
		END {
			for (i = 1; i <= c; i++) {
				m = order[i]
				if (assoc[m] == "false") continue
				if (m !~ /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) continue
				print m, (m in sig) ? sig[m] : "x", (m in ext) ? ext[m] : 0
			}
		}'
}

# " mac=seconds" list from iw station dump (empty without iw)
native_conn_times() {
	have_cmd iw || return 0
	iw dev "$1" station dump 2>/dev/null | awk '
		/^Station / { mac = tolower($2) }
		/connected time:/ { printf " %s=%s", mac, $3 }'
}

# word lookup in " key=value key=value" strings -> sets NV
native_lookup() {
	local _nl
	case "$1" in
	*" $2="*)
		_nl=${1#*" $2="}
		NV=${_nl%% *}
		;;
	*) NV='' ;;
	esac
}

native_tick() {
	local _now _kick _dis _groups _g _s _if _bss _band _loads _peers _ifs _times _cands _load _mac _sig _ext2 _btm _conn _act _why _hexes _t _cb _cband _chost _chex _cl _n _x _y _z _w
	uci_cache_warm
	pol_db_load
	_now=$(now)
	pol_cfg_v kick_mode none
	_kick=$POL_C
	_dis=0
	case "$_kick" in disassoc-imminent | deauth) _dis=1 ;; esac
	_groups=$(roam_groups)
	_peers=''
	[ -s "$ORM_ETC/peers.load" ] && _peers=" $(awk '{ printf "%s=%s ", $1, $2 }' "$ORM_ETC/peers.load")"

	# pass 1: per-BSS load of all local BSSes (used for candidate ranking)
	_loads='' _cl=''
	for _g in $_groups; do
		uci_cached_v roamctl "$_g" iface
		for _s in $UCI_V; do
			caps_v "iface.$_s.ifname"
			_if=$CAPS_V
			caps_v "iface.$_s.bssid"
			_bss=$CAPS_V
			[ -n "$_if" ] && [ -n "$_bss" ] || continue
			_ifs=$(native_clients "$_if")
			_n=0
			while read -r _mac _sig _ext2; do
				[ -n "$_mac" ] && _n=$((_n + 1))
			done <<NATIVE_EOF
$_ifs
NATIVE_EOF
			_loads="$_loads $_bss=$_n"
			_cl="$_cl$_g $_s $_if $_bss $_n$ORM_NL"
		done
	done

	# pass 2: decisions per client
	while read -r _g _s _if _bss _load; do
		[ -n "$_if" ] || continue
		caps_v "iface.$_s.band"
		_band=$CAPS_V
		_ifs=$(native_clients "$_if")
		[ -n "$_ifs" ] || continue
		_times=$(native_conn_times "$_if")
		# candidates: "bssid band load signal local hex"
		_cands=''
		if [ -f "$(nr_db)" ]; then
			while IFS="$ORM_FS" read -r _t _chost _x _cb _y _chex _cband _z; do
				[ "$_t" = "$_g" ] && [ "$_cb" != "$_bss" ] || continue
				if [ "$_chost" = local ]; then
					native_lookup "$_loads" "$_cb"
					_cands="$_cands$_cb $_cband ${NV:-$_load} - 1 $_chex$ORM_NL"
				else
					native_lookup "$_peers" "$_cb"
					_cands="$_cands$_cb $_cband ${NV:-$_load} - 0 $_chex$ORM_NL"
				fi
			done <"$(nr_db)"
		fi
		while read -r _mac _sig _ext2; do
			[ -n "$_mac" ] || continue
			_btm=0
			v_client_btm "$_ext2" && _btm=1
			native_lookup "$_times" "$_mac"
			_conn=$NV
			if [ -z "$_conn" ]; then
				pol_cfg_v min_assoc_time 30
				_conn=$POL_C
			fi
			pol_observe "$_mac" "$_bss" "$_band" "$_now"
			pol_decide_r "$_mac" "$_band" "$_sig" "$_btm" "$_conn" "$_load" "$_now" "$_cands"
			# shellcheck disable=SC2086
			set -- $POL_RESULT
			_act=$1 _why=$2
			shift 2
			if [ "$_act" = steer ]; then
				_hexes=''
				for _t in "$@"; do
					while read -r _cb _x _y _z _w _chex; do
						[ "$_cb" = "$_t" ] && _hexes="$_hexes $_chex"
					done <<NATIVE_EOF
$_cands
NATIVE_EOF
				done
				# shellcheck disable=SC2086
				if v_btm_request "$_if" "$_mac" "$_dis" 100 $_hexes; then
					ORM_SYSLOG=1 log_info "steer: BTM request to $_mac on $_if ($_why, signal ${_sig} dBm) -> $*"
				else
					log_debug "steer: BTM request to $_mac failed"
				fi
				pol_record_steer "$_mac" "$_now"
			elif [ "$_why" = no-btm-support ] && [ "$_kick" = deauth ]; then
				# explicit opt-in only: disconnect a legacy client stuck on a bad link
				pol_v "$_mac" low_count 0
				_n=$POL_V
				pol_cfg_v low_samples 3
				[ "$_n" -ge $((POL_C * 2)) ] || continue
				pol_v "$_mac" last_steer 0
				pol_cfg_v cooldown 120
				[ $((_now - POL_V)) -ge "$POL_C" ] || continue
				[ -n "$(pol_rank_candidates "$_band" "$_sig" 0 "$_cands" weak)" ] || continue
				ubus call "hostapd.$_if" del_client "{\"addr\":\"$_mac\",\"reason\":5,\"deauth\":false,\"ban_time\":0}" >/dev/null 2>&1
				pol_record_steer "$_mac" "$_now"
				ORM_SYSLOG=1 log_warn "steer: disassociated legacy client $_mac on $_if (kick_mode=deauth)"
			fi
		done <<NATIVE_EOF
$_ifs
NATIVE_EOF
	done <<NATIVE_EOF
$_cl
NATIVE_EOF
	pol_db_save
}

native_be_test() {
	local _ok _tot _g _s _if
	if [ "$(roam_get global.native_steering)" != 1 ]; then
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
