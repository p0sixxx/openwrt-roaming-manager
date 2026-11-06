# shellcheck shell=sh
# Diagnostics: hardware / driver / kernel / backend compatibility

diag_hardware() {
	local _phys _p _drv _cls _bands _std _hb _fe _f
	case "$(caps_get os.support)" in
	supported) report_add hardware "OpenWrt release" PASS "$(caps_get os.version) ($(caps_get os.target))" ;;
	best-effort) report_add hardware "OpenWrt release" WARN "$(caps_get os.version) is not a tested release (24.10/25.x)" ;;
	unsupported) report_add hardware "OpenWrt release" FAIL "$(caps_get os.version) is too old (needs >= 22.03, tested 24.10/25.x)" ;;
	*) report_add hardware "OpenWrt release" WARN "release could not be determined" ;;
	esac

	_phys=$(caps_get hw.phys)
	if [ -z "$_phys" ]; then
		report_add hardware "wiphy" FAIL "no wireless hardware (phy) found"
	fi
	for _p in $_phys; do
		_drv=$(caps_get "phy.$_p.driver")
		_cls=$(caps_get "phy.$_p.driver_class")
		_bands=$(caps_get "phy.$_p.bands")
		_std=$(caps_get "phy.$_p.std")
		if [ "$(caps_get "phy.$_p.ap")" != 1 ] && [ "$(caps_get "phy.$_p.iw")" = 1 ]; then
			report_add hardware "$_p" FAIL "driver $_drv does not support AP mode"
			continue
		fi
		case "$_cls" in
		softmac) report_add hardware "$_p" PASS "$_drv (mac80211), bands: ${_bands:-?}, 802.11${_std:+ $_std}" ;;
		fullmac) report_add hardware "$_p" WARN "$_drv is a fullmac driver: 802.11r/k/v are not available in AP mode" ;;
		*) report_add hardware "$_p" WARN "driver '$_drv' unknown; features are verified at runtime only" ;;
		esac
		[ "$(caps_get "phy.$_p.iw")" = 1 ] || report_add hardware "$_p capabilities" "NOT TESTED" "'iw' not installed; PHY capabilities not inspected"
	done

	if [ "$(caps_get kernel.mac80211)" = 1 ]; then
		report_add hardware "kernel" PASS "$(caps_get kernel.version) with mac80211/cfg80211"
	elif [ -n "$ORM_SYSROOT" ] || [ "$(caps_get kernel.cfg80211)" = 1 ]; then
		report_add hardware "kernel" WARN "$(caps_get kernel.version): mac80211 module not loaded"
	else
		report_add hardware "kernel" FAIL "no cfg80211/mac80211 in kernel $(caps_get kernel.version)"
	fi

	_hb=$(caps_get hostapd.binary)
	if [ "$_hb" = none ]; then
		report_add hardware "hostapd" FAIL "no hostapd/wpad installed"
	else
		_fe=''
		for _f in 11r sae eap owe 11ax; do
			[ "$(caps_get "hostapd.feat.$_f")" = 1 ] && _fe="$_fe $_f"
		done
		report_add hardware "hostapd" PASS "$(caps_get hostapd.package) v$(caps_get hostapd.version), features:${_fe:- none detected}"
		[ "$(caps_get hostapd.variant)" = mini ] && report_add hardware "hostapd variant" WARN "wpad-mini lacks 802.11k/v; consider wpad-basic-mbedtls (roamctl backend replace)"
	fi
	for _f in 11k 11v 11r; do
		case "$(caps_get "compat.$_f")" in
		all) report_add hardware "802.$_f support" PASS "supported on all managed interfaces" ;;
		some) report_add hardware "802.$_f support" WARN "supported on some interfaces only" ;;
		*) report_add hardware "802.$_f support" "NOT SUPPORTED" "$(diag_first_reason "$_f")" ;;
		esac
	done
}

diag_first_reason() {
	local _s _w
	for _s in $(caps_get iface.list); do
		[ "$(caps_get "iface.$_s.eligible")" = 1 ] || continue
		_w=$(caps_get "iface.$_s.why_$1")
		[ -n "$_w" ] && { printf '%s' "$_w"; return; }
	done
	printf 'no eligible interface'
}
