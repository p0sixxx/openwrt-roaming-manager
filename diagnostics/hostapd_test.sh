# shellcheck shell=sh
# Diagnostics: hostapd runtime (BSS, FT, RRM, BTM, configuration errors)

diag_hostapd() {
	local _hb _n _errs
	_hb=$(caps_get hostapd.binary)
	if [ "$_hb" = none ]; then
		report_add hostapd "daemon" FAIL "hostapd/wpad not installed"
		return 1
	fi
	_n=$(health_bss_count)
	if [ "$_n" -gt 0 ]; then
		report_add hostapd "daemon" PASS "$_n BSS registered on ubus"
	else
		report_add hostapd "daemon" FAIL "no hostapd BSS registered on ubus (hostapd not running or failed)"
	fi
	# per BSS validation of the running configuration (802.11k/v/r)
	hv_validate_all
	# recent configuration errors in the system log
	if have_cmd logread; then
		_errs=$(logread 2>/dev/null | tail -n 400 | grep -E 'hostapd.*(Invalid|invalid|Failed|failed|unknown configuration item|Line [0-9]+:)' | tail -n 3)
		if [ -n "$_errs" ]; then
			report_add hostapd "log" WARN "recent hostapd errors: $(printf '%s' "$_errs" | tr '\n' ' ' | cut -c1-300)"
		else
			report_add hostapd "log" PASS "no recent hostapd configuration errors in the system log"
		fi
	else
		report_add hostapd "log" "NOT TESTED" "logread not available"
	fi
}
