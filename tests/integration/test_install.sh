# Integration tests: installer, release scenarios for OpenWrt 24.10 / 25.x

test_installer_layout() {
	fx_new filogic-2410
	p="$FX/prefix"
	sh "$ORM_REPO/install/install.sh" --prefix "$p" >/dev/null || fail "installer failed"
	assert_file "$p/usr/sbin/roamctl"
	assert_file "$p/etc/init.d/roamctl"
	assert_file "$p/usr/lib/roamctl/config/profiles/balanced.conf"
	out=$("$p/usr/lib/roamctl/roamctl" --version)
	assert_eq "roamctl 1.0.0" "$out" "installed copy runs from its own directory"
	# reinstall is idempotent
	sh "$ORM_REPO/install/install.sh" --prefix "$p" >/dev/null || fail "reinstall failed"
	sh "$ORM_REPO/install/uninstall.sh" --prefix "$p" >/dev/null
	assert_no_file "$p/usr/sbin/roamctl"
	assert_no_file "$p/usr/lib/roamctl/roamctl"
}

test_ssh_rejects_unsafe_arguments() {
	fx_new filogic-2410
	rc_run multiap add evil '-oProxyCommand=reboot'
	assert_eq 1 "$RC"
	assert_contains "$ERR" "Unknown option"
	rc_run multiap add evil -- '-oProxyCommand=reboot'
	assert_eq 1 "$RC"
	assert_contains "$ERR" "Invalid host"
	rc_run multiap add 'bad;name' 192.168.1.9
	assert_contains "$ERR" "Invalid AP name"
	rc_run multiap add ap9 192.168.1.9 --user 'root;id'
	assert_contains "$ERR" "Invalid user"
	mod_run 'roam_cfg_init; orm_uci set roamctl.ap_x=ap; orm_uci set roamctl.ap_x.host=x; orm_uci commit roamctl
	ssh_agent ap_x watch "aa:bb;reboot" 5; echo "rc=$?"
	ssh_agent ap_x "rm -rf /" ; echo "rc=$?"'
	assert_contains "$OUT" "rc=255
rc=255"
	assert_not_contains "$(cat "$MOCK_LOG" 2>/dev/null)" "reboot"
}

# Release scenario matrix (CI runs each with TEST_OPENWRT=24.10 / 25)
test_release_scenarios() {
	case "${TEST_OPENWRT:-all}" in
	24.10) scen="filogic-2410 ramips-mt7621" ;;
	25) scen="filogic-25 filogic-mt7988-6g ramips-mt7621-ac2100" ;;
	*) scen="filogic-2410 filogic-25 ramips-mt7621" ;;
	esac
	for s in $scen; do
		fx_new "$s"
		rc_run -y setup
		assert_rc 0 "$RC" "$s setup"
		assert_contains "$ERR" "802.11r:       PASS" "$s 802.11r"
		assert_contains "$ERR" "802.11k:       PASS" "$s 802.11k"
		assert_contains "$ERR" "802.11v:       PASS" "$s 802.11v"
		rc_run diag
		assert_rc 0 "$RC" "$s diagnostics"
		fx_cleanup
	done
}
