# shellcheck shell=sh
# OpenWrt Roaming Manager - UCI configuration engine
#
# * Builds a change plan (nothing is written until it is confirmed)
# * Records the original value of every option it touches in a journal so
#   "roamctl uninstall" can revert exactly what roamctl changed
# * Analyses wireless interfaces, detects roaming groups and conflicts
#
# Plan record format (one per line, fields separated by $ORM_FS):
#   set  <path> <value>
#   del  <path>
#   list <path> <v1>|<v2>...     (values joined with $ORM_FS after 3rd field)

ORM_PLAN=''
ORM_CHANGED_CONFIGS=''

journal_file() {
	printf '%s/journal' "$ORM_ETC"
}

# Print list values of an UCI option, one per line (handles quoting).
uci_get_list() {
	orm_uci -q show "$1" 2>/dev/null | awk '
	{
		s = $0; sub(/^[^=]*=/, "", s)
		out = ""; inq = 0; tok = ""; started = 0
		n = length(s)
		for (i = 1; i <= n; i++) {
			c = substr(s, i, 1)
			if (inq) {
				if (c == "\047") { inq = 0 } else { tok = tok c }
			} else if (c == "\047") {
				inq = 1; started = 1
			} else if (c == "\\" && substr(s, i + 1, 1) == "\047") {
				tok = tok "\047"; i++
			} else if (c == " ") {
				if (started) { print tok; tok = ""; started = 0 }
			} else { tok = tok c; started = 1 }
		}
		if (started) print tok
	}'
}

uci_is_list() {
	local _ul _cfg _rest _sec _opt
	_ul=$(orm_uci -q show "$1" 2>/dev/null) || return 1
	# lists are rendered as 'a' 'b' ; a single list item cannot be told
	# apart from an option through "show", so check the raw config file.
	_cfg=${1%%.*}
	_rest=${1#*.}
	_sec=${_rest%%.*}
	_opt=${_rest#*.}
	case "$_ul" in
	*"' '"*) return 0 ;;
	esac
	awk -v sec="$_sec" -v opt="$_opt" '
		$1 == "config" { cur = $3; gsub(/\047|"/, "", cur) }
		$1 == "list" && cur == sec && $2 == opt { found = 1 }
		END { exit !found }' "$ORM_UCI_CONFDIR/$_cfg" 2>/dev/null
}

journal_has() {
	grep -q "^uci${ORM_FS}$1${ORM_FS}" "$(journal_file)" 2>/dev/null
}

# Store the original value of PATH (once).
journal_add_uci() {
	local _jv
	journal_has "$1" && return 0
	ensure_dir "$ORM_ETC" 0700
	if uci_is_list "$1"; then
		_jv="L:$(uci_get_list "$1" | tr '\n' "$ORM_FS")"
	elif _jv=$(orm_uci -q get "$1"); then
		_jv="V:$_jv"
	else
		_jv="U:"
	fi
	printf 'uci%s%s%s%s\n' "$ORM_FS" "$1" "$ORM_FS" "$_jv" >>"$(journal_file)"
	chmod 600 "$(journal_file)"
}

journal_add_pkg() {
	ensure_dir "$ORM_ETC" 0700
	grep -qx "pkg${ORM_FS}$1" "$(journal_file)" 2>/dev/null ||
		printf 'pkg%s%s\n' "$ORM_FS" "$1" >>"$(journal_file)"
}

journal_add_svc() {
	# journal_add_svc NAME WAS_ENABLED(0/1)
	ensure_dir "$ORM_ETC" 0700
	grep -q "^svc${ORM_FS}$1${ORM_FS}" "$(journal_file)" 2>/dev/null ||
		printf 'svc%s%s%s%s\n' "$ORM_FS" "$1" "$ORM_FS" "$2" >>"$(journal_file)"
}

_cfg_mark_changed() {
	local _c
	_c=${1%%.*}
	list_contains "$ORM_CHANGED_CONFIGS" "$_c" || ORM_CHANGED_CONFIGS="$ORM_CHANGED_CONFIGS $_c"
}

# ------------------------------------------------------------------ plan
plan_reset() {
	ORM_PLAN=''
}

_plan_add() {
	ORM_PLAN="${ORM_PLAN}$1
"
}

plan_set() {
	local _cur
	# plan_set PATH VALUE - skipped if the value is already set
	_cur=$(orm_uci -q get "$1") && [ "$_cur" = "$2" ] && ! uci_is_list "$1" && return 0
	_plan_add "set${ORM_FS}$1${ORM_FS}$2"
}

plan_del() {
	orm_uci -q get "$1" >/dev/null 2>&1 || return 0
	_plan_add "del${ORM_FS}$1"
}

plan_list() {
	local _pl_path _pl_new _v _pl_cur _pl_rec
	# plan_list PATH VALUE... - replace list content
	_pl_path=$1
	shift
	_pl_new=$(for _v in "$@"; do printf '%s\n' "$_v"; done)
	_pl_cur=$(uci_get_list "$_pl_path")
	[ "$_pl_new" = "$_pl_cur" ] && uci_is_list "$_pl_path" && return 0
	_pl_rec="list${ORM_FS}${_pl_path}"
	for _v in "$@"; do
		_pl_rec="${_pl_rec}${ORM_FS}${_v}"
	done
	_plan_add "$_pl_rec"
}

plan_count() {
	printf '%s' "$ORM_PLAN" | grep -c .
}

# Print the plan for the user; secret values are masked.
plan_show() {
	local _op _path _rest
	if [ -z "$ORM_PLAN" ]; then
		printf '  (no configuration changes required)\n'
		return 0
	fi
	printf '%s' "$ORM_PLAN" | while IFS="$ORM_FS" read -r _op _path _rest; do
		case "$_path" in
		*.r0kh | *.r1kh | *.shared_key | *.iv | *.key) _rest='<secret>' ;;
		esac
		_rest=$(printf '%s' "$_rest" | tr "$ORM_FS" ' ')
		case "$_op" in
		set) printf '  %s+%s %s = %s\n' "$C_GRN" "$C_RST" "$_path" "$_rest" ;;
		del) printf '  %s-%s %s\n' "$C_RED" "$C_RST" "$_path" ;;
		list) printf '  %s+%s %s = [%s]\n' "$C_GRN" "$C_RST" "$_path" "$_rest" ;;
		esac
	done
}

# Apply plan to UCI (uncommitted), journalling original values.
plan_apply() {
	local _pa_tmp _pa_rc _op _path _rest _old_ifs _v
	_pa_tmp="${ORM_STATE}/plan.$$"
	ensure_dir "$ORM_STATE"
	printf '%s' "$ORM_PLAN" >"$_pa_tmp"
	_pa_rc=0
	while IFS="$ORM_FS" read -r _op _path _rest; do
		[ -n "$_op" ] || continue
		journal_add_uci "$_path"
		_cfg_mark_changed "$_path"
		case "$_op" in
		set) orm_uci set "$_path=$_rest" || _pa_rc=1 ;;
		del) orm_uci -q delete "$_path" ;;
		list)
			orm_uci -q delete "$_path"
			_old_ifs=$IFS
			IFS=$ORM_FS
			# shellcheck disable=SC2086
			set -- $_rest
			IFS=$_old_ifs
			for _v in "$@"; do
				orm_uci add_list "$_path=$_v" || _pa_rc=1
			done
			;;
		esac
	done <"$_pa_tmp"
	rm -f "$_pa_tmp"
	return $_pa_rc
}

cfg_commit() {
	local _c
	for _c in $ORM_CHANGED_CONFIGS; do
		orm_uci commit "$_c" || return 1
	done
	return 0
}

cfg_revert() {
	local _c
	for _c in $ORM_CHANGED_CONFIGS; do
		orm_uci revert "$_c" 2>/dev/null
	done
	ORM_CHANGED_CONFIGS=''
}

# Revert every option recorded in the journal to its original value.
journal_restore_uci() {
	local _jf _jr_cfgs _type _path _val _li _c
	_jf=$(journal_file)
	[ -f "$_jf" ] || return 0
	_jr_cfgs=''
	while IFS="$ORM_FS" read -r _type _path _val; do
		[ "$_type" = uci ] || continue
		orm_uci -q get "${_path%.*}" >/dev/null 2>&1 || continue
		case "$_val" in
		U:*) orm_uci -q delete "$_path" ;;
		V:*) orm_uci set "$_path=${_val#V:}" ;;
		L:*)
			orm_uci -q delete "$_path"
			printf '%s' "${_val#L:}" | tr "$ORM_FS" '\n' | while IFS= read -r _li; do
				[ -n "$_li" ] && orm_uci add_list "$_path=$_li"
			done
			;;
		esac
		_c=${_path%%.*}
		list_contains "$_jr_cfgs" "$_c" || _jr_cfgs="$_jr_cfgs $_c"
	done <"$_jf"
	for _c in $_jr_cfgs; do
		orm_uci commit "$_c"
	done
}

# ------------------------------------------------------- group analysis
group_id_for_ssid() {
	printf 'g_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"
}

# Candidate interfaces for automatic roaming management.
# ORM_INCLUDE / ORM_EXCLUDE: space separated section names from CLI.
cfg_candidate_ifaces() {
	local _s
	for _s in $(caps_get iface.list); do
		[ "$(caps_get "iface.$_s.eligible")" = 1 ] || continue
		list_contains "${ORM_EXCLUDE:-}" "$_s" && continue
		if [ "$(caps_get "iface.$_s.special")" = 1 ] && ! list_contains "${ORM_INCLUDE:-}" "$_s"; then
			continue
		fi
		case "$(caps_get "iface.$_s.security")" in
		open | owe | wep | unknown)
			list_contains "${ORM_INCLUDE:-}" "$_s" || continue ;;
		esac
		printf '%s\n' "$_s"
	done
}

# Group candidate interfaces by SSID, verify that the security settings
# are identical and emit:  GROUPID<FS>SSID<FS>iface1 iface2...
# Conflicts are recorded in caps (conflict.N=...) and the conflicting
# SSID is not grouped automatically.
cfg_detect_groups() {
	local _cands _ssids _s _nconf _ssid _members _sec _fp _bad _isec _ifp
	_cands=$(cfg_candidate_ifaces)
	_ssids=$(for _s in $_cands; do caps_get "iface.$_s.ssid"; echo; done | sort -u)
	_nconf=0
	printf '%s\n' "$_ssids" | while IFS= read -r _ssid; do
		[ -n "$_ssid" ] || continue
		_members='' _sec='' _fp='' _bad=''
		for _s in $_cands; do
			[ "$(caps_get "iface.$_s.ssid")" = "$_ssid" ] || continue
			_isec=$(caps_get "iface.$_s.security")
			_ifp=$(caps_get "iface.$_s.keyfp")
			if [ -z "$_members" ]; then
				_sec=$_isec _fp=$_ifp
			else
				[ "$_isec" != "$_sec" ] && _bad="security mode differs ($_sec vs $_isec on $_s)"
				[ "$_ifp" != "$_fp" ] && _bad="passphrase differs between interfaces ($_s)"
			fi
			_members="$_members $_s"
		done
		if [ -n "$_bad" ]; then
			_nconf=$((_nconf + 1))
			caps_set "conflict.local.$(group_id_for_ssid "$_ssid")" "SSID '$_ssid': $_bad"
			continue
		fi
		printf '%s%s%s%s%s\n' "$(group_id_for_ssid "$_ssid")" "$ORM_FS" "$_ssid" "$ORM_FS" "${_members# }"
	done
}

cfg_conflicts() {
	grep '^conflict\.' "$(caps_file)" 2>/dev/null | sed 's/^[^=]*=//'
}

# ------------------------------------------------- roamctl own config
roam_cfg_init() {
	local _rc
	_rc=$ORM_UCI_CONFDIR/roamctl
	if [ ! -f "$_rc" ]; then
		ensure_dir "$ORM_UCI_CONFDIR"
		atomic_write "$_rc" <<'EOF'

config global 'global'
	option mode 'standalone'
	option steering_backend 'auto'
	option profile 'balanced'
	option nr_mode 'auto'
	option backup_keep '10'
	option watchdog_timeout '180'

EOF
	fi
}

roam_get() {
	# roam_get SECTION.OPTION [DEFAULT]
	orm_uci -q get "roamctl.$1" || {
		printf '%s' "${2:-}"
		return 1
	}
}

roam_groups() {
	orm_uci -X show roamctl 2>/dev/null | sed -n 's/^roamctl\.\([^.=]*\)=group$/\1/p'
}
