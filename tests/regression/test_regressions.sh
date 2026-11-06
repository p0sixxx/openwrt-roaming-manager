# Regression tests for defects found during development

# Function variables leaking between functions (POSIX sh has no scoping):
# plan_list's loop variable overwrote the caller's 802.11v flag, so
# bss_transition was silently never planned.
test_reg_variable_scoping_keeps_11v() {
	fx_new filogic-2410
	rc_run -n setup
	assert_contains "$ERR" "wireless.default_radio0.bss_transition = 1"
	assert_contains "$ERR" "wireless.default_radio1.bss_transition = 1"
}

# Every function must declare its underscore variables local.
test_reg_all_function_variables_local() {
	bad=$(awk '
		FNR == 1 { infn = 0 }
		/^[A-Za-z_][A-Za-z0-9_]*\(\) *\{ *$/ { infn = 1; fn = $1; locals = ""; next }
		infn && /^\tlocal / { locals = locals " " $0 " "; next }
		infn && /^}$/ { infn = 0; next }
		infn {
			line = $0
			while (match(line, /(^|[ \t;&|(`])_[A-Za-z0-9_]+=/)) {
				v = substr(line, RSTART, RLENGTH); sub(/^[^_]*/, "", v); sub(/=$/, "", v)
				if (index(locals, " " v " ") == 0 && index(locals, " " v "\n") == 0) print FILENAME ": " fn " " v
				line = substr(line, RSTART + RLENGTH)
			}
		}' "$ORM_REPO/roamctl" "$ORM_REPO"/core/*.sh "$ORM_REPO"/roaming/*.sh "$ORM_REPO"/steering/*.sh \
		"$ORM_REPO"/multiap/*.sh "$ORM_REPO"/diagnostics/*.sh | sort -u)
	assert_eq "" "$bad" "non-local function variables"
}

# BusyBox/musl sed does not understand \t inside bracket expressions or
# GNU \| alternation; product code must use POSIX classes.
test_reg_no_gnu_regex_extensions() {
	bad=$(grep -n "sed .*\[ \\\\t\]\|sed -n .*\\\\|" "$ORM_REPO/roamctl" "$ORM_REPO"/core/*.sh "$ORM_REPO"/roaming/*.sh \
		"$ORM_REPO"/steering/*.sh "$ORM_REPO"/multiap/*.sh "$ORM_REPO"/diagnostics/*.sh | grep -v awk)
	assert_eq "" "$bad"
}

# Empty JSON containers were dropped, hiding usteer options such as
# ssid_list and aggressiveness_mac_list.
test_reg_json_empty_containers() {
	fx_new filogic-2410
	mod_run 'json_keys "{\"a\":[],\"b\":{},\"c\":1}" ""'
	assert_eq 'a
b
c' "$OUT"
}

# usteer was configured before the roaming groups were committed, so its
# ssid_list stayed empty on the first run.
test_reg_usteer_ssid_list_first_run() {
	fx_new filogic-2410
	rc_run -y setup
	assert_eq HomeNet "$(fx_uci get usteer.@usteer[0].ssid_list)"
}

# The repeated run planned the roamctl group section again (a section
# was mistaken for a list) and so reloaded wireless every time.
test_reg_second_run_no_reload() {
	fx_new filogic-2410
	rc_run -y setup
	n=$(grep -c '^wifi ' "$MOCK_LOG")
	rc_run -y setup
	assert_eq "$n" "$(grep -c '^wifi ' "$MOCK_LOG")"
}

# SSIDs with quotes and spaces must survive UCI, neighbor JSON and usteer.
test_reg_special_ssid() {
	FXO_SC_SSID="Café \"Main\" Net" fx_new filogic-2410
	rc_run -y --backend native setup
	assert_rc 0 "$RC"
	assert_eq 'Café "Main" Net' "$(fx_uci get roamctl.$(fx_uci show roamctl | sed -n 's/^roamctl\.\(g_[0-9a-f]*\)=group$/\1/p').ssid)"
	assert_contains "$(cat "$MOCK_DIR/ubus/hostapd.phy0-ap0/nr_list.state")" 'Café \"Main\" Net'
}

# Anonymous wifi-iface sections are reported by netifd as cfgXXXXXX.
test_reg_anonymous_sections() {
	fx_new filogic-2410
	sed -i "s/^config wifi-iface 'default_radio0'/config wifi-iface/; s/^config wifi-iface 'default_radio1'/config wifi-iface/" "$ORM_SYSROOT/etc/config/wireless"
	PATH=$(fx_path) wifi reload >/dev/null
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_eq 1 "$(fx_uci get wireless.@wifi-iface[0].ieee80211r)"
	assert_eq 1 "$(fx_uci get wireless.@wifi-iface[1].ieee80211r)"
	assert_contains "$ERR" "802.11r:       PASS"
}

# No secret may end up in the repository, logs, backups metadata or output.
test_reg_no_secrets_leak() {
	FXO_SC_KEY=SuperSecretPassphrase99 fx_new filogic-mt7988-6g
	rc_run -y -v setup
	logs="$OUT$ERR$(cat "$ORM_SYSROOT/tmp/roamctl.log") $(cat "$ORM_SYSROOT"/etc/roamctl/backups/*.meta) $(cat "$ORM_SYSROOT"/etc/roamctl/journal | tr '\037' ' ')"
	assert_not_contains "$logs" "SuperSecretPassphrase99"
	for k in "$ORM_SYSROOT"/etc/roamctl/keys/*; do
		assert_not_contains "$logs" "$(cat "$k")"
	done
	assert_contains "$(cat "$ORM_SYSROOT/etc/roamctl/journal" | tr '\037' ' ')" "r0kh U:"
}

# Assignments followed by && at the end of a command function made a
# successful command exit with status 1.
test_reg_exit_status_after_conditional() {
	fx_new filogic-2410
	rc_run -y setup
	rc_run -y mdid random g_5a776d62
	assert_rc 0 "$RC"
}

# Dry-run/audit created /etc/config/roamctl.
test_reg_audit_creates_no_files() {
	fx_new filogic-2410
	rc_run audit
	assert_no_file "$ORM_SYSROOT/etc/config/roamctl"
	assert_no_file "$ORM_SYSROOT/etc/roamctl"
}
