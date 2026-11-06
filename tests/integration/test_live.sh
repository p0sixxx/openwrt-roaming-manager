# Integration tests: live roaming test and client capability survey

LIVE_MAC=02:c1:1e:00:00:42

live_log_assoc() {
	# hostapd-like log lines for the client on its new BSS
	printf 'Thu Nov  6 10:00:00 2026 daemon.info hostapd: %s: STA %s IEEE 802.11: associated (aid 1)\n' "$1" "$LIVE_MAC" >>"$2/log/messages"
}

test_live_roaming_not_tested_without_client() {
	fx_new filogic-2410
	rc_run -y setup
	assert_contains "$ERR" "Live Roaming:  NOT TESTED"
	rc_run test live
	assert_eq 1 "$RC"
	assert_contains "$ERR" "Usage: roamctl test live --client"
	rc_run diag
	assert_contains "$ERR" "no test client given"
	assert_contains "$ERR" "CONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED"
}

test_live_client_not_associated() {
	fx_new filogic-2410
	rc_run -y setup
	rc_run test live --client "$LIVE_MAC" --duration 2
	assert_contains "$ERR" "was not associated to any managed BSS"
	assert_contains "$ERR" "LIVE ROAMING NOT TESTED"
}

test_live_client_stays_on_one_bss() {
	fx_new filogic-2410
	rc_run -y setup
	t=$(date +%s)
	echo "$((t - 5)) $((t + 60)) phy1-ap0 $LIVE_MAC -55" >"$MOCK_DIR/roam_plan"
	rc_run test live --client "$LIVE_MAC" --duration 3
	assert_contains "$ERR" "no transition observed"
	assert_not_contains "$ERR" "PASS            live roaming"
}

test_live_roaming_band_transition_single_ap() {
	fx_new filogic-2410
	rc_run -y setup
	t=$(date +%s)
	printf '%s %s phy0-ap0 %s -71\n%s %s phy1-ap0 %s -58\n' "$((t - 5))" "$((t + 6))" "$LIVE_MAC" "$((t + 6))" "$((t + 60))" "$LIVE_MAC" >"$MOCK_DIR/roam_plan"
	live_log_assoc phy1-ap0 "$MOCK_DIR"
	echo 192.168.1.50 >>"$MOCK_DIR/net/hosts"
	rc_run test live --client "$LIVE_MAC" --duration 10 --ip 192.168.1.50
	assert_contains "$ERR" "02:11:22:33:00:00 -> 02:11:22:33:01:00, signal -71 -> -58 dBm"
	assert_contains "$ERR" "FT used: reassociation without 4-way handshake"
	assert_contains "$ERR" "packet loss 0%"
	assert_contains "$ERR" "PASS            live roaming"
	assert_not_contains "$ERR" "LIVE ROAMING NOT TESTED"
}

test_live_roaming_full_handshake_warns() {
	fx_new filogic-2410
	rc_run -y setup
	t=$(date +%s)
	printf '%s %s phy0-ap0 %s -71\n%s %s phy1-ap0 %s -58\n' "$((t - 5))" "$((t + 6))" "$LIVE_MAC" "$((t + 6))" "$((t + 60))" "$LIVE_MAC" >"$MOCK_DIR/roam_plan"
	live_log_assoc phy1-ap0 "$MOCK_DIR"
	printf 'Thu Nov  6 10:00:01 2026 daemon.info hostapd: phy1-ap0: STA %s WPA: pairwise key handshake completed (RSN)\n' "$LIVE_MAC" >>"$MOCK_DIR/log/messages"
	rc_run test live --client "$LIVE_MAC" --duration 10
	assert_contains "$ERR" "WARN            FT status"
	assert_contains "$ERR" "FT not used by client"
	assert_contains "$ERR" "client IP unknown"
}

test_live_roaming_between_two_aps() {
	fx_new filogic-2410
	rc_run -y setup
	(export FXO_SC_BASEMAC=02:22:00:00; fx_new filogic-2410 ap2)
	rc_run multiap add ap2 ap2
	rc_run -y multiap sync
	assert_rc 0 "$RC"
	t=$(date +%s)
	echo "$((t - 5)) $((t + 7)) phy1-ap0 $LIVE_MAC -74" >"$MOCK_DIR/roam_plan"
	echo "$((t + 7)) $((t + 60)) phy1-ap0 $LIVE_MAC -52" >"$FX_BASE/hosts/ap2/mock/roam_plan"
	live_log_assoc phy1-ap0 "$FX_BASE/hosts/ap2/mock"
	rc_run test live --client "$LIVE_MAC" --duration 12
	assert_contains "$ERR" "02:11:22:33:01:00 -> 02:22:00:00:01:00"
	assert_contains "$ERR" "FT used: reassociation without 4-way handshake"
	assert_contains "$ERR" "PASS            live roaming"
}

test_client_capability_survey() {
	fx_new filogic-2410
	rc_run -y setup
	printf '{"freq": 5180, "clients": {"02:aa:00:00:00:01": {"signal": -50, "extended_capabilities": [4,0,8,0], "rrm": [115,0,0,0,0]}, "02:aa:00:00:00:02": {"signal": -60, "extended_capabilities": [4,0,0,0], "rrm": [0,0,0,0,0]}}}\n' >"$MOCK_DIR/clients/phy1-ap0.json"
	rc_run diag
	assert_contains "$ERR" "2 client(s): 1 support 802.11v BTM, 1 support 802.11k neighbor reports"
	assert_contains "$ERR" "per-client signal available"
}
