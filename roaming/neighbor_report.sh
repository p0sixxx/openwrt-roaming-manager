# shellcheck shell=sh
# OpenWrt Roaming Manager - Neighbor Report Manager (802.11k)
#
# Neighbor report entries are never invented: every entry is the
# "own neighbor report" that the running hostapd of a BSS generates
# (ubus hostapd.<if> rrm_nr_get_own) from its real BSSID, operating
# class, channel and PHY type. Entries are collected from all BSSes of a
# roaming group (all bands, all APs), validated, stored in
# /etc/roamctl/neighbors.db and installed into each BSS with rrm_nr_set
# (excluding the BSS itself).
#
# DB format, $ORM_FS separated:
#   group host ifname bssid ssid nr_hex band timestamp

nr_db() {
	printf '%s/neighbors.db' "$ORM_ETC"
}

# nr_own IFNAME -> "bssid<FS>ssid<FS>hex"
nr_own() {
	local _j _b _ss _h
	_j=$(ubus call "hostapd.$1" rrm_nr_get_own 2>/dev/null) || return 1
	_b=$(json_get "$_j" value.0)
	_ss=$(json_get "$_j" value.1)
	_h=$(json_get "$_j" value.2)
	[ -n "$_b" ] && [ -n "$_h" ] || return 1
	printf '%s%s%s%s%s\n' "$(lower "$_b")" "$ORM_FS" "$_ss" "$ORM_FS" "$(lower "$_h")"
}

# Decode a neighbor report element body (hex) -> "bssid opclass channel phytype bssinfo"
nr_decode() {
	local _h
	_h=$(lower "$1")
	printf '%s' "$_h" | grep -Eq '^([0-9a-f]{2}){13,}$' || return 1
	printf '%s' "$_h" | awk '{
		bssid = substr($0,1,2) ":" substr($0,3,2) ":" substr($0,5,2) ":" substr($0,7,2) ":" substr($0,9,2) ":" substr($0,11,2)
		info = substr($0,19,2) substr($0,17,2) substr($0,15,2) substr($0,13,2)
		printf "%s %d %d %d %s\n", bssid, hex(substr($0,21,2)), hex(substr($0,23,2)), hex(substr($0,25,2)), info
	}
	function hex(s,   i, c, v) {
		v = 0
		for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; v = v * 16 + c }
		return v
	}'
}

nr_phy_name() {
	case "$1" in
	2) printf DSSS ;; 4) printf OFDM ;; 6) printf ERP ;; 7) printf HT ;;
	9) printf VHT ;; 14) printf HE ;; 15) printf EHT ;; *) printf "type-%s" "$1" ;;
	esac
}

nr_opclass_band() {
	local _oc
	_oc=$1
	if [ "$_oc" -ge 81 ] && [ "$_oc" -le 84 ]; then printf 2g
	elif [ "$_oc" -ge 115 ] && [ "$_oc" -le 130 ]; then printf 5g
	elif [ "$_oc" -ge 131 ] && [ "$_oc" -le 137 ]; then printf 6g
	else printf unknown; fi
}

# nr_validate BSSID HEX -> 0 if the element is consistent with the BSSID
nr_validate() {
	local _dec
	_dec=$(nr_decode "$2") || return 1
	# shellcheck disable=SC2086
	set -- "$1" $_dec
	[ "$(lower "$1")" = "$2" ] || return 1
	[ "$4" -ge 1 ] 2>/dev/null || return 1
	[ "$(nr_opclass_band "$3")" != unknown ] || return 1
	return 0
}

# Collect own reports of local group members and merge them into the DB.
# nr_collect_local HOSTLABEL -> number of valid entries collected
nr_collect_local() {
	local _host _db _tmp _cnt _g _gssid _s _if _own _b _ss _h _oc
	uci_cache_warm
	_host=${1:-local}
	_db=$(nr_db)
	_tmp="$ORM_STATE/nr.local.$$"
	ensure_dir "$ORM_STATE"
	: >"$_tmp"
	_cnt=0
	for _g in $(roam_groups); do
		_gssid=$(roam_get "$_g.ssid")
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			[ -n "$_if" ] || continue
			_own=$(nr_own "$_if") || {
				log_debug "no own neighbor report from $_if"
				continue
			}
			_b=$(printf '%s' "$_own" | cut -d"$ORM_FS" -f1)
			_ss=$(printf '%s' "$_own" | cut -d"$ORM_FS" -f2)
			_h=$(printf '%s' "$_own" | cut -d"$ORM_FS" -f3)
			if ! nr_validate "$_b" "$_h"; then
				log_warn "Ignoring inconsistent neighbor report from $_if"
				continue
			fi
			if [ "$_ss" != "$_gssid" ]; then
				log_warn "$_if reports SSID '$_ss', expected '$_gssid' - ignored"
				continue
			fi
			_oc=$(nr_decode "$_h" | cut -d' ' -f2)
			printf '%s\n' "$_g$ORM_FS$_host$ORM_FS$_if$ORM_FS$_b$ORM_FS$_ss$ORM_FS$_h$ORM_FS$(nr_opclass_band "$_oc")$ORM_FS$(now)" >>"$_tmp"
			_cnt=$((_cnt + 1))
		done
	done
	nr_db_merge_host "$_host" <"$_tmp"
	rm -f "$_tmp"
	printf '%s' "$_cnt"
}

# Replace all entries of HOST in the DB with stdin entries.
nr_db_merge_host() {
	local _db
	_db=$(nr_db)
	ensure_dir "$ORM_ETC" 0700
	{
		[ -f "$_db" ] && awk -F "$ORM_FS" -v h="$1" '$2 != h' "$_db"
		cat
	} | sort -u | atomic_write "$_db" 600
}

# Replace the whole DB (multi-AP push from controller), validating input.
nr_db_import() {
	local _tmp _line _b _h
	_tmp="$ORM_STATE/nr.import.$$"
	ensure_dir "$ORM_STATE"
	: >"$_tmp"
	while IFS= read -r _line; do
		_b=$(printf '%s' "$_line" | cut -d"$ORM_FS" -f4)
		_h=$(printf '%s' "$_line" | cut -d"$ORM_FS" -f6)
		if is_mac "$_b" && nr_validate "$_b" "$_h"; then
			printf '%s\n' "$_line" >>"$_tmp"
		else
			log_warn "Rejected invalid neighbor entry for $_b"
		fi
	done
	sort -u "$_tmp" | atomic_write "$(nr_db)" 600
	rm -f "$_tmp"
}

# JSON list of neighbors for a BSS: all entries of GROUP except own BSSID
nr_json_for() {
	local _first _g _h _if _b _ss _hex _band _ts
	# nr_json_for GROUP OWN_BSSID
	_first=1
	printf '{"list":['
	awk -F "$ORM_FS" -v g="$1" -v b="$2" '$1 == g && $4 != b' "$(nr_db)" 2>/dev/null |
		while IFS="$ORM_FS" read -r _g _h _if _b _ss _hex _band _ts; do
			[ "$_first" = 1 ] || printf ','
			_first=0
			printf '["%s","%s","%s"]' "$_b" "$(json_escape "$_ss")" "$_hex"
		done
	printf ']}'
}

nr_count_for() {
	awk -F "$ORM_FS" -v g="$1" -v b="$2" '$1 == g && $4 != b' "$(nr_db)" 2>/dev/null | wc -l | tr -d ' '
}

# Install neighbor lists into every local BSS of every group.
nr_apply_local() {
	local _rc _g _s _if _b _js
	uci_cache_warm
	_rc=0
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			_b=$(caps_get "iface.$_s.bssid")
			[ -n "$_if" ] && [ -n "$_b" ] || continue
			[ "$(caps_get "iface.$_s.hostapd")" = 1 ] || continue
			_js=$(nr_json_for "$_g" "$_b")
			if ubus call "hostapd.$_if" rrm_nr_set "$_js" >/dev/null 2>&1; then
				log_debug "neighbor list installed on $_if ($(nr_count_for "$_g" "$_b") entries)"
			else
				log_warn "rrm_nr_set failed on $_if"
				_rc=1
			fi
		done
	done
	return $_rc
}

# Number of entries hostapd currently holds for IFNAME
nr_installed_count() {
	local _j
	_j=$(ubus call "hostapd.$1" rrm_nr_list 2>/dev/null) || {
		echo -1
		return 1
	}
	json_glob "$_j" 'list.*.0' | grep -c :
}

# Self-healing check used by the daemon: re-install lists that hostapd
# lost (hostapd restart, wifi reload) and refresh local entries when a
# BSS changed (channel switch -> new operating class/channel).
nr_maintain() {
	local _changed _before _after _g _s _if _b _want _have
	uci_cache_warm
	_changed=0
	_before=$(awk -F "$ORM_FS" '$2 == "local" {print $4, $6}' "$(nr_db)" 2>/dev/null | sort)
	nr_collect_local local >/dev/null
	_after=$(awk -F "$ORM_FS" '$2 == "local" {print $4, $6}' "$(nr_db)" 2>/dev/null | sort)
	[ "$_before" != "$_after" ] && _changed=1
	for _g in $(roam_groups); do
		for _s in $(roam_get "$_g.iface"); do
			_if=$(caps_get "iface.$_s.ifname")
			_b=$(caps_get "iface.$_s.bssid")
			[ -n "$_if" ] || continue
			_want=$(nr_count_for "$_g" "$_b")
			_have=$(nr_installed_count "$_if")
			[ "$_have" != "$_want" ] && _changed=1
		done
	done
	if [ "$_changed" = 1 ]; then
		log_debug "neighbor reports out of date - reinstalling"
		nr_apply_local
	fi
	return 0
}

# Human readable dump of the DB
nr_show() {
	local _g _h _if _b _ss _hex _band _ts
	[ -s "$(nr_db)" ] || {
		echo "No neighbor reports collected."
		return 0
	}
	printf '%-10s %-12s %-14s %-17s %-5s %-4s %-4s %s\n' GROUP HOST IFACE BSSID BAND OPCL CH PHY
	while IFS="$ORM_FS" read -r _g _h _if _b _ss _hex _band _ts; do
		# shellcheck disable=SC2046
		set -- $(nr_decode "$_hex")
		printf '%-10s %-12s %-14s %-17s %-5s %-4s %-4s %s\n' "$_g" "$_h" "$_if" "$_b" "$_band" "$2" "$3" "$(nr_phy_name "$4")"
	done <"$(nr_db)"
}

# Whether roamctl should manage neighbor reports itself (static mode) or
# leave them to the steering backend (usteer/DAWN distribute them).
nr_effective_mode() {
	local _m _be
	_m=$(roam_get global.nr_mode auto)
	case "$_m" in
	static | backend | off) printf '%s' "$_m" ;;
	*)
		_be=$(roam_get global.steering_backend_active none)
		if [ "$_be" != none ] && steer_call "$_be" handles_nr; then
			printf backend
		else
			printf static
		fi
		;;
	esac
}
