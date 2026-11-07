# Integration tests: MediaTek MT7621 (ramips) access points,
# typically used as additional (member) APs

test_ramips_mt7621_setup() {
	fx_new ramips-mt7621
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Platform:  MediaTek MT7621 (ramips, MIPS 1004Kc) (MT7621)"
	assert_contains "$ERR" "driver=mt7603e (softmac)"
	assert_contains "$ERR" "driver=mt76x2e (softmac)"
	for f in 11k 11v 11r; do assert_contains "$ERR" "802.$f:       PASS"; done
	assert_contains "$(cat "$ORM_SYSROOT"/var/run/hostapd-phy1.conf)" "wpa_key_mgmt=WPA-PSK FT-PSK"
	assert_eq usteer "$(fx_uci get roamctl.global.steering_backend_active)"
}

test_ramips_mt7621_mt7615_openwrt25() {
	fx_new ramips-mt7621-ac2100
	rc_run -y setup
	assert_rc 0 "$RC"
	assert_contains "$ERR" "Packages:  apk"
	assert_contains "$ERR" "driver=mt7615e (softmac)"
	assert_contains "$ERR" "802.11r:       PASS"
}



# 16 MB flash MT7621 boards with many extra packages can be nearly full
test_ramips_full_flash_falls_back() {
	FXO_SC_FLASH_FREE_KB=180 fx_new ramips-mt7621
	rc_run -y setup
	assert_rc 0 "$RC" "roaming works without extra packages"
	assert_contains "$ERR" "insufficient flash: 180 KB free"
	assert_not_contains "$(cat "$MOCK_LOG")" "opkg install" "no install attempt without space"
	assert_eq native "$(fx_uci get roamctl.global.steering_backend_active)"
	assert_contains "$ERR" "802.11r:       PASS"
	assert_contains "$ERR" "802.11k:       PASS"
	# only 3 backup generations on nearly full flash
	for i in 1 2 3 4 5; do rc_run backup create; done
	assert_eq 3 "$(ls "$ORM_SYSROOT"/etc/roamctl/backups/*.meta | wc -l | tr -d ' ')"
}

test_ramips_installer_flash_check() {
	FXO_SC_FLASH_FREE_KB=180 fx_new ramips-mt7621
	out=$(PATH=$(fx_path) ORM_INSTALL_NEED_KB=999999 sh "$ORM_REPO/install/install.sh" --prefix "$FX/p" 2>&1)
	assert_contains "$out" "Done." "prefix installs (staging) are not space checked"
}

# Typical deployment: Filogic main router + MT7621 extra APs
test_mixed_multiap_filogic_mt7621() {
	fx_new filogic-2410
	rc_run -y setup
	assert_rc 0 "$RC"
	(export FXO_SC_BASEMAC=02:76:21:00; fx_new ramips-mt7621 ap2)
	(export FXO_SC_BASEMAC=02:21:00:00 FXO_SC_FLASH_FREE_KB=180; fx_new ramips-mt7621 ap3)
	rc_run multiap add hall ap2
	rc_run multiap add garage ap3
	rc_run -y multiap sync
	assert_rc 0 "$RC" "sync exit code"
	md=$(fx_uci get roamctl.g_5a776d62.mdid)
	assert_eq "$md" "$(fx_host_uci ap2 get wireless.default_radio1.mobility_domain)" "MT7621 MDID"
	assert_eq "$md" "$(fx_host_uci ap3 get wireless.default_radio0.mobility_domain)" "second MT7621 MDID"
	assert_eq 1 "$(fx_host_uci ap3 get wireless.default_radio0.ft_psk_generate_local)"
	assert_eq 6 "$(grep -c . "$ORM_SYSROOT/etc/roamctl/neighbors.db")" "3 APs x 2 bands"
	assert_contains "$ERR" "ap_garage steering"
	assert_contains "$ERR" "insufficient flash"
	assert_eq native "$(fx_host_uci ap3 get roamctl.global.steering_backend_active)" "AP with full flash falls back to native"
	assert_eq usteer "$(fx_host_uci ap2 get roamctl.global.steering_backend_active)"
	nl=$(cat "$FX_BASE/hosts/ap3/mock/ubus/hostapd.phy0-ap0/nr_list.state")
	assert_contains "$nl" "02:11:22:33:01:00" "member advertises the main router"
	assert_contains "$nl" "02:76:21:00:01:00" "member advertises the other MT7621 AP"
	rc_run multiap check
	assert_rc 0 "$RC"
}

# Resource budget: the recurring native steering tick must stay cheap
# (it was ~1700 processes for 11 clients before optimisation).
test_perf_native_tick_budget() {
	fx_new ramips-mt7621
	rc_run -y --backend native setup
	c=''
	for i in 1 2 3 4 5 6 7 8 9; do c="$c\"02:aa:00:00:00:0$i\": {\"assoc\": true, \"signal\": -60, \"extended_capabilities\": [4,0,8,0]},"; done
	printf '{"freq": 5180, "clients": {%s "02:bb:00:00:00:01": {"assoc": true, "signal": -61}}}\n' "$c" >"$MOCK_DIR/clients/phy1-ap0.json"
	mod_run 'detect_everything; native_tick
	p0=$(awk "/^processes/ {print \$2}" /proc/stat); native_tick; p1=$(awk "/^processes/ {print \$2}" /proc/stat)
	echo $((p1 - p0))'
	n=$(printf '%s\n' "$OUT" | tail -n1)
	[ "$n" -le 120 ] || fail "native tick spawned $n processes for 10 clients (budget 120)"
}

test_perf_detection_budget() {
	fx_new ramips-mt7621
	p0=$(awk '/^processes/ {print $2}' /proc/stat)
	rc_run detect --raw
	p1=$(awk '/^processes/ {print $2}' /proc/stat)
	n=$((p1 - p0))
	# includes the mocked uci/ubus (shell + awk scripts, much heavier
	# than the real C binaries); was ~3100 before optimisation
	[ "$n" -le 1600 ] || fail "detection spawned $n processes (budget 1600)"
}
