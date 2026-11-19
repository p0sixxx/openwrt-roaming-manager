# Integration test of the planned deployment:
#   main router  Routerich AX3000 v1 (MT7981B), OpenWrt 25.12, controller
#   second AP    Netis NX30 V2 (MT7981B), OpenWrt 25.12, wired, dumb AP
# Both start with the image default wpad-basic-mbedtls (no WNM/802.11v);
# roamctl replaces it by the full wpad-mbedtls on both.

dep_setup() {
	fx_new routerich-ax3000
	rc_run -y "$@" setup
	assert_rc 0 "$RC" "main router setup"
	(export FXO_SC_GATEWAY=192.168.1.1; fx_new netis-nx30v2 nx30)
	rc_run multiap add nx30 nx30
	rc_run -y "$@" multiap sync
	assert_rc 0 "$RC" "sync to NX30"
}

installed() {
	cat "$1/pkg/installed"
}

test_deploy_routerich_netis_wpa2() {
	dep_setup
	# wpad-basic-mbedtls removed, full wpad-mbedtls installed on both
	assert_contains "$(installed "$MOCK_DIR")" "wpad-mbedtls"
	assert_not_contains "$(installed "$MOCK_DIR")" "wpad-basic-mbedtls"
	assert_contains "$(installed "$FX_BASE/hosts/nx30/mock")" "wpad-mbedtls"
	assert_not_contains "$(installed "$FX_BASE/hosts/nx30/mock")" "wpad-basic-mbedtls"
	assert_contains "$ERR" "PASS            ap_nx30 wpad"
	assert_contains "$(cat "$MOCK_LOG")" "apk add usteer"
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	for s in default_radio0 default_radio1; do
		assert_eq "$md" "$(fx_uci get wireless.$s.mobility_domain)" "Routerich $s"
		assert_eq "$md" "$(fx_host_uci nx30 get wireless.$s.mobility_domain)" "NX30 $s"
		assert_eq 1 "$(fx_host_uci nx30 get wireless.$s.ft_psk_generate_local)"
		assert_eq 1 "$(fx_uci get wireless.$s.bss_transition)" "Routerich 11v after wpad replacement"
		assert_eq 1 "$(fx_host_uci nx30 get wireless.$s.bss_transition)" "NX30 11v after wpad replacement"
		assert_eq "" "$(fx_uci -q get wireless.$s.ieee80211v)" "no ieee80211v on 25.12"
	done
	assert_contains "$(cat "$ORM_SYSROOT"/var/run/hostapd-phy1.conf)" "bss_transition=1"
	assert_eq 0 "$(fx_host_uci nx30 get usteer.@usteer[0].local_mode)"
	assert_eq 1 "$(fx_host_uci nx30 get usteer.@usteer[0].aggressiveness)"
	assert_eq 4 "$(grep -c . "$ORM_SYSROOT/etc/roamctl/neighbors.db")" "2 APs x 2 bands"
	rc_run multiap check
	assert_rc 0 "$RC"
	rc_run detect
	assert_contains "$ERR" "Routerich AX3000 v1"
	assert_contains "$ERR" "driver=mt7986-wmac (softmac)"
	assert_contains "$ERR" "hostapd:   wpad-mbedtls"
	rc_run diag
	assert_contains "$ERR" "802.11r:       PASS"
	assert_contains "$ERR" "802.11k:       PASS"
	assert_contains "$ERR" "802.11v:       PASS"
	assert_contains "$ERR" "3 neighbor(s) installed" "usteer distributes the NX30 BSSes"
}

test_deploy_routerich_netis_wpa3_mixed() {
	FXO_SC_ENC=sae-mixed fx_new routerich-ax3000
	rc_run -y setup
	assert_rc 0 "$RC"
	(export FXO_SC_GATEWAY=192.168.1.1 FXO_SC_ENC=sae-mixed; fx_new netis-nx30v2 nx30)
	rc_run multiap add nx30 nx30
	rc_run -y multiap sync
	assert_rc 0 "$RC"
	g=g_5a776d62
	k=$(cat "$ORM_SYSROOT/etc/roamctl/keys/$g.ftkey")
	assert_eq "ff:ff:ff:ff:ff:ff,*,$k" "$(fx_host_uci nx30 get wireless.default_radio1.r0kh)" "same FT key on NX30"
	assert_eq 02a400000100 "$(fx_host_uci nx30 get wireless.default_radio1.nasid)" "unique R0KH-ID from BSSID"
	assert_eq 02a300000100 "$(fx_uci get wireless.default_radio1.nasid)"
}

test_deploy_keep_wpad_basic() {
	fx_new routerich-ax3000
	rc_run -y --keep-wpad setup
	assert_rc 0 "$RC"
	assert_contains "$(installed "$MOCK_DIR")" "wpad-basic-mbedtls"
	assert_contains "$ERR" "built without WNM"
	assert_contains "$ERR" "802.11v:       DISABLED"
	assert_contains "$ERR" "802.11r:       PASS"
	assert_contains "$ERR" "802.11k:       PASS"
}

test_deploy_forced_removal() {
	fx_new routerich-ax3000
	touch "$MOCK_DIR/pkg/del_needs_force"
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$(cat "$MOCK_LOG")" "apk del --force-broken-world wpad-basic-mbedtls"
	assert_not_contains "$(installed "$MOCK_DIR")" "wpad-basic-mbedtls"
	assert_contains "$ERR" "802.11v:       PASS"
}

test_deploy_failed_install_restores_basic() {
	fx_new routerich-ax3000
	echo wpad-mbedtls >"$MOCK_DIR/pkg/install_fail"
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	rc_run -y setup
	assert_ne 0 "$RC"
	assert_contains "$ERR" "reinstalling wpad-basic-mbedtls"
	assert_contains "$(installed "$MOCK_DIR")" "wpad-basic-mbedtls" "old backend back"
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")" "nothing else changed"
}
