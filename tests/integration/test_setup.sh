# Integration tests: automatic configuration on single access points

test_setup_filogic_2410() {
	fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC" "setup exit code"
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	assert_match "$md" '^[0-9a-f]{4}$' "MDID stored"
	for s in default_radio0 default_radio1; do
		assert_eq 1 "$(fx_uci get wireless.$s.ieee80211r)" "$s 11r"
		assert_eq "$md" "$(fx_uci get wireless.$s.mobility_domain)" "$s MDID"
		assert_eq 1 "$(fx_uci get wireless.$s.ft_psk_generate_local)" "$s FT-PSK local"
		assert_eq 0 "$(fx_uci get wireless.$s.ft_over_ds)" "$s FT over the air"
		assert_eq 1 "$(fx_uci get wireless.$s.ieee80211k)" "$s 11k"
		assert_eq 1 "$(fx_uci get wireless.$s.bss_transition)" "$s 11v"
	done
	# running hostapd configuration (what actually matters)
	conf=$(cat "$ORM_SYSROOT"/var/run/hostapd-phy0.conf)
	assert_contains "$conf" "wpa_key_mgmt=WPA-PSK FT-PSK"
	assert_contains "$conf" "mobility_domain=$md"
	assert_contains "$conf" "rrm_neighbor_report=1"
	assert_contains "$conf" "bss_transition=1"
	assert_contains "$ERR" "802.11k:       PASS"
	assert_contains "$ERR" "802.11v:       PASS"
	assert_contains "$ERR" "802.11r:       PASS"
	assert_contains "$ERR" "Backend:       usteer"
	assert_contains "$ERR" "Live Roaming:  NOT TESTED"
	assert_contains "$ERR" "CONFIGURATION VERIFIED — LIVE ROAMING NOT TESTED"
	assert_contains "$ERR" "Backup:        CREATED"
	[ -n "$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.tar.gz 2>/dev/null)" ] || fail "backup archive missing"
	assert_eq 1 "$(fx_uci get usteer.@usteer[0].aggressiveness)" "usteer BTM-only aggressiveness"
	assert_eq HomeNet "$(fx_uci get usteer.@usteer[0].ssid_list)" "usteer limited to roaming SSID"
	assert_eq 1 "$(fx_uci get usteer.@usteer[0].local_mode)" "standalone usteer"
	assert_eq 0 "$(fx_uci get usteer.@usteer[0].min_snr)" "no low-signal kicks"
}

test_setup_does_not_touch_guest_iot() {
	fx_new filogic-2410
	before=$(fx_uci show wireless.guest_radio1; fx_uci show wireless.iot_radio0)
	rc_run -y setup
	after=$(fx_uci show wireless.guest_radio1; fx_uci show wireless.iot_radio0)
	assert_eq "$before" "$after" "guest and IoT interfaces unchanged"
	assert_contains "$ERR" "skipped: guest/IoT/isolated network"
	# SSID, key, channel and txpower never changed
	assert_eq HomeNet "$(fx_uci get wireless.default_radio0.ssid)"
	assert_eq correct-horse-battery "$(fx_uci get wireless.default_radio0.key)"
	assert_eq 1 "$(fx_uci get wireless.radio0.channel)"
	assert_eq HE80 "$(fx_uci get wireless.radio1.htmode)"
}

test_setup_include_guest_explicitly() {
	fx_new filogic-2410
	rc_run -y --include guest_radio1 setup
	assert_rc 0 "$RC"
	assert_eq 1 "$(fx_uci get wireless.guest_radio1.ieee80211r)" "explicitly included guest managed"
	gmd=$(fx_uci get wireless.guest_radio1.mobility_domain)
	hmd=$(fx_uci get wireless.default_radio0.mobility_domain)
	assert_ne "$gmd" "$hmd" "independent roaming groups get different MDIDs"
}

test_setup_filogic_25_apk() {
	fx_new filogic-25
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Packages:  apk"
	assert_contains "$(cat "$MOCK_LOG")" "apk add usteer"
	assert_not_contains "$(cat "$MOCK_LOG")" "opkg"
	assert_contains "$ERR" "802.11r:       PASS"
}

test_setup_qualcomm_full_wpad() {
	fx_new qualcomm-ipq807x
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Qualcomm IPQ (ath11k/ath12k)"
	assert_contains "$ERR" "driver=ath11k (softmac)"
	assert_contains "$ERR" "802.11r:       PASS"
}

test_setup_broadcom_fullmac_not_supported() {
	fx_new broadcom-rpi4
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	rc_run -y setup
	assert_ne 0 "$RC" "nothing can be configured"
	assert_contains "$ERR" "none of 802.11k/v/r is supported"
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")" "wireless untouched"
	rc_run audit
	assert_contains "$ERR" "NOT SUPPORTED   802.11r support"
	assert_contains "$ERR" "fullmac"
}

test_setup_wpa3_6ghz_shared_ft_key() {
	fx_new filogic-mt7988-6g
	rc_run -y setup
	assert_rc 0 "$RC"
	g=$(fx_uci show roamctl | sed -n 's/^roamctl\.\(g_[0-9a-f]*\)=group$/\1/p')
	assert_eq shared "$(fx_uci get roamctl.$g.ft_key_mode)" "SAE needs R0KH/R1KH"
	key=$(cat "$ORM_SYSROOT/etc/roamctl/keys/$g.ftkey")
	assert_match "$key" '^[0-9a-f]{64}$'
	assert_eq 600 "$(stat -c %a "$ORM_SYSROOT/etc/roamctl/keys/$g.ftkey")"
	for s in default_radio0 default_radio1 default_radio2; do
		assert_eq "ff:ff:ff:ff:ff:ff,*,$key" "$(fx_uci get wireless.$s.r0kh)" "$s r0kh"
		assert_eq "00:00:00:00:00:00,00:00:00:00:00:00,$key" "$(fx_uci get wireless.$s.r1kh)" "$s r1kh"
		assert_eq 0 "$(fx_uci get wireless.$s.ft_psk_generate_local)" "$s"
	done
	assert_contains "$(cat "$ORM_SYSROOT"/var/run/hostapd-phy2.conf)" "WPA-PSK SAE FT-PSK FT-SAE"
	assert_contains "$ERR" "[+] FT-SAE"
	assert_not_contains "$OUT$ERR" "$key" "FT key must never be printed"
	rc_run diag
	assert_contains "$ERR" "R0KH/R1KH key consistent"
	assert_not_contains "$OUT$ERR$(cat "$ORM_SYSROOT/tmp/roamctl.log")" "$key" "FT key must never be printed or logged"
}

test_setup_legacy_2203_handler() {
	fx_new legacy-2203
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_eq 1 "$(fx_uci get wireless.default_radio0.ieee80211v)" "legacy handler needs ieee80211v gate"
	assert_contains "$(cat "$ORM_SYSROOT"/var/run/hostapd-phy0.conf)" "bss_transition=1"
	assert_contains "$ERR" "best-effort"
}

test_no_80211k_support() {
	FXO_SC_RRM=0 fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211k)" "11k not enabled"
	assert_eq 1 "$(fx_uci get wireless.default_radio0.ieee80211r)"
	assert_contains "$ERR" "802.11k:       DISABLED"
}

test_no_80211v_support() {
	FXO_SC_WNM=0 fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.bss_transition)"
	assert_contains "$ERR" "802.11v:       DISABLED"
	assert_contains "$ERR" "802.11r:       ENABLED"
}

test_no_80211r_support() {
	FXO_SC_FEATURES="sae eap" fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)" "11r never enabled without support"
	assert_contains "$ERR" "802.11r:       DISABLED"
	assert_contains "$ERR" "802.11k:       PASS"
	rc_run detect
	assert_contains "$ERR" "built without IEEE 802.11r"
}

test_wpad_mini_nothing_supported() {
	FXO_SC_FEATURES="" FXO_SC_WPAD=wpad-mini fx_new filogic-2410
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	rc_run -y setup
	assert_ne 0 "$RC"
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")"
	rc_run audit
	assert_contains "$ERR" "wpad-mini lacks 802.11k/v"
}

test_package_install_failure_falls_back() {
	fx_new filogic-2410
	echo usteer >"$MOCK_DIR/pkg/install_fail"
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "using built-in native backend"
	assert_eq native "$(fx_uci get roamctl.global.steering_backend_active)"
	assert_eq 1 "$(fx_uci get roamctl.global.native_steering)"
	assert_eq 1 "$(fx_uci get wireless.default_radio0.ieee80211r)" "roaming configured anyway"
}

test_no_internet_falls_back_with_reason() {
	FXO_SC_INTERNET=0 fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC" "roaming does not need internet"
	assert_contains "$ERR" "no internet connectivity"
	assert_eq native "$(fx_uci get roamctl.global.steering_backend_active)"
	assert_contains "$ERR" "802.11r:       PASS"
}

test_no_steering_backend() {
	fx_new filogic-2410
	rc_run -y --backend none setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Steering:      DISABLED"
	assert_no_file "$ORM_SYSROOT/etc/init.d/usteer"
}

test_dawn_backend() {
	fx_new filogic-2410
	rc_run -y --backend dawn setup
	assert_rc 0 "$RC"
	assert_contains "$(cat "$MOCK_DIR/pkg/installed")" dawn
	assert_not_contains "$(cat "$MOCK_DIR/pkg/installed")" usteer "never both steering daemons"
	assert_eq 0 "$(fx_uci get dawn.global.kicking)" "no kicking in balanced profile"
	assert_eq -82 "$(fx_uci get dawn.802_11g.low_rssi_val)" "2.4 GHz threshold"
	assert_eq -79 "$(fx_uci get dawn.802_11a.low_rssi_val)" "5 GHz threshold"
	sk=$(fx_uci get dawn.@network[0].shared_key)
	assert_match "$sk" '^[0-9a-f]{32}$' "random DAWN shared key"
	assert_contains "$ERR" "Backend:       dawn"
}

test_backend_exclusivity() {
	FXO_SC_PKGS="base-files dnsmasq iw iwinfo dawn" fx_new filogic-2410
	[ -f "$MOCK_DIR/svc/dawn.running" ] || fail "fixture: dawn should run"
	rc_run -y --backend usteer setup
	assert_rc 0 "$RC"
	assert_no_file "$MOCK_DIR/svc/dawn.running"
	assert_no_file "$ORM_SYSROOT/etc/rc.d/S99dawn"
	assert_file "$MOCK_DIR/svc/usteer.running"
	assert_contains "$(cat "$MOCK_DIR/pkg/installed")" dawn "package kept (removal needs consent)"
}

test_native_backend_sends_btm() {
	fx_new filogic-2410
	rc_run -y --backend native setup
	assert_rc 0 "$RC"
	assert_eq 1 "$(fx_uci get roamctl.global.daemon)"
	# static neighbor lists installed by roamctl itself
	assert_contains "$(fx_actions)" "rrm_nr_set phy0-ap0"
	assert_contains "$(cat "$MOCK_DIR/ubus/hostapd.phy0-ap0/nr_list.state")" "02:11:22:33:01:00"
	printf '{"freq": 5180, "clients": {"02:aa:00:00:00:01": {"assoc": true, "signal": -88, "extended_capabilities": [4,0,8,0], "rrm": [115,0,0,0,0]}, "02:aa:00:00:00:02": {"assoc": true, "signal": -88, "extended_capabilities": [4,0,0,0]}}}\n' >"$MOCK_DIR/clients/phy1-ap0.json"
	mod_run 'detect_everything; native_tick; native_tick; native_tick; native_tick'
	act=$(fx_actions)
	assert_contains "$act" 'bss_transition_request phy1-ap0 {"addr":"02:aa:00:00:00:01","disassociation_imminent":false' "BTM recommendation for BTM client"
	assert_contains "$act" '"neighbors":["0211223300008f0900005101'"0e"'"]'
	assert_not_contains "$act" "02:aa:00:00:00:02" "legacy client never touched"
	assert_eq 1 "$(echo "$act" | grep -c bss_transition_request)" "cooldown prevents repeated requests"
}
