# Regression tests for the findings of the code audit (2026-11)

# 1. The daemon re-collected neighbor reports every minute and rewrote
#    /etc/roamctl/neighbors.db on flash each time.
test_audit_nr_db_no_flash_rewrite() {
	fx_new filogic-2410
	rc_run -y --backend native setup
	db="$ORM_SYSROOT/etc/roamctl/neighbors.db"
	i1=$(ls -i "$db" | cut -d' ' -f1)
	mod_run 'detect_everything; nr_maintain; nr_maintain; nr_maintain'
	assert_eq "$i1" "$(ls -i "$db" | cut -d' ' -f1)" "unchanged DB must not be rewritten"
	assert_no_file "$ORM_SYSROOT/var/run/roamctl/nrdb.lock"
	# a real change is still written
	mod_run 'detect_everything; printf "x\n" | nr_db_merge_host ap_test; :'
	assert_ne "$i1" "$(ls -i "$db" | cut -d' ' -f1)" "changed DB is written"
}

# 2. A wifi reload drops a wireless uplink for some seconds; the health
#    check gave up after 3 s and rolled back every time.
uplink_fixture() {
	fx_new filogic-2410
	cat >>"$ORM_SYSROOT/etc/config/wireless" <<'W'

config wifi-iface 'wwan'
	option device 'radio0'
	option network 'wwan'
	option mode 'sta'
	option ssid 'MainRouter'
	option encryption 'psk2'
	option key 'uplinkpassword'
W
	PATH=$(fx_path) wifi reload >/dev/null
}

test_audit_wireless_uplink_waits() {
	uplink_fixture
	echo 7 >"$MOCK_DIR/net/uplink_drop_seconds"
	rc_run -y setup
	assert_rc 0 "$RC" "no false rollback"
	assert_contains "$ERR" "uses a wireless uplink"
	assert_eq 1 "$(fx_uci get wireless.default_radio0.ieee80211r)"
	assert_no_file "$ORM_SYSROOT/etc/roamctl/last_rollback"
}

test_audit_uplink_lost_still_rolls_back() {
	uplink_fixture
	echo 1000 >"$MOCK_DIR/net/uplink_drop_seconds"
	ORM_GW_WAIT=6 rc_run -y setup
	assert_ne 0 "$RC"
	assert_contains "$ERR" "default gateway unreachable after change"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)" "rolled back"
}

# 3. Daemon and CLI shared one capability file.
test_audit_caps_per_process() {
	fx_new filogic-2410
	rc_run detect --raw
	assert_contains "$OUT" "os.version=24.10.2"
	left=$(ls "$ORM_SYSROOT"/var/run/roamctl/caps* 2>/dev/null)
	assert_eq "" "$left" "per-process capability file removed on exit"
	mod_run 'ORM_CAPS_ID=a; caps_reset; caps_set k 1; ORM_CAPS_ID=b; caps_reset; caps_set k 2
	ORM_CAPS_ID=a; caps_reload; caps_get k; echo; ls "$ORM_STATE" | grep -c "^caps\."'
	assert_eq '1
2' "$OUT" "separate files per process"
}

# 4. A manual rollback restored all of /etc/config.
test_audit_rollback_keeps_unrelated_config() {
	fx_new filogic-2410
	rc_run -y setup
	id=$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.meta | head -n1)
	id=$(basename "$id" .meta)
	fx_uci set network.lan.ipaddr=192.168.1.2
	fx_uci commit network
	rc_run -y rollback "$id"
	assert_rc 0 "$RC"
	assert_eq "" "$(fx_uci -q get wireless.default_radio0.ieee80211r)" "wireless restored"
	assert_eq 192.168.1.2 "$(fx_uci get network.lan.ipaddr)" "network kept"
	rc_run -y --full rollback "$id"
	assert_contains "$ERR" "reboot afterwards"
	assert_eq 192.168.1.1 "$(fx_uci get network.lan.ipaddr)" "--full restores everything"
}

# 5. The RAM log grew without limit.
test_audit_log_rotation() {
	fx_new filogic-2410
	mod_run 'ORM_LOG_MAX=3000; i=0
	while [ $i -lt 400 ]; do log_info "line $i xxxxxxxxxxxxxxxxxxxx" 2>/dev/null; i=$((i + 1)); done
	wc -c <"$ORM_LOG"; [ -f "$ORM_LOG.1" ] && echo rotated'
	sz=$(printf '%s\n' "$OUT" | head -n1 | tr -d ' ')
	[ "$sz" -lt 7000 ] || fail "log is $sz bytes (limit ~3000 + 50 lines)"
	assert_contains "$OUT" rotated
}
