# Unit tests: mobility domain, FT keys, neighbor reports, compatibility engine

test_mdid_generation_and_persistence() {
	fx_new filogic-2410
	mod_run '
	detect_everything
	a=$(mdid_ensure g_test HomeNet default_radio0 default_radio1)
	echo "$a"
	mdid_store g_test HomeNet "${a%% *}" generated
	b=$(mdid_ensure g_test HomeNet default_radio0 default_radio1)
	echo "$b"'
	set -- $OUT
	assert_match "$1" '^[0-9a-f]{4}$' "MDID format"
	assert_eq generated "$2"
	assert_eq "$1" "$3" "MDID must not be regenerated on later runs"
	assert_eq existing "$4"
}

test_mdid_reserved_and_unique() {
	fx_new filogic-2410
	mod_run '
	detect_everything
	mdid_store g_a A 1234 manual
	i=0; dup=0
	while [ $i -lt 40 ]; do
		m=$(mdid_generate g_b)
		mdid_reserved "$m" && dup=1
		[ "$m" = 1234 ] && dup=1
		i=$((i+1))
	done
	echo "dup=$dup"
	mdid_change g_a 0000 2>/dev/null || echo reserved-rejected
	mdid_change g_a xyz1 2>/dev/null || echo invalid-rejected
	mdid_store g_b B 5678 manual
	mdid_change g_b 1234 2>/dev/null || echo conflict-rejected
	mdid_change g_b abcd'
	assert_eq 'dup=0
reserved-rejected
invalid-rejected
conflict-rejected
abcd' "$OUT"
}

test_mdid_adopts_existing_consistent_ft() {
	fx_new filogic-2410
	fx_uci set wireless.default_radio0.ieee80211r=1
	fx_uci set wireless.default_radio0.mobility_domain=4f2a
	fx_uci set wireless.default_radio1.ieee80211r=1
	fx_uci set wireless.default_radio1.mobility_domain=4F2A
	fx_uci commit wireless
	mod_run 'detect_everything; mdid_ensure g_x HomeNet default_radio0 default_radio1'
	assert_eq "4f2a adopted" "$OUT"
}

test_mdid_inconsistent_existing_not_adopted() {
	fx_new filogic-2410
	fx_uci set wireless.default_radio0.ieee80211r=1
	fx_uci set wireless.default_radio0.mobility_domain=4f2a
	fx_uci set wireless.default_radio1.ieee80211r=1
	fx_uci set wireless.default_radio1.mobility_domain=9999
	fx_uci commit wireless
	mod_run 'detect_everything; mdid_ensure g_x HomeNet default_radio0 default_radio1'
	assert_contains "$OUT" generated "incompatible FT parameters must not be adopted"
}

test_mdid_scan_conflict_byte_order() {
	fx_new filogic-2410
	mkdir -p "$MOCK_DIR/iw/scan"
	printf 'BSS 02:99:00:00:00:01(on phy0-ap0)\n\tSSID: Neighbour\n\tMD: MDID 0x2c80 FT-over-DS\nBSS 02:99:00:00:00:02(on phy0-ap0)\n\tSSID: HomeNet\n\tMD: MDID 0x2c80\n' >"$MOCK_DIR/iw/scan/phy0-ap0"
	mod_run 'detect_everything; mdid_store g_h HomeNet 802c generated; mdid_scan phy0-ap0; cat "$ORM_STATE/scan_mdids"; mdid_conflicts'
	assert_contains "$OUT" "802c Neighbour" "little endian MDID converted to hostapd byte order"
	assert_contains "$OUT" "nearby network 'Neighbour' advertises the same Mobility Domain 802c"
	assert_not_contains "$OUT" "'HomeNet' advertises"
}

test_ft_key_modes() {
	fx_new filogic-2410
	mod_run 'for s in psk sae sae-mixed eap open owe; do printf "%s=%s " $s $(ft_key_mode_for $s); done; ft_key_mode_for psk shared'
	assert_eq "psk=local sae=shared sae-mixed=shared eap=shared open=none owe=none shared" "$OUT"
}

test_ft_key_storage() {
	fx_new filogic-2410
	mod_run '
	ft_key_ensure g_1 2>/dev/null; k1=$(ft_key_read g_1)
	ft_key_ensure g_1 2>/dev/null; k2=$(ft_key_read g_1)
	[ "$k1" = "$k2" ] && echo stable
	stat -c %a "$ORM_KEY_DIR" "$(ft_key_file g_1)"
	ft_r0kh_entry "$k1" | grep -Eq "^ff:ff:ff:ff:ff:ff,\*,[0-9a-f]{64}$" && echo r0kh-ok
	ft_r1kh_entry "$k1" | grep -Eq "^00:00:00:00:00:00,00:00:00:00:00:00,[0-9a-f]{64}$" && echo r1kh-ok
	ft_key_write g_1 nothex 2>/dev/null || echo malformed-rejected
	grep -c "$k1" "$ORM_LOG"'
	assert_eq 'stable
700
600
r0kh-ok
r1kh-ok
malformed-rejected
0' "$OUT" "key stored once, private, never logged"
}

test_nr_decode_and_validate() {
	fx_new filogic-2410
	mod_run '
	nr_decode 0211223300018f090000802409
	nr_validate 02:11:22:33:00:01 0211223300018f090000802409 && echo valid
	nr_validate 02:11:22:33:00:09 0211223300018f090000802409 || echo bssid-mismatch
	nr_validate 02:11:22:33:00:01 zz || echo garbage
	nr_validate 02:11:22:33:00:01 0211223300018f090000ff2409 || echo bad-opclass
	nr_opclass_band 81; nr_opclass_band 128; nr_opclass_band 133'
	assert_eq '02:11:22:33:00:01 128 36 9 0000098f
valid
bssid-mismatch
garbage
bad-opclass
2g5g6g' "$OUT"
}

test_nr_json_excludes_self_and_escapes() {
	fx_new filogic-2410
	mod_run '
	F=$ORM_FS
	ensure_dir "$ORM_ETC"
	printf "g1${F}local${F}a${F}02:00:00:00:00:01${F}My \"Net\"${F}0200000000018f0900007e0109${F}2g${F}1\n" >"$ORM_ETC/neighbors.db"
	printf "g1${F}ap_b${F}b${F}02:00:00:00:00:02${F}My \"Net\"${F}0200000000028f090000802409${F}5g${F}1\n" >>"$ORM_ETC/neighbors.db"
	printf "g2${F}ap_b${F}c${F}02:00:00:00:00:03${F}Other${F}0200000000038f090000802409${F}5g${F}1\n" >>"$ORM_ETC/neighbors.db"
	nr_json_for g1 02:00:00:00:00:01'
	assert_eq '{"list":[["02:00:00:00:00:02","My \"Net\"","0200000000028f090000802409"]]}' "$OUT"
}

test_compat_fullmac_no_ft() {
	fx_new broadcom-rpi4
	mod_run 'detect_everything; for f in can_11k can_11v can_11r why_11r; do caps_get iface.default_radio0.$f; echo; done'
	assert_contains "$OUT" "0
0
0
fullmac driver brcmfmac"
}

test_compat_no_11r_in_hostapd() {
	FXO_SC_FEATURES="sae eap" fx_new filogic-2410
	mod_run 'detect_everything; caps_get iface.default_radio0.can_11r; echo; caps_get iface.default_radio0.why_11r; echo; caps_get iface.default_radio0.can_11k'
	assert_contains "$OUT" "0
installed wpad-basic-mbedtls is built without IEEE 802.11r"
	assert_contains "$OUT" "
1" "802.11k must stay available"
}

test_compat_handler_without_option() {
	FXO_SC_UCI_UNSUPPORTED="bss_transition" fx_new filogic-2410
	mod_run 'detect_everything; caps_get iface.default_radio0.can_11v; echo; caps_get iface.default_radio0.why_11v'
	assert_eq "0
netifd wireless handler does not support the 'bss_transition' option" "$OUT"
}

test_compat_runtime_methods() {
	FXO_SC_WNM=0 FXO_SC_RRM=0 fx_new filogic-2410
	mod_run 'detect_everything; for f in can_11k why_11k can_11v why_11v can_11r; do caps_get iface.default_radio0.$f; echo; done'
	assert_contains "$OUT" "exports no neighbor report (rrm_nr_*) methods"
	assert_contains "$OUT" "built without WNM/BSS transition support"
	assert_match "$OUT" '1$' "802.11r stays available"
}

test_compat_security_modes() {
	fx_new filogic-mt7988-6g
	mod_run 'detect_everything; caps_get iface.default_radio2.ft_modes; echo; caps_get iface.default_radio2.security'
	assert_eq "ft-psk ft-sae
sae-mixed" "$OUT"
}

test_compat_open_network_no_ft() {
	FXO_SC_ENC=none fx_new filogic-2410
	mod_run 'detect_everything; caps_get iface.default_radio0.can_11r; echo; caps_get iface.default_radio0.why_11r'
	assert_contains "$OUT" "Fast Transition requires WPA2/WPA3 security"
}
