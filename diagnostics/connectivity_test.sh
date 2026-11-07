# shellcheck shell=sh
# Diagnostics: connectivity (DHCP, gateway, DNS, LAN, internet)

diag_connectivity() {
	local _nets _g _s _n _st _ip _dhcp_local _d _init _ignore _leases _gw _lr
	uci_cache_warm
	# LAN bridge(s) used by roaming interfaces have an address
	_nets=''
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			for _n in $(caps_get "iface.$_s.network"); do
				list_contains "$_nets" "$_n" || _nets="$_nets $_n"
			done
		done
	done
	for _n in ${_nets:-lan}; do
		_st=$(ubus call "network.interface.$_n" status 2>/dev/null)
		if [ -z "$_st" ]; then
			report_add connectivity "network $_n" WARN "interface status unavailable"
			continue
		fi
		if [ "$(json_get "$_st" up)" = true ]; then
			_ip=$(json_get "$_st" ipv4-address.0.address)
			report_add connectivity "network $_n" PASS "up${_ip:+, $_ip}"
		else
			report_add connectivity "network $_n" FAIL "network '$_n' is down"
		fi
	done

	# DHCP: local server (router mode) or upstream (dumb AP mode)
	_dhcp_local=0
	for _d in dnsmasq odhcpd; do
		_init=$(orm_path "/etc/init.d/$_d")
		[ -x "$_init" ] && "$_init" running >/dev/null 2>&1 && _dhcp_local=1
	done
	_ignore=$(orm_uci -q get dhcp.lan.ignore)
	if [ "$_ignore" = 1 ]; then
		report_add connectivity "DHCP" PASS "DHCP served upstream (dumb AP mode, dhcp.lan.ignore=1)"
	elif [ "$_dhcp_local" = 1 ]; then
		_leases=$(grep -c . "$(orm_path /tmp/dhcp.leases)" 2>/dev/null)
		report_add connectivity "DHCP" PASS "local DHCP server running (${_leases:-0} leases)"
	else
		report_add connectivity "DHCP" WARN "no local DHCP server running and dhcp.lan.ignore is not set"
	fi

	_gw=$(health_gateway)
	if [ -z "$_gw" ]; then
		report_add connectivity "gateway" WARN "no default route"
	elif ping -c 2 -W 2 "$_gw" >/dev/null 2>&1; then
		report_add connectivity "gateway" PASS "$_gw reachable"
	else
		report_add connectivity "gateway" FAIL "$_gw unreachable"
	fi
	if net_check_dns openwrt.org; then
		report_add connectivity "DNS" PASS "name resolution works"
	else
		report_add connectivity "DNS" FAIL "name resolution failed"
	fi
	if net_check_internet; then
		report_add connectivity "internet" PASS "internet reachable"
	else
		report_add connectivity "internet" WARN "internet not reachable (roaming itself does not need it)"
	fi
	_lr=$(kv_get "$ORM_ETC/last_rollback" reason)
	if [ -n "$_lr" ]; then
		report_add connectivity "last change" WARN "a previous change was rolled back ($_lr, backup $(kv_get "$ORM_ETC/last_rollback" id))"
	fi
}
