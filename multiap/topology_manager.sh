# shellcheck shell=sh
# OpenWrt Roaming Manager - topology manager
#
# Member APs are stored as "config ap" sections in /etc/config/roamctl:
#   config ap 'ap_office'
#       option host '192.168.1.3'
#       option user 'root'
#       option port '22'
#       option enabled '1'
# The node running "roamctl multiap ..." is the controller.

roam_aps() {
	orm_uci -X show roamctl 2>/dev/null | sed -n 's/^roamctl\.\([^.=]*\)=ap$/\1/p'
}

roam_aps_enabled() {
	local _a
	for _a in $(roam_aps); do
		[ "$(orm_uci -q get "roamctl.$_a.enabled" || echo 1)" = 1 ] && printf '%s\n' "$_a"
	done
}

# Number of APs in the roaming system (this AP + enabled members)
roam_ap_count() {
	echo $(($(roam_aps_enabled | grep -c .) + 1))
}

topo_ap_name_valid() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_]{1,24}$'
}

topo_ap_add() {
	local _n _h _u _p _sec
	# topo_ap_add NAME HOST [USER] [PORT]
	_n=$1 _h=$2 _u=${3:-root} _p=${4:-22}
	topo_ap_name_valid "$_n" || { log_error "Invalid AP name '$_n' (letters, digits, _)"; return 1; }
	is_safe_host "$_h" || { log_error "Invalid host '$_h'"; return 1; }
	ssh_valid_user "$_u" || { log_error "Invalid user '$_u'"; return 1; }
	is_uint "$_p" || { log_error "Invalid port '$_p'"; return 1; }
	_sec="ap_$_n"
	roam_cfg_init
	orm_uci set "roamctl.$_sec=ap"
	orm_uci set "roamctl.$_sec.host=$_h"
	orm_uci set "roamctl.$_sec.user=$_u"
	orm_uci set "roamctl.$_sec.port=$_p"
	orm_uci set "roamctl.$_sec.enabled=1"
	orm_uci set roamctl.global.mode=multiap
	orm_uci set roamctl.global.role=controller
	orm_uci commit roamctl
	printf '%s' "$_sec"
}

topo_ap_remove() {
	local _sec _db
	_sec=$1
	case "$_sec" in ap_*) ;; *) _sec="ap_$_sec" ;; esac
	orm_uci -q get "roamctl.$_sec" >/dev/null || { log_error "Unknown AP '$1'"; return 1; }
	orm_uci delete "roamctl.$_sec"
	[ -z "$(roam_aps)" ] && orm_uci set roamctl.global.mode=standalone
	orm_uci commit roamctl
	# drop its neighbor entries so they are no longer advertised
	_db=$(nr_db)
	if [ -f "$_db" ]; then
		awk -F "$ORM_FS" -v h="$_sec" '$2 != h' "$_db" | atomic_write "$_db" 600
	fi
}

# Parse "key=value" output of "roamctl agent info" into caps under
# remote.<ap>.<key>
topo_store_info() {
	local _ap _l
	_ap=$1
	while IFS= read -r _l; do
		case "$_l" in
		*=*) caps_set "remote.$_ap.${_l%%=*}" "${_l#*=}" ;;
		esac
	done
}

# Query one AP. Returns 0 if reachable and compatible.
topo_probe_ap() {
	local _ap _info
	_ap=$1
	_info=$(ssh_agent "$_ap" info </dev/null 2>/dev/null)
	if [ -z "$_info" ]; then
		caps_set "remote.$_ap.reachable" 0
		return 1
	fi
	caps_set "remote.$_ap.reachable" 1
	printf '%s\n' "$_info" | topo_store_info "$_ap"
	return 0
}

# Compare a remote AP's view of every group with the controller's.
# Prints conflict lines; returns 1 when the AP must not be synchronised.
topo_check_ap() {
	local _ap _bad _rv _g _ssid _lsec _lfp _rsec _rfp _rmd _rftfp _md
	_ap=$1 _bad=0
	_rv=$(caps_get "remote.$_ap.roamctl")
	if [ "$_rv" != "$ORM_VERSION" ]; then
		echo "$_ap: roamctl version $_rv differs from controller $ORM_VERSION (warning)"
	fi
	case "$(caps_get "remote.$_ap.os_support")" in
	unsupported) echo "$_ap: OpenWrt $(caps_get "remote.$_ap.os_version") is not supported"; _bad=1 ;;
	esac
	for _g in $(roam_groups); do
		_ssid=$(roam_get "$_g.ssid")
		_lsec=$(caps_get "iface.$(roam_get "$_g.iface" | cut -d' ' -f1).security")
		_lfp=$(caps_get "iface.$(roam_get "$_g.iface" | cut -d' ' -f1).keyfp")
		_rsec=$(caps_get "remote.$_ap.group.$_g.security")
		_rfp=$(caps_get "remote.$_ap.group.$_g.keyfp")
		_rmd=$(caps_get "remote.$_ap.group.$_g.mdid")
		_rftfp=$(caps_get "remote.$_ap.group.$_g.ftkeyfp")
		if [ -z "$_rsec" ]; then
			echo "$_ap: SSID '$_ssid' not configured on this AP (group skipped there)"
			continue
		fi
		if [ "$_rsec" = conflict ]; then
			echo "$_ap: SSID '$_ssid' has inconsistent security between its interfaces"
			_bad=1
		elif [ "$_rsec" != "$_lsec" ]; then
			echo "$_ap: SSID '$_ssid' uses security '$_rsec', controller uses '$_lsec' - not merged"
			_bad=1
		elif [ "$_rfp" != "$_lfp" ]; then
			echo "$_ap: SSID '$_ssid' has a different passphrase - not merged"
			_bad=1
		fi
		_md=$(roam_get "$_g.mdid")
		if [ -n "$_rmd" ] && [ "$_rmd" != none ] && [ "$_rmd" != "$_md" ]; then
			echo "$_ap: SSID '$_ssid' uses Mobility Domain $_rmd, group uses $_md (will be aligned)"
		fi
		if [ "$(roam_get "$_g.ft_key_mode")" = shared ] && [ -n "$_rftfp" ] && [ "$_rftfp" != none ] &&
			[ "$_rftfp" != "$(ft_key_fingerprint "$_g")" ]; then
			echo "$_ap: FT key for '$_ssid' differs (will be aligned)"
		fi
	done
	return $_bad
}
