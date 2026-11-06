# Integration tests: multi-AP management over (mock) SSH

# ma_host NAME SCENARIO [VAR=VALUE...] - build a member AP fixture
ma_host() {
	_n=$1 _sc=$2
	shift 2
	(
		for _kv in "$@"; do export "FXO_$_kv"; done
		fx_new "$_sc" "$_n"
	)
}

ma_setup_controller() {
	fx_new filogic-2410
	rc_run -y "$@" setup
	assert_rc 0 "$RC" "controller setup"
}

test_multiap_two_aps_sync() {
	ma_setup_controller
	ma_host ap2 filogic-25 SC_BASEMAC=02:22:00:00
	rc_run multiap add ap2 ap2
	assert_rc 0 "$RC"
	assert_contains "$ERR" "ap_ap2 reachable: OpenWrt 25.12.0"
	rc_run -y multiap sync
	assert_rc 0 "$RC" "sync exit code"
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	assert_eq "$md" "$(fx_host_uci ap2 get wireless.default_radio0.mobility_domain)" "same MDID on member"
	assert_eq "$md" "$(fx_host_uci ap2 get roamctl.g_5a776d62.mdid)"
	assert_eq member "$(fx_host_uci ap2 get roamctl.global.role)"
	assert_eq 2 "$(fx_host_uci ap2 get roamctl.global.ap_count)"
	assert_eq 0 "$(fx_uci get usteer.@usteer[0].local_mode)" "controller usteer leaves local mode"
	assert_eq 0 "$(fx_host_uci ap2 get usteer.@usteer[0].local_mode)" "member usteer exchanges with peers"
	db=$(cat "$ORM_SYSROOT/etc/roamctl/neighbors.db" | tr '\037' ' ')
	assert_contains "$db" "ap_ap2 phy0-ap0 02:22:00:00:00:00"
	assert_contains "$db" "local phy1-ap0 02:11:22:33:01:00"
	mdb=$(tr '\037' ' ' <"$FX_BASE/hosts/ap2/root/etc/roamctl/neighbors.db")
	assert_contains "$mdb" "controller phy1-ap0 02:11:22:33:01:00" "member knows controller BSSes"
	assert_contains "$mdb" "local phy0-ap0 02:22:00:00:00:00"
	assert_contains "$ERR" "PASS            ap_ap2"
	rc_run multiap check
	assert_rc 0 "$RC"
	assert_contains "$ERR" "MDID and FT keys consistent"
}

test_multiap_three_aps_native_static_neighbors() {
	ma_setup_controller --backend native
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	ma_host ap3 qualcomm-ipq807x SC_BASEMAC=02:33:00:00
	rc_run multiap add ap2 ap2
	rc_run multiap add ap3 ap3
	rc_run -y multiap sync
	assert_rc 0 "$RC"
	assert_eq 6 "$(grep -c . "$ORM_SYSROOT/etc/roamctl/neighbors.db")" "3 APs x 2 bands"
	nl=$(cat "$ORM_SYSROOT/../mock/ubus/hostapd.phy1-ap0/nr_list.state")
	assert_contains "$nl" "02:22:00:00:01:00" "controller advertises ap2"
	assert_contains "$nl" "02:33:00:00:00:00" "controller advertises ap3"
	assert_not_contains "$nl" "02:11:22:33:01:00" "never itself"
	nl3=$(cat "$FX_BASE/hosts/ap3/mock/ubus/hostapd.phy0-ap0/nr_list.state")
	assert_contains "$nl3" "02:11:22:33:00:00" "ap3 advertises controller"
	assert_contains "$nl3" "02:22:00:00:00:00" "ap3 advertises ap2"
	assert_eq native "$(fx_host_uci ap3 get roamctl.global.steering_backend_active)"
	assert_eq 3 "$(fx_host_uci ap3 get roamctl.global.ap_count)"
}

test_multiap_different_password_not_merged() {
	ma_setup_controller
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	ma_host ap3 filogic-2410 SC_BASEMAC=02:33:00:00 SC_KEY=other-password
	before=$(cat "$FX_BASE/hosts/ap3/root/etc/config/wireless")
	rc_run multiap add ap2 ap2
	rc_run multiap add ap3 ap3
	rc_run -y multiap sync
	assert_eq 3 "$RC" "failure reported"
	assert_contains "$ERR" "different passphrase - not merged"
	assert_eq "$before" "$(cat "$FX_BASE/hosts/ap3/root/etc/config/wireless")" "conflicting AP untouched"
	assert_eq 1 "$(fx_host_uci ap2 get wireless.default_radio0.ieee80211r)" "compatible AP synchronised"
}

test_multiap_different_encryption_not_merged() {
	ma_setup_controller
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00 SC_ENC=sae
	rc_run multiap add ap2 ap2
	rc_run -y multiap sync
	assert_eq 3 "$RC"
	assert_contains "$ERR" "uses security 'sae', controller uses 'psk' - not merged"
	assert_eq "" "$(fx_host_uci ap2 -q get wireless.default_radio0.ieee80211r)"
}

test_multiap_unreachable_ap_skipped() {
	ma_setup_controller
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	ma_host ap3 filogic-2410 SC_BASEMAC=02:33:00:00
	rc_run multiap add ap2 ap2
	rc_run multiap add ap3 ap3
	touch "$FX_BASE/hosts/ap2/down"
	rc_run -y multiap sync
	assert_ne 0 "$RC"
	assert_contains "$ERR" "ap_ap2 is unreachable - skipped"
	assert_eq "$(fx_uci get roamctl.g_5a776d62.mdid)" "$(fx_host_uci ap3 get wireless.default_radio0.mobility_domain)" "other APs still synchronised"
	assert_eq "" "$(fx_host_uci ap2 -q get wireless.default_radio0.ieee80211r)"
}

test_multiap_ssh_loss_stops_rollout() {
	ma_setup_controller
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	ma_host ap3 filogic-2410 SC_BASEMAC=02:33:00:00
	rc_run multiap add ap2 ap2
	rc_run multiap add ap3 ap3
	touch "$FX_BASE/hosts/ap2/drop_during_apply"
	rc_run -y multiap sync
	assert_ne 0 "$RC"
	assert_contains "$ERR" "stopping rollout"
	assert_eq "" "$(fx_host_uci ap3 -q get wireless.default_radio0.ieee80211r)" "no further AP changed after a failure"
	# the member itself completed safely on its own (transaction + watchdog)
	assert_no_file "$FX_BASE/hosts/ap2/root/etc/roamctl/pending"
}

test_multiap_sae_ft_key_distribution() {
	fx_new filogic-mt7988-6g
	rc_run -y setup
	ma_host ap2 filogic-mt7988-6g SC_BASEMAC=02:89:00:00
	rc_run multiap add ap2 ap2
	rc_run -y multiap sync
	assert_rc 0 "$RC"
	g=$(fx_uci show roamctl | sed -n 's/^roamctl\.\(g_[0-9a-f]*\)=group$/\1/p')
	k=$(cat "$ORM_SYSROOT/etc/roamctl/keys/$g.ftkey")
	assert_eq "$k" "$(cat "$FX_BASE/hosts/ap2/root/etc/roamctl/keys/$g.ftkey")" "identical FT key on member"
	assert_eq 600 "$(stat -c %a "$FX_BASE/hosts/ap2/root/etc/roamctl/keys/$g.ftkey")"
	assert_eq "ff:ff:ff:ff:ff:ff,*,$k" "$(fx_host_uci ap2 get wireless.default_radio2.r0kh)"
	assert_not_contains "$(cat "$MOCK_LOG")" "$k" "key never on an ssh command line"
	assert_not_contains "$OUT$ERR" "$k"
	rc_run multiap check
	assert_contains "$ERR" "MDID and FT keys consistent"
}

test_multiap_check_detects_drift_and_remove() {
	ma_setup_controller
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	rc_run multiap add ap2 ap2
	rc_run -y multiap sync
	fx_host_uci ap2 set wireless.default_radio0.mobility_domain=1234
	fx_host_uci ap2 commit wireless
	rc_run multiap check
	assert_eq 3 "$RC"
	assert_contains "$ERR" "MDID or FT key differs"
	rc_run multiap remove ap2
	assert_rc 0 "$RC"
	assert_not_contains "$(tr '\037' ' ' <"$ORM_SYSROOT/etc/roamctl/neighbors.db")" "ap_ap2" "neighbor entries withdrawn"
	assert_eq standalone "$(fx_uci get roamctl.global.mode)"
}

test_agent_rejects_malformed_payload() {
	fx_new filogic-2410
	ma_host ap2 filogic-2410 SC_BASEMAC=02:22:00:00
	before=$(cat "$FX_BASE/hosts/ap2/root/etc/config/wireless")
	out=$(printf 'orm-sync\0371\ngroup\037g_deadbeef\037HomeNet\037zzzz\037local\0371\0371\0371\037air\nend\n' |
		PATH=$(fx_path) ORM_SYSROOT="$FX_BASE/hosts/ap2/root" MOCK_DIR="$FX_BASE/hosts/ap2/mock" sh "$ORM_REPO/roamctl" agent apply 2>/dev/null)
	assert_contains "$out" "result=fail"
	assert_eq "$before" "$(cat "$FX_BASE/hosts/ap2/root/etc/config/wireless")"
}
