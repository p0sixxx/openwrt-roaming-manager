# Unit tests: steering policy engine, optimizer, band steering, package manager

POL_SETUP='
roam_cfg_init
orm_uci set roamctl.steering=steering
for kv in rssi_min_2g=-78 rssi_min_5g=-75 rssi_pref_2g=-65 rssi_pref_5g=-67 hyst_2g=5 hyst_5g=6 \
	cooldown=120 retry_limit=2 pingpong_window=600 pingpong_max=3 min_assoc_time=30 low_samples=3 \
	band_steer_rssi_2g=-60 band_target_min_5g=-70 band_steering=1 load_threshold=20 load_diff=5; do
	orm_uci set roamctl.steering.$kv
done
orm_uci commit roamctl
M=02:aa:bb:cc:dd:01
C="02:00:00:00:00:02 5g 3 - 0
02:00:00:00:00:03 2g 1 - 1"
'

test_policy_never_steers_non_btm_clients() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	for i in 1 2 3 4 5; do pol_decide $M 5g -88 0 600 1 1000 "$C"; done | sort -u'
	assert_eq "none no-btm-support" "$OUT"
}

test_policy_time_hysteresis_and_settling() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	pol_decide $M 5g -85 1 10 1 1000 "$C"
	rm -rf "$ORM_STATE/steer"
	pol_decide $M 5g -85 1 600 1 1000 "$C"
	pol_decide $M 5g -85 1 600 1 1001 "$C"
	pol_decide $M 5g -85 1 600 1 1002 "$C"'
	assert_eq 'none settling
none ok
none ok
steer low-signal 02:00:00:00:00:02 02:00:00:00:00:03' "$OUT" "3 consecutive low samples before steering; 5 GHz candidate ranked first"
}

test_policy_cooldown_retry_and_rearm() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	for t in 1000 1001 1002; do pol_decide $M 5g -85 1 600 1 $t "$C" >/dev/null; done
	pol_record_steer $M 1002
	pol_decide $M 5g -85 1 600 1 1050 "$C"
	pol_decide $M 5g -85 1 600 1 1200 "$C" | cut -d" " -f1-2
	pol_record_steer $M 1200
	pol_decide $M 5g -85 1 600 1 1400 "$C"
	pol_decide $M 5g -60 1 600 1 1401 "$C"
	for t in 1402 1403 1404; do pol_decide $M 5g -85 1 600 1 $t "$C"; done | tail -n1 | cut -d" " -f1-2'
	assert_eq 'none cooldown
steer low-signal
none retry-limit
none ok
steer low-signal' "$OUT" "cooldown, retry limit and re-arm after recovery above min+hysteresis"
}

test_policy_ping_pong_protection() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	pol_observe $M 02:00:00:00:00:01 5g 1000
	pol_observe $M 02:00:00:00:00:02 5g 1010
	pol_observe $M 02:00:00:00:00:01 5g 1020
	pol_observe $M 02:00:00:00:00:02 5g 1030
	for t in 1031 1032 1033; do pol_decide $M 5g -85 1 600 1 $t "$C"; done | tail -n1
	for t in 1700 1701 1702; do pol_decide $M 5g -85 1 600 1 $t "$C"; done | tail -n1 | cut -d" " -f1'
	assert_eq 'none ping-pong-protection
steer' "$OUT" "frozen while transitions inside the window exceed the limit"
}

test_policy_exclusion_inclusion() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	orm_uci add_list roamctl.steering.exclude_client=$M; orm_uci commit roamctl
	pol_decide $M 5g -85 1 600 1 1000 "$C"
	orm_uci delete roamctl.steering.exclude_client
	orm_uci add_list roamctl.steering.include_client=02:ff:ff:ff:ff:ff; orm_uci commit roamctl
	pol_decide $M 5g -85 1 600 1 1000 "$C"'
	assert_eq 'none excluded
none not-included' "$OUT"
}

test_policy_never_offers_worse_candidate() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	W="02:00:00:00:00:02 5g 0 -88 0
02:00:00:00:00:03 5g 0 -82 0
02:00:00:00:00:04 5g 0 -70 0"
	for t in 2001 2002 2003; do pol_decide $M 5g -84 1 600 1 $t "$W"; done | tail -n1'
	assert_eq "steer low-signal 02:00:00:00:00:04" "$OUT" "only candidates better than current+hysteresis"
}

test_policy_band_steering() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	B="02:00:00:00:00:05 5g 2 - 1"
	pol_decide $M 2g -50 1 600 1 1000 "$B"
	pol_set $M dualband 1
	pol_decide $M 2g -50 1 600 1 1001 "$B"
	pol_decide 02:aa:bb:cc:dd:02 2g -70 1 600 1 1001 "$B"'
	assert_eq 'none ok
steer band-steering 02:00:00:00:00:05
none ok' "$OUT" "only strong, dual-band capable 2.4 GHz clients"
}

test_policy_load_balancing() {
	fx_new filogic-2410
	mod_run "$POL_SETUP"'
	L="02:00:00:00:00:06 5g 30 - 0
02:00:00:00:00:07 5g 4 - 0"
	pol_decide $M 5g -70 1 600 30 1000 "$L"
	pol_decide 02:aa:bb:cc:dd:03 5g -50 1 600 30 1000 "$L"'
	assert_eq 'steer load-balancing 02:00:00:00:00:07
none ok' "$OUT"
}

test_optimizer_per_band_thresholds() {
	fx_new filogic-mt7988-6g
	mod_run 'detect_everything; opt_compute balanced 2; for b in 2g 5g 6g; do caps_get opt.rssi_min_$b; echo; done
	opt_compute balanced 1; caps_get opt.rssi_min_5g; echo
	opt_compute balanced 4; caps_get opt.rssi_min_5g; echo
	opt_compute aggressive 2; caps_get opt.rssi_min_5g; echo; caps_get opt.kick_mode; echo
	opt_compute conservative 2; caps_get opt.cooldown'
	assert_eq '-78
-75
-72
-79
-73
-71
disassoc-imminent
300' "$OUT" "different per band; adjusted by AP density and profile"
}

test_optimizer_noise_raises_thresholds() {
	FXO_SC_NOISE=-84 fx_new filogic-2410
	mod_run 'detect_everything; opt_compute balanced 2; caps_get opt.noise_5g; echo; caps_get opt.rssi_min_5g'
	assert_eq '-84
-67' "$OUT" "8 dB noisier than expected -> thresholds +8 dB"
}

test_pkgmgr_detection_opkg_apk() {
	fx_new filogic-2410
	mod_run 'sysdet_pkgmgr; caps_get pkg.manager'
	assert_eq opkg "$OUT"
	fx_cleanup
	fx_new filogic-25
	mod_run 'caps_reset; sysdet_pkgmgr; caps_get pkg.manager; echo; pkg_installed_list | grep -x wpad-basic-mbedtls'
	assert_eq 'apk
wpad-basic-mbedtls' "$OUT"
}

test_pkg_install_idempotent_and_reasons() {
	fx_new filogic-2410
	mod_run 'detect_everything
	pkg_install usteer test 2>/dev/null && echo installed
	pkg_install usteer test 2>/dev/null && echo again
	pkg_install does-not-exist test 2>/dev/null || caps_get pkg.fail.does-not-exist; echo
	pkg_install wpad-mbedtls test 2>/dev/null || caps_get pkg.fail.wpad-mbedtls'
	assert_eq 'installed
again
package not available in configured feeds
would replace the active Wi-Fi backend wpad-basic-mbedtls (use '"'roamctl backend replace'"')' "$OUT"
	assert_eq 1 "$(grep -c 'opkg install usteer' "$MOCK_LOG")" "second install must be skipped"
}

test_pkg_no_internet_reason() {
	FXO_SC_INTERNET=0 fx_new filogic-2410
	mod_run 'detect_everything; pkg_install usteer x 2>/dev/null || caps_get pkg.fail.usteer'
	assert_eq "no internet connectivity" "$OUT"
}
