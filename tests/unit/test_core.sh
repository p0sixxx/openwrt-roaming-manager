# Unit tests: common helpers, JSON reader, logger masking, locking, UCI plan/journal

test_random_hex_secure() {
	fx_new filogic-2410
	mod_run 'a=$(random_hex 2); b=$(random_hex 32); c=$(random_hex 32); echo "$a $b $c"'
	set -- $OUT
	assert_match "$1" '^[0-9a-f]{4}$' "2-byte random"
	assert_match "$2" '^[0-9a-f]{64}$' "32-byte random"
	assert_ne "$2" "$3" "two keys must differ"
	# $RANDOM must never be used anywhere in the product
	if grep -rnE '[$][{]?RANDOM([^A-Za-z_]|$)' "$ORM_REPO/roamctl" "$ORM_REPO"/core "$ORM_REPO"/roaming "$ORM_REPO"/steering "$ORM_REPO"/multiap | grep -v ':[[:space:]]*#' | grep -q .; then
		fail "\$RANDOM used in product code"
	fi
}

test_input_validation() {
	fx_new filogic-2410
	mod_run '
	is_mac aa:bb:cc:dd:ee:ff && echo mac1
	is_mac "aa:bb:cc:dd:ee" || echo mac2
	is_safe_host 192.168.1.2 && echo h1
	is_safe_host "-oProxyCommand=sh" || echo h2
	is_safe_host "a;reboot" || echo h3
	is_safe_host "ap-1.lan" && echo h4
	is_uint 12 && echo u1
	is_uint -3 || echo u2'
	assert_eq "mac1 mac2 h1 h2 h3 h4 u1 u2" "$(echo $OUT)"
}

test_json_reader() {
	fx_new filogic-2410
	mod_run '
	J="{\"r0\":{\"up\":true,\"interfaces\":[{\"ifname\":\"a\",\"section\":\"s1\"},{\"section\":\"s2\",\"ifname\":\"b\"}]},\"n\":-55,\"s\":\"q\\\"x\"}"
	json_get "$J" r0.up; json_get "$J" n; json_get "$J" s
	json_glob "$J" "*.interfaces.*.ifname" | tr "\n" ,; echo
	json_keys "$J" "" | tr "\n" ,; echo
	json_find_index "$J" r0.interfaces section s2'
	assert_eq 'true
-55
q"x
a,b,
r0,n,s,
1' "$OUT"
}

test_json_escape() {
	fx_new filogic-2410
	mod_run 'json_escape "a\"b\\c	d"'
	assert_eq 'a\"b\\c\td' "$OUT"
}

test_log_masks_secrets() {
	fx_new filogic-2410
	mod_run 'log_info "key=supersecret r0kh ff:ff:ff:ff:ff:ff,*,0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; cat "$ORM_LOG"'
	assert_not_contains "$ERR$OUT" "supersecret"
	assert_not_contains "$ERR$OUT" "0123456789abcdef0123456789abcdef"
	assert_contains "$ERR" "<redacted>"
}

test_atomic_write_and_kv() {
	fx_new filogic-2410
	mod_run '
	printf "hello\n" | atomic_write "$ORM_STATE/x/f" 600
	cat "$ORM_STATE/x/f"; stat -c %a "$ORM_STATE/x/f"
	kv_set "$ORM_STATE/kv" a 1; kv_set "$ORM_STATE/kv" b 2; kv_set "$ORM_STATE/kv" a 3
	kv_get "$ORM_STATE/kv" a; kv_get "$ORM_STATE/kv" b; kv_get "$ORM_STATE/kv" c def; echo
	ls -a "$ORM_STATE/x" | grep -c tmp'
	assert_eq 'hello
600
32def
0' "$OUT"
}

test_lock_prevents_parallel_runs() {
	fx_new filogic-2410
	mod_run '
	lock_acquire && echo first
	( ORM_LOCK_WAIT=1; ORM_LOCK_HELD=0; lock_acquire && echo second-acquired || echo second-blocked )
	lock_release
	# stale lock of a dead process is removed
	mkdir -p "$ORM_STATE/lock"; echo 999999 >"$ORM_STATE/lock/pid"
	lock_acquire && echo stale-recovered'
	assert_contains "$OUT" first
	assert_contains "$OUT" second-blocked
	assert_contains "$OUT" stale-recovered
	assert_not_contains "$OUT" second-acquired
}

test_plan_journal_restore() {
	fx_new filogic-2410
	mod_run '
	roam_cfg_init
	plan_reset
	plan_set wireless.default_radio0.ssid HomeNet
	plan_set wireless.default_radio0.ieee80211r 1
	plan_list wireless.default_radio0.r0kh "a,b,c"
	echo "count=$(plan_count)"
	plan_apply; cfg_commit
	uci_get_list wireless.default_radio0.r0kh
	orm_uci get wireless.default_radio0.ieee80211r
	journal_restore_uci
	orm_uci -q get wireless.default_radio0.ieee80211r || echo unset
	orm_uci -q get wireless.default_radio0.r0kh || echo nolist
	orm_uci get wireless.default_radio0.ssid'
	assert_eq 'count=2
a,b,c
1
unset
nolist
HomeNet' "$OUT" "plan skips unchanged values, journal restores originals"
}

test_backup_create_verify_restore() {
	fx_new filogic-2410
	mod_run '
	detect_everything
	id=$(backup_create test 2>/dev/null)
	backup_verify "$id" && echo verified
	stat -c %a "$ORM_BACKUP_DIR" "$ORM_BACKUP_DIR/$id.tar.gz"
	orm_uci set wireless.default_radio0.ssid=Changed; orm_uci commit wireless
	backup_restore "$id" 2>/dev/null && orm_uci get wireless.default_radio0.ssid
	echo corrupt >>"$ORM_BACKUP_DIR/$id.tar.gz"
	backup_verify "$id" 2>/dev/null || echo detected-corruption'
	assert_eq 'verified
700
600
HomeNet
detected-corruption' "$OUT"
}
