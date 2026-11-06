# shellcheck shell=sh
# Diagnostics: client capability survey and live roaming test
#
# The live test only reports PASS after it has actually observed a test
# client moving from one BSSID to another. Without a client (or without
# a transition during the test window) the result is NOT TESTED.

# Survey of associated clients: 802.11k/v support as advertised by them
diag_clients() {
	local _tot _btm _nr _g _s _if _f _m _e2 _r0
	_tot=0 _btm=0 _nr=0
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			[ -n "$_if" ] || continue
			_f=$(ubus call "hostapd.$_if" get_clients 2>/dev/null | json_flatten)
			for _m in $(printf '%s\n' "$_f" | awk -F. '/^clients\./ { print $2 }' | sort -u); do
				is_mac "$_m" || continue
				_tot=$((_tot + 1))
				_e2=$(printf '%s\n' "$_f" | sed -n "s/^clients\.$_m\.extended_capabilities\.2=//p")
				v_client_btm "$_e2" && _btm=$((_btm + 1))
				_r0=$(printf '%s\n' "$_f" | sed -n "s/^clients\.$_m\.rrm\.0=//p")
				is_uint "$_r0" && [ $((_r0 & 2)) -ne 0 ] && _nr=$((_nr + 1))
			done
		done
	done
	if [ "$_tot" -eq 0 ]; then
		report_add live "client survey" "NOT TESTED" "no clients associated to roaming SSIDs"
	else
		report_add live "client survey" PASS "$_tot client(s): $_btm support 802.11v BTM, $_nr support 802.11k neighbor reports"
	fi
}

# Watch a client on the local BSSes: prints "epoch bssid signal ifname"
live_watch_local() {
	local _mac _end _t _s _if _j _ina _sig
	# live_watch_local MAC SECONDS
	_mac=$(lower "$1")
	_end=$(($(now) + $2))
	while [ "$(now)" -lt "$_end" ]; do
		_t=$(now)
		for _s in $(caps_get iface.list); do
			[ "$(caps_get "iface.$_s.hostapd")" = 1 ] || continue
			_if=$(caps_get "iface.$_s.ifname")
			_j=$(ubus call "hostapd.$_if" get_clients 2>/dev/null) || continue
			case "$_j" in *"\"$_mac\""*) ;; *) continue ;; esac
			# a roamed-away client lingers in the old AP's station table until
			# inactivity timeout: only count stations with recent activity
			if have_cmd iw; then
				_ina=$(iw dev "$_if" station get "$_mac" 2>/dev/null | sed -n 's/.*inactive time:[[:blank:]]*\([0-9]*\) ms.*/\1/p')
				[ -n "$_ina" ] && [ "$_ina" -gt "${ORM_LIVE_INACTIVE_MS:-3000}" ] && continue
			fi
			_sig=$(json_get "$_j" "clients.$_mac.signal")
			printf '%s %s %s %s\n' "$_t" "$(caps_get "iface.$_s.bssid")" "${_sig:--}" "$_if"
		done
		sleep "${ORM_LIVE_STEP:-1}"
	done
	if have_cmd logread; then
		logread 2>/dev/null | grep -i "$_mac" | tail -n 60 | sed 's/^/log /'
	fi
}

# Client IP from DHCP leases or the neighbour table
live_client_ip() {
	local _m _ip
	_m=$(lower "$1")
	_ip=$(awk -v m="$_m" 'tolower($2) == m { print $3; exit }' "$(orm_path /tmp/dhcp.leases)" 2>/dev/null)
	[ -n "$_ip" ] || _ip=$(ip -4 neigh show 2>/dev/null | awk -v m="$_m" 'tolower($5) == m { print $1; exit }')
	printf '%s' "$_ip"
}

# Analyse merged samples -> transitions; prints result lines
# "transition <t_old_last> <t_new_first> <from> <to> <sig_before> <sig_after>"
live_analyse() {
	sort -n -k1,1 "$1" | awk '
		$1 ~ /^[0-9]+$/ {
			t = $1; b = $2; s = $3
			if (cur != "" && b != cur)
				printf "transition %s %s %s %s %s %s\n", last_t, t, cur, b, last_s, s
			cur = b; last_t = t; last_s = s
		}'
}

# FT inference from hostapd log lines of the target AP around time T
live_ft_status() {
	# live_ft_status LOGFILE MAC
	if ! [ -s "$1" ]; then
		printf 'unknown (no log)'
		return
	fi
	if grep -qi "$2.*FT" "$1" || grep -qi 'authentication OK (FT)' "$1"; then
		printf 'FT authentication logged'
	elif grep -qi "$2.*pairwise key handshake completed" "$1"; then
		printf 'full 4-way handshake observed (FT not used by client)'
	else
		printf 'no full handshake logged (FT likely)'
	fi
}

# Live roaming test: roamctl test live --client MAC [--duration N] [--ip IP] [--steer]
diag_live() {
	local _mac _dur _w _ip _pids _ap _pint _cnt _seen _ntr _loss _outage _worst _x _t1 _t2 _from _to _s1 _s2 _gap _ft
	_mac=$(lower "${ORM_LIVE_CLIENT:-}")
	_dur=${ORM_LIVE_DURATION:-60}
	if [ -z "$_mac" ]; then
		report_add live "live roaming" "NOT TESTED" "no test client given (roamctl test live --client <mac>)"
		return 0
	fi
	is_mac "$_mac" || { log_error "Invalid client MAC"; return 1; }
	is_uint "$_dur" || _dur=60
	if [ "$(roam_ap_count)" -lt 2 ] && [ "$(caps_get radio.count 0)" -lt 2 ]; then
		report_add live "live roaming" "NOT TESTED" "needs at least two BSS of the roaming SSID"
		return 0
	fi
	_w="$ORM_STATE/live"
	rm -rf "$_w"
	ensure_dir "$_w"
	_ip=${ORM_LIVE_IP:-$(live_client_ip "$_mac")}
	log_step "Live roaming test: client $_mac${_ip:+ ($_ip)} for ${_dur}s - move the client between APs now"

	live_watch_local "$_mac" "$_dur" >"$_w/local" 2>/dev/null &
	_pids=$!
	for _ap in $(roam_aps_enabled); do
		ssh_agent "$_ap" watch "$_mac" "$_dur" </dev/null >"$_w/$_ap" 2>/dev/null &
		_pids="$_pids $!"
	done
	_pint=1
	if [ -n "$_ip" ]; then
		ping -c 1 -i 0.2 -W 1 127.0.0.1 >/dev/null 2>&1 && _pint=0.2
		_cnt=$(awk -v d="$_dur" -v i="$_pint" 'BEGIN { printf "%d", d / i }')
		ping -c "$_cnt" -i "$_pint" -W 1 "$_ip" >"$_w/ping" 2>&1 &
		_pids="$_pids $!"
	fi
	if [ "${ORM_LIVE_STEER:-0}" = 1 ]; then
		sleep 5
		live_trigger_steer "$_mac"
	fi
	# shellcheck disable=SC2086
	wait $_pids 2>/dev/null

	{
		cat "$_w/local"
		for _ap in $(roam_aps_enabled); do cat "$_w/$_ap"; done
	} 2>/dev/null | grep -E '^[0-9]+ ' >"$_w/samples"
	grep -h '^log ' "$_w"/* 2>/dev/null >"$_w/log"
	_seen=$(awk '{print $2}' "$_w/samples" | sort -u | grep -c .)
	if [ "$_seen" -eq 0 ]; then
		report_add live "live roaming" "NOT TESTED" "client $_mac was not associated to any managed BSS"
		return 0
	fi
	live_analyse "$_w/samples" >"$_w/transitions"
	_ntr=$(grep -c . "$_w/transitions")

	_loss='' _outage=''
	if [ -s "$_w/ping" ]; then
		_loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' "$_w/ping")
		_outage=$(awk -v i="$_pint" '
			/seq=/ { s = $0; sub(/.*seq=/, "", s); sub(/[^0-9].*/, "", s); s += 0
				if (have) { gap = s - prev - 1; if (gap > maxgap) maxgap = gap }
				prev = s; have = 1 }
			END { printf "%d", (maxgap + 1) * i * 1000 }' "$_w/ping")
	fi

	if [ "$_ntr" -eq 0 ]; then
		report_add live "live roaming" "NOT TESTED" "client stayed on $(head -n1 "$_w/samples" | cut -d' ' -f2) - no transition observed in ${_dur}s"
		return 0
	fi
	_worst=0
	while read -r _x _t1 _t2 _from _to _s1 _s2; do
		_gap=$((_t2 - _t1))
		[ "$_gap" -gt "$_worst" ] && _worst=$_gap
		report_add live "transition" PASS "$_from -> $_to, signal ${_s1} -> ${_s2} dBm, association gap <= ${_gap}s (1s sampling)"
	done <"$_w/transitions"
	_ft=$(live_ft_status "$_w/log" "$_mac")
	report_add live "FT status" "$(case "$_ft" in *'not used'*) echo WARN ;; unknown*) echo "NOT TESTED" ;; *) echo PASS ;; esac)" "$_ft"
	if [ -n "$_outage" ]; then
		if [ "$_outage" -le 1000 ]; then
			report_add live "data path" PASS "packet loss ${_loss:-?}%, longest interruption ~${_outage} ms (ping every ${_pint}s)"
		else
			report_add live "data path" WARN "packet loss ${_loss:-?}%, longest interruption ~${_outage} ms (ping every ${_pint}s)"
		fi
	else
		report_add live "data path" "NOT TESTED" "client IP unknown - packet loss not measured (use --ip)"
	fi
	if [ "$_worst" -gt 5 ]; then
		report_add live "live roaming" WARN "$_ntr transition(s); a gap of ${_worst}s indicates a full reconnect"
	else
		report_add live "live roaming" PASS "$_ntr transition(s) observed"
	fi
}

# Ask the client (via BTM) to move to another BSS of its group (local AP only)
live_trigger_steer() {
	local _mac _g _s _if _j _own _hexes
	_mac=$1
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			_j=$(ubus call "hostapd.$_if" get_clients 2>/dev/null) || continue
			case "$_j" in *"\"$_mac\""*) ;; *) continue ;; esac
			_own=$(caps_get "iface.$_s.bssid")
			_hexes=$(awk -F "$ORM_FS" -v g="$_g" -v b="$_own" '$1 == g && $4 != b { print $6 }' "$(nr_db)" 2>/dev/null | tr '\n' ' ')
			if [ -z "$_hexes" ]; then
				log_warn "No neighbor to steer to"
				return 1
			fi
			# shellcheck disable=SC2086
			if v_btm_request "$_if" "$_mac" 0 100 $_hexes; then
				log_info "BTM request sent to $_mac on $_if"
			else
				log_warn "BTM request to $_mac failed"
			fi
			return 0
		done
	done
	log_warn "Client $_mac is not on this AP; move it physically or run the test on its current AP"
	return 1
}
