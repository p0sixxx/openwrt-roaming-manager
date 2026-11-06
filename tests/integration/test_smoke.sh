# Smoke tests: detection on a mock system
test_detect_filogic() {
	fx_new filogic-2410
	rc_run detect --raw
	assert_rc 0 "$RC" "detect exit code"
	assert_contains "$OUT" "os.version=24.10.2"
	assert_contains "$OUT" "soc.family=MediaTek Filogic 830"
	assert_contains "$OUT" "phy.phy0.driver=mt7915e"
	assert_contains "$OUT" "pkg.manager=opkg"
	assert_contains "$OUT" "iface.default_radio0.can_11r=1"
	assert_contains "$OUT" "iface.default_radio0.ifname=phy0-ap0"
	assert_contains "$OUT" "iface.guest_radio1.special=1"
}
