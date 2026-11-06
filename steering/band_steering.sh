# shellcheck shell=sh
# OpenWrt Roaming Manager - band steering
#
# Prefers 5 GHz / 6 GHz over 2.4 GHz for capable clients by sending BSS
# transition recommendations (native backend) or by configuring the
# selected backend's band steering. 2.4 GHz is never disabled and no SSID
# is split. Guest/IoT SSIDs are not part of roaming groups unless the
# administrator includes them, so they are never band steered implicitly.
# Individual clients can be excluded (roamctl steer exclude <mac>).

# Is band steering possible for a group? (same SSID on 2+ bands)
band_group_bands() {
	local _bb _s _b
	_bb=''
	for _s in $(roam_get "$1.iface"); do
		_b=$(caps_get "iface.$_s.band")
		case "$_b" in 2g | 5g | 6g) list_contains "$_bb" "$_b" || _bb="$_bb $_b" ;; esac
	done
	printf '%s' "${_bb# }"
}

band_steering_possible() {
	local _bands
	_bands=$(band_group_bands "$1")
	# shellcheck disable=SC2086
	set -- $_bands
	[ "$#" -ge 2 ]
}

# Preferred band order for a group, best first
band_preference() {
	local _bands _b
	_bands=$(band_group_bands "$1")
	for _b in 6g 5g 2g; do
		list_contains "$_bands" "$_b" && printf '%s ' "$_b"
	done
}

# Client exclusion management (stored in roamctl.steering)
band_client_list() {
	orm_uci -q get "roamctl.steering.$1" | tr ' ' '\n' | grep -v '^$'
}

band_client_add() {
	local _m
	# band_client_add exclude_client|include_client MAC
	is_mac "$2" || {
		log_error "Invalid MAC address '$2'"
		return 1
	}
	_m=$(lower "$2")
	orm_uci -q get roamctl.steering >/dev/null || orm_uci set roamctl.steering=steering
	band_client_list "$1" | grep -qx "$_m" && return 0
	orm_uci add_list "roamctl.steering.$1=$_m"
	orm_uci commit roamctl
}

band_client_del() {
	local _m
	_m=$(lower "$2")
	orm_uci -q del_list "roamctl.steering.$1=$_m"
	orm_uci commit roamctl
}
