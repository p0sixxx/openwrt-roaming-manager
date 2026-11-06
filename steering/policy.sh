# shellcheck shell=sh
# OpenWrt Roaming Manager - steering policy engine
#
# Pure decision logic used by the native backend. It never disconnects a
# client by itself; it only decides whether a BSS Transition Management
# *recommendation* should be sent and which candidates to offer, in which
# order. The client makes the final roaming decision.
#
# Protection mechanisms:
#   - per band thresholds with time hysteresis (N consecutive low samples)
#   - signal hysteresis: an episode re-arms only after the client recovers
#     above min + hysteresis
#   - cooldown between recommendations to the same client
#   - retry limit per low-signal episode
#   - ping-pong detection: too many BSS changes inside a time window
#     freeze steering for that client
#   - minimum association time before a client is considered
#   - exclusion list (never steer) and optional inclusion list
#   - candidates with a known signal that is not better by the hysteresis
#     are never offered; a 5/6 GHz target must exceed its minimum

# ------------------------------------------------------- client state
pol_state_dir() {
	printf '%s/steer' "$ORM_STATE"
}

pol_state_file() {
	printf '%s/%s' "$(pol_state_dir)" "$(printf '%s' "$1" | tr -d ':')"
}

pol_get() {
	# pol_get MAC KEY [DEFAULT]
	kv_get "$(pol_state_file "$1")" "$2" "${3:-}"
}

pol_set() {
	ensure_dir "$(pol_state_dir)"
	kv_set "$(pol_state_file "$1")" "$2" "$3"
}

# Record that a client was seen on BSS at time T; counts BSS changes.
pol_observe() {
	local _last _tr
	# pol_observe MAC BSSID BAND T
	_last=$(pol_get "$1" bss)
	if [ -n "$_last" ] && [ "$_last" != "$2" ]; then
		_tr="$(pol_get "$1" transitions) $4"
		pol_set "$1" transitions "$(pol_trim_window "$_tr" "$4")"
		pol_set "$1" low_count 0
		pol_set "$1" attempts 0
	fi
	pol_set "$1" bss "$2"
	case "$3" in
	5g | 6g) pol_set "$1" dualband 1 ;;
	esac
}

# Keep only timestamps inside the ping-pong window
pol_trim_window() {
	local _w _out _ts
	_w=$(pol_cfg pingpong_window 600)
	_out=''
	for _ts in $1; do
		[ $(($2 - _ts)) -le "$_w" ] && _out="$_out $_ts"
	done
	printf '%s' "${_out# }"
}

# Effective parameter: roamctl.steering.<key> (written by the optimizer)
pol_cfg() {
	local _v
	_v=$(orm_uci -q get "roamctl.steering.$1") || _v=''
	printf '%s' "${_v:-$2}"
}

pol_band_cfg() {
	# pol_band_cfg KEY BAND DEFAULT -> e.g. rssi_min_5g
	pol_cfg "${1}_$2" "$3"
}

# ------------------------------------------------------------ decide
# pol_decide MAC BAND RSSI BTM(0/1) CONNECTED_SECS CLIENTS_ON_BSS NOW CANDIDATES
# CANDIDATES: newline separated "bssid band load signal local" where
# signal is the client's signal at that BSS if known, otherwise "-".
# Output: "none <reason>" or "steer <reason> <bssid1> <bssid2> ..."
pol_decide() {
	local _mac _band _rssi _btm _conn _load _now _cands _incl _min _pref _hy _samples _cool _retry _ppmax _low _ls _tr _att _list
	_mac=$1 _band=$2 _rssi=$3 _btm=$4 _conn=$5 _load=$6 _now=$7 _cands=$8

	if list_contains "$(pol_cfg exclude_client)" "$_mac"; then
		echo "none excluded"
		return 0
	fi
	_incl=$(pol_cfg include_client)
	if [ -n "$_incl" ] && ! list_contains "$_incl" "$_mac"; then
		echo "none not-included"
		return 0
	fi
	is_uint "${_rssi#-}" || {
		echo "none no-signal"
		return 0
	}

	_min=$(pol_band_cfg rssi_min "$_band" -75)
	_pref=$(pol_band_cfg rssi_pref "$_band" -65)
	_hy=$(pol_band_cfg hyst "$_band" 6)
	_samples=$(pol_cfg low_samples 3)
	_cool=$(pol_cfg cooldown 120)
	_retry=$(pol_cfg retry_limit 3)
	_ppmax=$(pol_cfg pingpong_max 3)

	# Episode bookkeeping (signal hysteresis)
	_low=$(pol_get "$_mac" low_count 0)
	if [ "$_rssi" -lt "$_min" ]; then
		_low=$((_low + 1))
	elif [ "$_rssi" -ge $((_min + _hy)) ]; then
		_low=0
		pol_set "$_mac" attempts 0
	fi
	pol_set "$_mac" low_count "$_low"

	if [ "$_btm" != 1 ]; then
		echo "none no-btm-support"
		return 0
	fi
	if [ "$_conn" -lt "$(pol_cfg min_assoc_time 30)" ]; then
		echo "none settling"
		return 0
	fi
	_ls=$(pol_get "$_mac" last_steer 0)
	if [ $((_now - _ls)) -lt "$_cool" ]; then
		echo "none cooldown"
		return 0
	fi
	_tr=$(pol_trim_window "$(pol_get "$_mac" transitions)" "$_now")
	# shellcheck disable=SC2086
	set -- $_tr
	if [ "$#" -ge "$_ppmax" ]; then
		echo "none ping-pong-protection"
		return 0
	fi
	_att=$(pol_get "$_mac" attempts 0)

	# 1) signal based AP/band steering
	if [ "$_low" -ge "$_samples" ]; then
		if [ "$_att" -ge "$_retry" ]; then
			echo "none retry-limit"
			return 0
		fi
		_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" weak)
		if [ -n "$_list" ]; then
			echo "steer low-signal $_list"
			return 0
		fi
		echo "none no-better-candidate"
		return 0
	fi

	# 2) band steering: strong 2.4 GHz client, dual band capable
	if [ "$_band" = 2g ] && [ "$(pol_cfg band_steering 1)" = 1 ] &&
		[ "$_rssi" -ge "$(pol_cfg band_steer_rssi_2g -60)" ] &&
		[ "$(pol_get "$_mac" dualband 0)" = 1 ] && [ "$_att" -lt "$_retry" ]; then
		_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" band)
		if [ -n "$_list" ]; then
			echo "steer band-steering $_list"
			return 0
		fi
	fi

	# 3) load balancing: busy BSS, marginal signal, clearly less loaded peer
	if [ "$_load" -gt "$(pol_cfg load_threshold 20)" ] && [ "$_rssi" -lt "$_pref" ] && [ "$_att" -lt "$_retry" ]; then
		_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" load "$_load")
		if [ -n "$_list" ]; then
			echo "steer load-balancing $_list"
			return 0
		fi
	fi
	echo "none ok"
}

# Rank candidates. Prints space separated BSSIDs, best first.
# pol_rank_candidates BAND RSSI HYST CANDIDATES MODE [LOAD]
pol_rank_candidates() {
	local _cb _cr _ch _cc _mode _cl _ldiff _t5 _t6
	_cb=$1 _cr=$2 _ch=$3 _cc=$4 _mode=$5 _cl=${6:-0}
	_ldiff=$(pol_cfg load_diff 5)
	_t5=$(pol_cfg band_target_min_5g -70)
	_t6=$(pol_cfg band_target_min_6g -68)
	printf '%s\n' "$_cc" | awk -v cb="$_cb" -v cr="$_cr" -v ch="$_ch" -v mode="$_mode" \
		-v cl="$_cl" -v ldiff="$_ldiff" -v t5="$_t5" -v t6="$_t6" '
	NF >= 5 {
		bssid = $1; band = $2; load = $3 + 0; sig = $4; loc = $5
		known = (sig != "-")
		# never offer a BSS known to be worse than the current link
		if (known && sig + 0 < cr + ch) next
		if (mode == "band") {
			if (band != "5g" && band != "6g") next
			if (loc != 1) next
			if (known && band == "5g" && sig + 0 < t5) next
			if (known && band == "6g" && sig + 0 < t6) next
		}
		if (mode == "load") {
			if (load + ldiff > cl) next
		}
		# score: known signal dominates, then band preference, then load
		score = 0
		if (known) score += 1000 + (sig - cr) * 10
		if (band == "6g") score += 30; else if (band == "5g") score += 20
		if (mode == "weak" && band == "2g" && !known) score += 5  # 2.4 reaches further
		score -= load
		printf "%d %s\n", score, bssid
	}' | sort -rn | awk '{ printf "%s%s", (NR > 1 ? " " : ""), $2 } END { if (NR) printf "\n" }'
}

# Record a sent recommendation
pol_record_steer() {
	# pol_record_steer MAC NOW
	pol_set "$1" last_steer "$2"
	pol_set "$1" attempts $(($(pol_get "$1" attempts 0) + 1))
	pol_set "$1" steer_total $(($(pol_get "$1" steer_total 0) + 1))
}

# Remove state of clients not seen for a long time (memory hygiene)
pol_gc() {
	local _dir
	_dir=$(pol_state_dir)
	[ -d "$_dir" ] || return 0
	find "$_dir" -type f -mmin +120 -exec rm -f {} \; 2>/dev/null || true
}
