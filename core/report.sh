# shellcheck shell=sh
# OpenWrt Roaming Manager - test/diagnostic result collection
#
# Statuses: PASS, WARN, FAIL, "NOT SUPPORTED", "NOT TESTED"
# Records: CATEGORY<FS>NAME<FS>STATUS<FS>MESSAGE in $ORM_STATE/report

report_file() {
	printf '%s/report' "$ORM_STATE"
}

report_reset() {
	ensure_dir "$ORM_STATE"
	: >"$(report_file)"
}

report_add() {
	# report_add CATEGORY NAME STATUS MESSAGE
	case "$3" in
	PASS | WARN | FAIL | "NOT SUPPORTED" | "NOT TESTED") ;;
	*) log_error "internal: invalid status '$3'"; return 1 ;;
	esac
	printf '%s%s%s%s%s%s%s\n' "$1" "$ORM_FS" "$2" "$ORM_FS" "$3" "$ORM_FS" "$(printf '%s' "$4" | tr '\n' ' ')" >>"$(report_file)"
	case "$3" in
	PASS) log_debug "[$1] $2: $4" ;;
	WARN) log_debug "[$1] $2: WARN $4" ;;
	FAIL) log_debug "[$1] $2: FAIL $4" ;;
	esac
	return 0
}

# Worst status of a category: FAIL > WARN > PASS > NOT TESTED > NOT SUPPORTED
report_category_status() {
	awk -F "$ORM_FS" -v c="$1" '
		$1 == c { s[$3] = 1; any = 1 }
		END {
			if (!any) { print "NOT TESTED"; exit }
			if (s["FAIL"]) print "FAIL"
			else if (s["WARN"]) print "WARN"
			else if (s["PASS"]) print "PASS"
			else if (s["NOT TESTED"]) print "NOT TESTED"
			else print "NOT SUPPORTED"
		}' "$(report_file)" 2>/dev/null
}

report_has_fail() {
	awk -F "$ORM_FS" '$3 == "FAIL" { f = 1 } END { exit !f }' "$(report_file)" 2>/dev/null
}

report_count() {
	awk -F "$ORM_FS" -v s="$1" '$3 == s { n++ } END { print n + 0 }' "$(report_file)" 2>/dev/null
}

# Detailed listing with explanation of each status
report_print_details() {
	local _cat _seen _c _n _st _msg _f
	_f=$(report_file)
	[ -s "$_f" ] || return 0
	# fixed category order, then anything else in order of appearance
	_seen=''
	for _cat in hardware packages config hostapd 11r 11k 11v steering multiap connectivity clients live \
		$(cut -d"$ORM_FS" -f1 "$_f" | awk '!s[$0]++'); do
		list_contains "$_seen" "$_cat" && continue
		_seen="$_seen $_cat"
		grep -q "^${_cat}${ORM_FS}" "$_f" || continue
		printf '\n%s%s%s\n' "$C_BLD" "$(report_category_title "$_cat")" "$C_RST"
		while IFS="$ORM_FS" read -r _c _n _st _msg; do
			[ "$_c" = "$_cat" ] || continue
			printf '  %-15s %-28s %s\n' "$(status_color "$_st")" "$_n" "$_msg"
		done <"$_f"
	done
	printf '\n'
}

report_category_title() {
	case "$1" in
	hardware) printf 'Hardware compatibility' ;;
	packages) printf 'Package integrity' ;;
	config) printf 'Configuration validation' ;;
	hostapd) printf 'hostapd' ;;
	11k) printf '802.11k (RRM / neighbor reports)' ;;
	11v) printf '802.11v (BSS transition management)' ;;
	11r) printf '802.11r (fast BSS transition)' ;;
	steering) printf 'Steering' ;;
	connectivity) printf 'Connectivity' ;;
	multiap) printf 'Multi-AP' ;;
	live) printf 'Live roaming' ;;
	clients) printf 'Client capabilities' ;;
	*) printf '%s' "$1" ;;
	esac
}

# Machine readable output (for multi-AP agent / CI)
report_print_raw() {
	cat "$(report_file)" 2>/dev/null | tr "$ORM_FS" '|'
}
