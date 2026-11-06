# shellcheck shell=sh
# Diagnostics: steering backend

diag_steering() {
	local _be _note _aps _nr _sig _g _s _if _j _t _c _selftest_mac _old_state _d1 _d2
	_be=$(roam_get global.steering_backend_active none)
	if [ "$_be" = none ]; then
		report_add steering backend "NOT TESTED" "steering disabled"
		return 0
	fi
	if [ -n "$(caps_get steer.conflict)" ]; then
		report_add steering exclusivity FAIL "competing steering daemons running: $(caps_get steer.conflict)"
	fi
	steer_call "$_be" test
	_note=$(caps_get "steer.$_be.note")
	[ -n "$_note" ] && report_add steering "$_be note" WARN "$_note"
	# Neighbor discovery visible to the backend / static lists
	_aps=$(roam_ap_count)
	_nr=$(awk -F "$ORM_FS" '$2 != "local"' "$(nr_db)" 2>/dev/null | wc -l | tr -d ' ')
	if [ "$_aps" -gt 1 ]; then
		if [ "$_nr" -gt 0 ]; then
			report_add steering "neighbor APs" PASS "$_nr BSS of other APs known"
		else
			report_add steering "neighbor APs" WARN "no BSS of other APs known (run 'roamctl multiap sync')"
		fi
	fi
	# signal information available?
	_sig=0
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			[ -n "$_if" ] || continue
			_j=$(ubus call "hostapd.$_if" get_clients 2>/dev/null)
			json_glob "$_j" 'clients.*.signal' | grep -q . && _sig=1
		done
	done
	if [ "$_sig" = 1 ]; then
		report_add steering "RSSI data" PASS "per-client signal available from hostapd"
	else
		report_add steering "RSSI data" "NOT TESTED" "no associated clients to read signal from"
	fi
	# Policy self-test: the decision engine must refuse unsafe actions
	_t=$(now)
	_c="02:00:00:00:00:01 5g 0 - 1"
	_selftest_mac="02:00:5e:00:00:99"
	_old_state=$ORM_STATE
	ORM_STATE="$ORM_STATE/selftest"
	rm -rf "$ORM_STATE/steer"
	_d1=$(pol_decide "$_selftest_mac" 2g -85 0 600 1 "$_t" "$_c")
	_d2=$(pol_decide "$_selftest_mac" 5g -40 1 600 1 "$_t" "$_c")
	rm -rf "$ORM_STATE"
	ORM_STATE=$_old_state
	if [ "${_d1%% *}" = none ] && [ "${_d2%% *}" = none ]; then
		report_add steering "policy engine" PASS "no steering of non-BTM clients or clients with good signal"
	else
		report_add steering "policy engine" FAIL "unexpected decisions: '$_d1' / '$_d2'"
	fi
}
