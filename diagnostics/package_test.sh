# shellcheck shell=sh
# Diagnostics: package integrity

diag_packages() {
	local _pm _w _p _act _be _inst _bin _o _l _k
	_pm=$(caps_get pkg.manager)
	if [ "$_pm" = none ]; then
		report_add packages "package manager" WARN "neither opkg nor apk found"
	else
		if pkg_installed_list >/dev/null 2>&1; then
			report_add packages "package manager" PASS "$_pm database readable"
		else
			report_add packages "package manager" FAIL "$_pm cannot list installed packages"
		fi
	fi

	# Exactly one hostapd/wpad provider
	_w=$(pkg_installed_list 2>/dev/null | while read -r _p; do pkg_wpad_family "$_p" && printf '%s ' "$_p"; done)
	# shellcheck disable=SC2086
	set -- $_w
	if [ "$#" -eq 0 ]; then
		report_add packages "wpad/hostapd" FAIL "no hostapd provider installed"
	elif [ "$#" -gt 1 ]; then
		report_add packages "wpad/hostapd" FAIL "conflicting hostapd providers installed: $*"
	else
		if have_cmd hostapd || have_cmd wpad; then
			report_add packages "wpad/hostapd" PASS "$1 installed, binary present"
		else
			report_add packages "wpad/hostapd" FAIL "$1 installed but hostapd binary missing"
		fi
	fi

	# Steering packages: installed backend has its daemon binary,
	# competing daemons not running simultaneously
	_act=$(roam_get global.steering_backend_active none)
	for _be in usteer dawn; do
		_inst=$(caps_get "steer.$_be.installed")
		[ "$_inst" = 1 ] || continue
		case "$_be" in
		usteer) _bin=/sbin/usteerd ;;
		dawn) _bin=/usr/sbin/dawn ;;
		esac
		if [ -x "$(orm_path "$_bin")" ] || have_cmd "$(basename "$_bin")"; then
			report_add packages "$_be" PASS "installed$([ "$_act" = "$_be" ] && printf ' (active backend)')"
		else
			report_add packages "$_be" FAIL "package present but $_bin missing (broken install)"
		fi
	done
	if [ -n "$(caps_get steer.conflict)" ]; then
		report_add packages "steering exclusivity" FAIL "multiple steering daemons running: $(caps_get steer.conflict)"
	else
		report_add packages "steering exclusivity" PASS "at most one steering daemon active"
	fi
	if [ "$_act" != none ] && [ "$_act" != native ] && [ "$(caps_get "steer.$_act.installed")" != 1 ]; then
		report_add packages "$_act" FAIL "configured steering backend is not installed"
	fi
	for _o in iw iwinfo; do
		have_cmd "$_o" || report_add packages "$_o" WARN "'$_o' missing: some diagnostics are limited"
	done
	# Previous installation failures
	grep '^pkg\.fail\.' "$(caps_file)" 2>/dev/null | while IFS= read -r _l; do
		_k=${_l%%=*}
		report_add packages "${_k#pkg.fail.}" WARN "not installed: ${_l#*=}"
	done
}
