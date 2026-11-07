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
# Per-client state lives in memory (POL_DB, newline separated
# "<mac>.<key>=<value>" records, last value wins) and is written to
# $ORM_STATE/steer.db once per daemon tick (pol_db_save). Lookups and
# updates need no process at all - the daemon must stay cheap on single
# core MIPS access points (MT7628) with many clients.
POL_DB=''
POL_DB_LOADED=0

pol_db_file() {
	printf '%s/steer.db' "$ORM_STATE"
}

pol_db_load() {
	[ "$POL_DB_LOADED" = 1 ] && return 0
	POL_DB_LOADED=1
	POL_DB=''
	[ -s "$ORM_STATE/steer.db" ] && POL_DB="$ORM_NL$(cat "$ORM_STATE/steer.db")"
	return 0
}

# Compact (last value per key) and persist; drops clients not seen for 2h
pol_db_save() {
	pol_db_load
	ensure_dir "$ORM_STATE"
	printf '%s\n' "$POL_DB" | awk -v now="$(now)" '
		/^[0-9a-f:]+\.[a-z_]+=/ {
			k = $0; sub(/=.*/, "", k)
			if (!(k in v)) order[++n] = k
			v[k] = substr($0, length(k) + 2)
			m = k; sub(/\..*/, "", m)
			if (k == m ".seen") seen[m] = v[k] + 0
		}
		END {
			for (i = 1; i <= n; i++) {
				k = order[i]; m = k; sub(/\..*/, "", m)
				if ((m in seen) && now - seen[m] > 7200) continue
				print k "=" v[k]
			}
		}' | atomic_write "$ORM_STATE/steer.db"
	POL_DB="$ORM_NL$(cat "$ORM_STATE/steer.db" 2>/dev/null)"
}

# pol_v MAC KEY [DEFAULT] -> sets POL_V (no subshell)
pol_v() {
	local _pv
	pol_db_load
	case "$POL_DB" in
	*"$ORM_NL$1.$2="*)
		_pv=${POL_DB##*"$ORM_NL$1.$2="}
		POL_V=${_pv%%"$ORM_NL"*}
		;;
	*) POL_V=${3:-} ;;
	esac
}

pol_get() {
	# pol_get MAC KEY [DEFAULT]
	pol_v "$@"
	printf '%s' "$POL_V"
}

pol_set() {
	# pol_set MAC KEY VALUE (in memory; persisted by pol_db_save)
	pol_db_load
	POL_DB="$POL_DB$ORM_NL$1.$2=$3"
}

# Effective parameter: roamctl.steering.<key> (written by the optimizer)
# pol_cfg_v KEY DEFAULT -> sets POL_C
pol_cfg_v() {
	uci_cached_v roamctl steering "$1"
	POL_C=${UCI_V:-$2}
}

pol_cfg() {
	pol_cfg_v "$1" "$2"
	printf '%s' "$POL_C"
}

pol_band_cfg() {
	# pol_band_cfg KEY BAND DEFAULT -> e.g. rssi_min_5g
	pol_cfg "${1}_$2" "$3"
}

# Keep only timestamps inside the ping-pong window -> sets POL_TR
pol_trim_window_v() {
	local _ts
	pol_cfg_v pingpong_window 600
	POL_TR=''
	for _ts in $1; do
		[ $(($2 - _ts)) -le "$POL_C" ] && POL_TR="$POL_TR $_ts"
	done
	POL_TR=${POL_TR# }
}

pol_trim_window() {
	pol_trim_window_v "$1" "$2"
	printf '%s' "$POL_TR"
}

# Record that a client was seen on BSS at time T; counts BSS changes.
pol_observe() {
	local _last
	# pol_observe MAC BSSID BAND T
	pol_v "$1" bss
	_last=$POL_V
	if [ -n "$_last" ] && [ "$_last" != "$2" ]; then
		pol_v "$1" transitions
		pol_trim_window_v "$POL_V $4" "$4"
		pol_set "$1" transitions "$POL_TR"
		pol_set "$1" low_count 0
		pol_set "$1" attempts 0
	fi
	[ "$_last" = "$2" ] || pol_set "$1" bss "$2"
	pol_set "$1" seen "$4"
	case "$3" in
	5g | 6g)
		pol_v "$1" dualband 0
		[ "$POL_V" = 1 ] || pol_set "$1" dualband 1
		;;
	esac
}

# ------------------------------------------------------------ decide
# pol_decide_r MAC BAND RSSI BTM(0/1) CONNECTED_SECS CLIENTS_ON_BSS NOW CANDIDATES
# CANDIDATES: newline separated "bssid band load signal local" where
# signal is the client's signal at that BSS if known, otherwise "-".
# Result in POL_RESULT: "none <reason>" or "steer <reason> <bssid>..."
# (pol_decide prints the same result; use _r in loops to keep the state)
pol_decide_r() {
	local _mac _band _rssi _btm _conn _load _now _cands _min _pref _hy _samples _cool _retry _ppmax _low _att _list
	_mac=$1 _band=$2 _rssi=$3 _btm=$4 _conn=$5 _load=$6 _now=$7 _cands=$8

	pol_cfg_v exclude_client ''
	if list_contains "$POL_C" "$_mac"; then
		POL_RESULT="none excluded"
		return 0
	fi
	pol_cfg_v include_client ''
	if [ -n "$POL_C" ] && ! list_contains "$POL_C" "$_mac"; then
		POL_RESULT="none not-included"
		return 0
	fi
	is_uint "${_rssi#-}" || {
		POL_RESULT="none no-signal"
		return 0
	}

	pol_cfg_v "rssi_min_$_band" -75
	_min=$POL_C
	pol_cfg_v "rssi_pref_$_band" -65
	_pref=$POL_C
	pol_cfg_v "hyst_$_band" 6
	_hy=$POL_C
	pol_cfg_v low_samples 3
	_samples=$POL_C
	pol_cfg_v cooldown 120
	_cool=$POL_C
	pol_cfg_v retry_limit 3
	_retry=$POL_C
	pol_cfg_v pingpong_max 3
	_ppmax=$POL_C

	# Episode bookkeeping (signal hysteresis)
	pol_v "$_mac" low_count 0
	_low=$POL_V
	if [ "$_rssi" -lt "$_min" ]; then
		_low=$((_low + 1))
		pol_set "$_mac" low_count "$_low"
	elif [ "$_rssi" -ge $((_min + _hy)) ]; then
		if [ "$_low" != 0 ]; then
			_low=0
			pol_set "$_mac" low_count 0
		fi
		pol_v "$_mac" attempts 0
		[ "$POL_V" = 0 ] || pol_set "$_mac" attempts 0
	fi

	if [ "$_btm" != 1 ]; then
		POL_RESULT="none no-btm-support"
		return 0
	fi
	pol_cfg_v min_assoc_time 30
	if [ "$_conn" -lt "$POL_C" ]; then
		POL_RESULT="none settling"
		return 0
	fi
	pol_v "$_mac" last_steer 0
	if [ $((_now - POL_V)) -lt "$_cool" ]; then
		POL_RESULT="none cooldown"
		return 0
	fi
	pol_v "$_mac" transitions
	pol_trim_window_v "$POL_V" "$_now"
	# shellcheck disable=SC2086
	set -- $POL_TR
	if [ "$#" -ge "$_ppmax" ]; then
		POL_RESULT="none ping-pong-protection"
		return 0
	fi
	pol_v "$_mac" attempts 0
	_att=$POL_V

	# 1) signal based AP/band steering
	if [ "$_low" -ge "$_samples" ]; then
		if [ "$_att" -ge "$_retry" ]; then
			POL_RESULT="none retry-limit"
			return 0
		fi
		_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" weak)
		if [ -n "$_list" ]; then
			POL_RESULT="steer low-signal $_list"
			return 0
		fi
		POL_RESULT="none no-better-candidate"
		return 0
	fi

	# 2) band steering: strong 2.4 GHz client, dual band capable
	if [ "$_band" = 2g ] && [ "$_att" -lt "$_retry" ]; then
		pol_cfg_v band_steering 1
		if [ "$POL_C" = 1 ]; then
			pol_cfg_v band_steer_rssi_2g -60
			pol_v "$_mac" dualband 0
			if [ "$_rssi" -ge "$POL_C" ] && [ "$POL_V" = 1 ]; then
				_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" band)
				if [ -n "$_list" ]; then
					POL_RESULT="steer band-steering $_list"
					return 0
				fi
			fi
		fi
	fi

	# 3) load balancing: busy BSS, marginal signal, clearly less loaded peer
	pol_cfg_v load_threshold 20
	if [ "$_load" -gt "$POL_C" ] && [ "$_rssi" -lt "$_pref" ] && [ "$_att" -lt "$_retry" ]; then
		_list=$(pol_rank_candidates "$_band" "$_rssi" "$_hy" "$_cands" load "$_load")
		if [ -n "$_list" ]; then
			POL_RESULT="steer load-balancing $_list"
			return 0
		fi
	fi
	POL_RESULT="none ok"
}

pol_decide() {
	pol_decide_r "$@"
	printf '%s\n' "$POL_RESULT"
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
	pol_v "$1" attempts 0
	pol_set "$1" attempts $((POL_V + 1))
	pol_v "$1" steer_total 0
	pol_set "$1" steer_total $((POL_V + 1))
}

# Old per-client state files of earlier versions; the DB itself is
# compacted and aged by pol_db_save.
pol_gc() {
	rm -rf "$ORM_STATE/steer" 2>/dev/null
	return 0
}
