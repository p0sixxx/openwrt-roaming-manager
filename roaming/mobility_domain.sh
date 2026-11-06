# shellcheck shell=sh
# OpenWrt Roaming Manager - Mobility Domain Manager
#
# The Mobility Domain ID (MDID, IEEE 802.11r MDE) is 2 octets, written as
# four hex characters in hostapd/UCI ("mobility_domain").
#
#  * generated once per roaming group from the kernel CSPRNG
#  * persisted in /etc/config/roamctl (survives reboots and sysupgrade
#    when /etc/config is kept)
#  * reused on every subsequent run - never regenerated implicitly
#  * shared by all APs of a group (multi-AP sync pushes it to members)
#  * different groups always get different MDIDs (conflict detection)

mdid_valid() {
	printf '%s' "$1" | grep -Eq '^[0-9a-f]{4}$'
}

# Values we never hand out: all-zero / all-one and the hostapd example
mdid_reserved() {
	case "$1" in
	0000 | ffff | a1b2) return 0 ;;
	esac
	return 1
}

# OpenWrt derives a default MDID from the SSID (md5) when none is set.
# A configured MDID equal to that default is "implicit", not user chosen.
mdid_openwrt_default() {
	printf '%s' "$1" | md5sum | cut -c1-4
}

# All MDIDs known to be in use: other roamctl groups, other SSIDs in the
# local wireless config, remote APs and scan results (excluding GROUP).
mdid_in_use() {
	local _skip _g _skip_ssid _s _md _ssid
	_skip=${1:-}
	for _g in $(roam_groups); do
		[ "$_g" = "$_skip" ] && continue
		roam_get "$_g.mdid"
		echo
	done
	_skip_ssid=$(roam_get "$_skip.ssid")
	for _s in $(caps_get iface.list); do
		_md=$(caps_get "iface.$_s.uci_mobility_domain")
		[ -n "$_md" ] || continue
		[ -n "$_skip" ] && [ "$(caps_get "iface.$_s.ssid")" = "$_skip_ssid" ] && continue
		lower "$_md"
		echo
	done
	cat "$ORM_STATE/scan_mdids" 2>/dev/null | while IFS=' ' read -r _md _ssid; do
		[ "$_ssid" = "$_skip_ssid" ] && continue
		printf '%s\n' "$_md"
	done
}

mdid_generate() {
	local _used _tries _cand
	# mdid_generate [GROUP] -> new MDID not in use
	_used=$(mdid_in_use "${1:-}" | tr '\n' ' ')
	_tries=0
	while [ "$_tries" -lt 64 ]; do
		_cand=$(random_hex 2) || return 1
		_tries=$((_tries + 1))
		mdid_reserved "$_cand" && continue
		list_contains "$_used" "$_cand" && continue
		printf '%s' "$_cand"
		return 0
	done
	log_error "Unable to generate a free Mobility Domain ID"
	return 1
}

# Existing MDID consistently configured on all member interfaces (adopted
# so roaming with APs that are not yet managed by roamctl keeps working).
mdid_existing_for_ifaces() {
	local _ssid _found _s _md
	_ssid=$1
	shift
	_found=''
	for _s in "$@"; do
		[ "$(caps_get "iface.$_s.uci_ieee80211r")" = 1 ] || return 1
		_md=$(lower "$(caps_get "iface.$_s.uci_mobility_domain")")
		mdid_valid "$_md" || return 1
		if [ -z "$_found" ]; then
			_found=$_md
		elif [ "$_found" != "$_md" ]; then
			return 1
		fi
	done
	[ -n "$_found" ] || return 1
	mdid_reserved "$_found" && return 1
	printf '%s' "$_found"
}

# mdid_ensure GROUP SSID IFACES... -> prints the MDID for the group.
# Nothing is written here: the caller persists the value as part of the
# confirmed change plan. The origin is printed after the MDID:
#   "<mdid> existing|adopted|generated"
mdid_ensure() {
	local _grp _ssid _md _used
	_grp=$1 _ssid=$2
	shift 2
	_md=$(roam_get "$_grp.mdid")
	if mdid_valid "$_md"; then
		printf '%s existing' "$_md"
		return 0
	fi
	if _md=$(mdid_existing_for_ifaces "$_ssid" "$@"); then
		_used=$(mdid_in_use "$_grp" | tr '\n' ' ')
		if ! list_contains "$_used" "$_md"; then
			log_info "Adopting existing Mobility Domain $_md for '$_ssid'"
			printf '%s adopted' "$_md"
			return 0
		fi
		log_warn "Existing Mobility Domain $_md of '$_ssid' collides with another network - generating a new one"
	fi
	_md=$(mdid_generate "$_grp") || return 1
	printf '%s generated' "$_md"
}

mdid_store() {
	# mdid_store GROUP SSID MDID ORIGIN
	roam_cfg_init
	if [ "$ORM_DRYRUN" = 1 ]; then
		return 0
	fi
	orm_uci -q get "roamctl.$1" >/dev/null || orm_uci set "roamctl.$1=group"
	orm_uci set "roamctl.$1.ssid=$2"
	orm_uci set "roamctl.$1.mdid=$3"
	orm_uci set "roamctl.$1.mdid_origin=$4"
	orm_uci set "roamctl.$1.mdid_time=$(now)"
	orm_uci commit roamctl
}

# Manual change of the MDID of a group (validated + conflict checked).
mdid_change() {
	local _grp _new
	_grp=$1 _new=$(lower "$2")
	orm_uci -q get "roamctl.$_grp" >/dev/null || {
		log_error "Unknown roaming group '$_grp'"
		return 1
	}
	[ "$_new" = random ] && _new=$(mdid_generate "$_grp")
	mdid_valid "$_new" || {
		log_error "Invalid Mobility Domain '$2' (expected 4 hex characters)"
		return 1
	}
	mdid_reserved "$_new" && {
		log_error "Mobility Domain $_new is reserved"
		return 1
	}
	if list_contains "$(mdid_in_use "$_grp" | tr '\n' ' ')" "$_new"; then
		log_error "Mobility Domain $_new is already used by another network"
		return 1
	fi
	mdid_store "$_grp" "$(roam_get "$_grp.ssid")" "$_new" manual
	printf '%s' "$_new"
}

# Conflict report for all groups -> lines "GROUP: message"
mdid_conflicts() {
	local _seen _g _md _ssid _p _s _imd _smd _sssid
	_seen=''
	for _g in $(roam_groups); do
		_md=$(roam_get "$_g.mdid")
		_ssid=$(roam_get "$_g.ssid")
		if ! mdid_valid "$_md"; then
			echo "$_g: invalid or missing Mobility Domain '$_md'"
			continue
		fi
		for _p in $_seen; do
			[ "${_p#*:}" = "$_md" ] && echo "$_g: Mobility Domain $_md also used by group ${_p%%:*}"
		done
		_seen="$_seen $_g:$_md"
		# local interfaces of the group configured with another MDID
		for _s in $(roam_get "$_g.iface"); do
			_imd=$(lower "$(caps_get "iface.$_s.uci_mobility_domain")")
			[ "$(caps_get "iface.$_s.uci_ieee80211r")" = 1 ] || continue
			[ -n "$_imd" ] && [ "$_imd" != "$_md" ] &&
				echo "$_g: interface $_s uses Mobility Domain $_imd instead of $_md"
		done
		# other SSIDs on this AP with the same MDID
		for _s in $(caps_get iface.list); do
			[ "$(lower "$(caps_get "iface.$_s.uci_mobility_domain")")" = "$_md" ] || continue
			[ "$(caps_get "iface.$_s.ssid")" = "$_ssid" ] && continue
			echo "$_g: SSID '$(caps_get "iface.$_s.ssid")' ($_s) uses the same Mobility Domain $_md"
		done
		# foreign networks seen over the air
		while IFS=' ' read -r _smd _sssid; do
			[ "$_smd" = "$_md" ] && [ "$_sssid" != "$_ssid" ] &&
				echo "$_g: nearby network '$_sssid' advertises the same Mobility Domain $_md"
		done <<EOF
$(cat "$ORM_STATE/scan_mdids" 2>/dev/null)
EOF
	done
}

# Optional over-the-air scan for Mobility Domain elements of nearby
# networks. Scanning from an AP interface is not supported by every
# driver; failures are reported as "not tested", never as a conflict.
# Output stored in $ORM_STATE/scan_mdids: "<mdid> <ssid>".
mdid_scan() {
	local _ifn _out
	_ifn=$1
	have_cmd iw || return 2
	_out=$(iw dev "$_ifn" scan 2>/dev/null) || return 2
	printf '%s\n' "$_out" | awk '
		/^BSS / { if (ssid != "" && md != "") print md, ssid; ssid = ""; md = "" }
		/^[ \t]*SSID: / { s = $0; sub(/^[ \t]*SSID: /, "", s); ssid = s }
		/MDID/ {
			s = $0
			if (match(s, /0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)) {
				v = tolower(substr(s, RSTART + 2, 4))
				# iw prints the little endian u16; hostapd notation is byte order
				md = substr(v, 3, 2) substr(v, 1, 2)
			}
		}
		END { if (ssid != "" && md != "") print md, ssid }' | sort -u >"$ORM_STATE/scan_mdids"
	return 0
}
