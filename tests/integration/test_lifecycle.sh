# Integration tests: idempotency, rollback, recovery, uninstall, audit, repair, conflicts

test_repeated_run_is_idempotent() {
	fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC"
	md1=$(fx_uci get roamctl.g_5a776d62.mdid)
	cfg1=$(cat "$ORM_SYSROOT/etc/config/wireless" "$ORM_SYSROOT/etc/config/usteer")
	reloads1=$(grep -c '^wifi ' "$MOCK_LOG")
	backups1=$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.meta | wc -l)
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "already up to date"
	assert_eq "$md1" "$(fx_uci get roamctl.g_5a776d62.mdid)" "MDID not regenerated"
	assert_eq "$cfg1" "$(cat "$ORM_SYSROOT/etc/config/wireless" "$ORM_SYSROOT/etc/config/usteer")" "no config drift"
	assert_eq "$reloads1" "$(grep -c '^wifi ' "$MOCK_LOG")" "no wireless reload on second run"
	assert_eq "$backups1" "$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.meta | wc -l)" "no backup when nothing changes"
	assert_eq 1 "$(grep -c 'opkg install usteer' "$MOCK_LOG")" "package installed once"
}

test_hostapd_failure_triggers_rollback() {
	fx_new filogic-2410
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	# hostapd on this system rejects the FT configuration (radio fails)
	printf 'SC_REJECT=ieee80211r\n' >>"$MOCK_DIR/scenario.env"
	rc_run -y setup
	assert_ne 0 "$RC" "failure reported"
	assert_contains "$ERR" "health: hostapd: only"
	assert_contains "$ERR" "Rolled back to backup"
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")" "wireless restored byte for byte"
	assert_eq health-check "$(sed -n 's/^reason=//p' "$ORM_SYSROOT/etc/roamctl/last_rollback")"
	assert_eq "true" "$(PATH=$(fx_path) ubus call network.wireless status | grep -c '"up": true' | sed 's/^[1-9][0-9]*$/true/')" "radios up again"
	assert_no_file "$ORM_SYSROOT/etc/roamctl/pending"
	assert_no_file "$MOCK_DIR/svc/usteer.running"
}

test_uci_commit_error_rolls_back() {
	fx_new filogic-2410
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	MOCK_UCI_COMMIT_FAIL=wireless rc_run -y setup
	assert_ne 0 "$RC"
	assert_contains "$ERR" "uci commit failed"
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")"
	assert_eq "" "$(fx_uci changes)" "no staged changes left behind"
}

test_watchdog_rolls_back_when_session_dies() {
	fx_new filogic-2410
	before=$(cat "$ORM_SYSROOT/etc/config/wireless")
	# roamctl is killed (e.g. SSH over Wi-Fi drops) after arming the
	# watchdog and changing the configuration, before confirming
	mod_run 'detect_everything; roam_cfg_init
	id=$(backup_create test 2>/dev/null)
	rollback_arm "$id" 3
	orm_uci set wireless.default_radio0.ssid=BROKEN; orm_uci commit wireless
	exit 0'
	assert_eq BROKEN "$(fx_uci get wireless.default_radio0.ssid)"
	i=0
	while [ $i -lt 20 ] && [ -f "$ORM_SYSROOT/etc/roamctl/pending" ]; do sleep 1; i=$((i + 1)); done
	sleep 1
	assert_eq "$before" "$(cat "$ORM_SYSROOT/etc/config/wireless")" "watchdog restored the backup"
	assert_eq watchdog "$(sed -n 's/^reason=//p' "$ORM_SYSROOT/etc/roamctl/last_rollback")"
}

test_boot_check_restores_unconfirmed_change() {
	fx_new filogic-2410
	mod_run 'detect_everything; roam_cfg_init
	id=$(backup_create test 2>/dev/null)
	printf "id=%s\ndeadline=1\n" "$id" >"$ORM_ETC/pending"
	orm_uci set wireless.default_radio0.ssid=BROKEN; orm_uci commit wireless'
	rc_run boot
	assert_eq HomeNet "$(fx_uci get wireless.default_radio0.ssid)" "restored at boot"
	assert_no_file "$ORM_SYSROOT/etc/roamctl/pending"
}

test_manual_rollback_and_restore() {
	fx_new filogic-2410
	rc_run -y setup
	first=$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.meta | head -n1)
	id=$(basename "$first" .meta)
	rc_run backup list
	assert_contains "$OUT" "$id"
	rc_run backup verify "$id"
	assert_rc 0 "$RC"
	rc_run -y rollback "$id"
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)" "pre-setup state restored"
	assert_no_file "$MOCK_DIR/svc/usteer.running"
}

test_uninstall_reverts_exactly() {
	fx_new filogic-2410
	orig=$(cat "$ORM_SYSROOT/etc/config/wireless")
	rc_run -y setup
	# an unrelated change made later by the administrator is kept
	fx_uci set wireless.radio0.txpower=17
	fx_uci commit wireless
	rc_run -y uninstall
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)"
	assert_eq "" "$(fx_uci -q get wireless.default_radio1.mobility_domain)"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.bss_transition)"
	assert_eq 17 "$(fx_uci get wireless.radio0.txpower)" "unrelated change kept"
	assert_no_file "$ORM_SYSROOT/etc/config/roamctl"
	assert_no_file "$MOCK_DIR/svc/usteer.running"
	assert_no_file "$ORM_SYSROOT/etc/rc.d/S99usteer"
	fx_uci delete wireless.radio0.txpower
	fx_uci commit wireless
	assert_eq "$orig" "$(cat "$ORM_SYSROOT/etc/config/wireless")" "original configuration"
}

test_audit_and_dry_run_change_nothing() {
	fx_new filogic-2410
	sum() { find "$ORM_SYSROOT/etc" -type f -exec sha256sum {} + | sort | sha256sum; }
	s0=$(sum)
	rc_run audit
	assert_contains "$ERR" "Planned configuration changes"
	assert_contains "$ERR" "'roamctl setup' would apply"
	assert_eq "$s0" "$(sum)" "audit is read-only"
	rc_run -n setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Dry run - nothing was changed"
	assert_eq "$s0" "$(sum)" "dry-run is read-only"
	assert_not_contains "$(cat "$MOCK_LOG")" "opkg install"
	assert_not_contains "$(cat "$MOCK_LOG")" "wifi reload"
}

test_repair_fixes_drift() {
	fx_new filogic-2410
	rc_run -y setup
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	fx_uci set wireless.default_radio1.mobility_domain=1111
	fx_uci delete wireless.default_radio0.bss_transition
	fx_uci commit wireless
	PATH=$(fx_path) wifi reload >/dev/null
	rc_run diag
	assert_eq 3 "$RC" "diagnostics report the drift"
	assert_contains "$ERR" "mobility_domain '1111' != $md"
	rc_run -y repair
	assert_rc 0 "$RC"
	assert_eq "$md" "$(fx_uci get wireless.default_radio1.mobility_domain)"
	assert_eq 1 "$(fx_uci get wireless.default_radio0.bss_transition)"
}

test_mdid_conflict_with_other_network() {
	fx_new filogic-2410
	rc_run -y setup
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	# administrator configures FT on the IoT SSID with the same MDID
	fx_uci set wireless.iot_radio0.ieee80211r=1
	fx_uci set wireless.iot_radio0.mobility_domain="$md"
	fx_uci commit wireless
	rc_run mdid show
	assert_contains "$OUT" "SSID 'HomeNet-IoT' (iot_radio0) uses the same Mobility Domain $md"
	rc_run diag
	assert_contains "$ERR" "MDID conflict"
	rc_run -y mdid set g_5a776d62 "$md"
	rc_run -y mdid random g_5a776d62
	assert_rc 0 "$RC"
	new=$(fx_uci get roamctl.g_5a776d62.mdid)
	assert_ne "$md" "$new" "manual change to a new random MDID"
	assert_eq "$new" "$(fx_uci get wireless.default_radio0.mobility_domain)" "applied to interfaces"
	assert_eq manual "$(fx_uci get roamctl.g_5a776d62.mdid_origin)"
}

test_local_password_conflict_not_grouped() {
	fx_new filogic-2410
	fx_uci set wireless.default_radio1.key=another-password
	fx_uci commit wireless
	rc_run -y setup
	assert_contains "$ERR" "passphrase differs"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)" "conflicting SSID not merged"
}

test_local_encryption_conflict_not_grouped() {
	fx_new filogic-2410
	fx_uci set wireless.default_radio1.encryption=sae
	fx_uci commit wireless
	rc_run -y setup
	assert_contains "$ERR" "security mode differs"
	assert_eq "" "$(fx_uci -q get wireless.default_radio1.ieee80211r)"
}

test_parallel_runs_blocked() {
	fx_new filogic-2410
	mkdir -p "$ORM_SYSROOT/var/run/roamctl/lock"
	echo "$MOCK_ALIVE_PID" >"$ORM_SYSROOT/var/run/roamctl/lock/pid"
	rc_run -y setup
	assert_eq 1 "$RC"
	assert_contains "$ERR" "Another roamctl instance is running"
}

test_cli_basics() {
	fx_new filogic-2410
	rc_run --version
	assert_eq "roamctl 1.0.0" "$OUT"
	rc_run --help
	assert_contains "$OUT" "Usage: roamctl"
	rc_run --bogus
	assert_eq 1 "$RC"
	rc_run --profile turbo setup
	assert_contains "$ERR" "Invalid profile"
	rc_run status
	assert_contains "$ERR" "Roaming not configured"
	rc_run --exclude 'x;reboot' setup
	assert_contains "$ERR" "Invalid section name"
}
