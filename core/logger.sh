# shellcheck shell=sh
# OpenWrt Roaming Manager - logging and terminal output
#
# Messages go to stderr (so stdout stays machine readable) and to a log
# file in RAM (${ORM_LOG}). Optionally mirrored to syslog via logger(1).
# Secrets must never be passed to these functions; log_mask() is applied
# as a last line of defence against accidental leaks of key material.

: "${ORM_LOG:=${ORM_SYSROOT}/tmp/roamctl.log}"
: "${ORM_VERBOSE:=0}"
: "${ORM_QUIET:=0}"
: "${ORM_SYSLOG:=0}"
: "${ORM_COLOR:=auto}"

log_init_colors() {
	local _lc_use
	C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN='' C_BLD='' C_RST=''
	_lc_use=0
	case "$ORM_COLOR" in
	always) _lc_use=1 ;;
	never) _lc_use=0 ;;
	*) [ -t 2 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ] && _lc_use=1 ;;
	esac
	if [ "$_lc_use" = 1 ]; then
		C_RED=$(printf '\033[31m') C_GRN=$(printf '\033[32m')
		C_YEL=$(printf '\033[33m') C_BLU=$(printf '\033[34m')
		C_CYN=$(printf '\033[36m') C_BLD=$(printf '\033[1m')
		C_RST=$(printf '\033[0m')
	fi
}

# Replace anything that looks like FT key material (32/64 hex chars) or
# key=/psk= assignments with a placeholder.
log_mask() {
	printf '%s' "$1" | sed -E \
		-e 's/[0-9A-Fa-f]{32,}/<redacted>/g' \
		-e 's/((key|psk|passphrase|password|shared_key|iv)[=:] *)[^ ]+/\1<redacted>/g'
}

_log_file() {
	local _lf_dir
	# _log_file LEVEL MESSAGE
	[ -n "$ORM_LOG" ] || return 0
	_lf_dir=$(dirname "$ORM_LOG")
	[ -d "$_lf_dir" ] || mkdir -p "$_lf_dir" 2>/dev/null || return 0
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" "$2" >>"$ORM_LOG" 2>/dev/null
	if [ "$ORM_SYSLOG" = 1 ] && command -v logger >/dev/null 2>&1; then
		logger -t roamctl -p "daemon.$3" -- "$2" 2>/dev/null
	fi
	return 0
}

log_debug() {
	local _m
	_m=$(log_mask "$*")
	_log_file DEBUG "$_m" debug
	[ "$ORM_VERBOSE" = 1 ] && printf '%s[debug]%s %s\n' "$C_BLU" "$C_RST" "$_m" >&2
	return 0
}

log_info() {
	local _m
	_m=$(log_mask "$*")
	_log_file INFO "$_m" info
	[ "$ORM_QUIET" = 1 ] || printf '%s\n' "$_m" >&2
}

log_step() {
	local _m
	_m=$(log_mask "$*")
	_log_file STEP "$_m" info
	[ "$ORM_QUIET" = 1 ] || printf '%s==>%s %s%s%s\n' "$C_CYN" "$C_RST" "$C_BLD" "$_m" "$C_RST" >&2
}

log_ok() {
	local _m
	_m=$(log_mask "$*")
	_log_file OK "$_m" info
	[ "$ORM_QUIET" = 1 ] || printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$_m" >&2
}

log_warn() {
	local _m
	_m=$(log_mask "$*")
	_log_file WARN "$_m" warning
	printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$_m" >&2
}

log_error() {
	local _m
	_m=$(log_mask "$*")
	_log_file ERROR "$_m" err
	printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$_m" >&2
}

die() {
	log_error "$*"
	lock_release 2>/dev/null
	exit 1
}

# Progress indicator for long running steps: progress N TOTAL "label"
progress() {
	local _pg_w _pg_fill _pg_bar
	[ "$ORM_QUIET" = 1 ] && return 0
	[ -t 2 ] || return 0
	_pg_w=20
	_pg_fill=$(($1 * _pg_w / $2))
	_pg_bar=$(printf '%*s' "$_pg_fill" '' | tr ' ' '#')
	printf '\r%s[%-20s]%s %3d%% %s\033[K' "$C_CYN" "$_pg_bar" "$C_RST" $(($1 * 100 / $2)) "$3" >&2
	[ "$1" -ge "$2" ] && printf '\n' >&2
	return 0
}

# Formatting helpers for status words used in reports
status_color() {
	case "$1" in
	PASS | ENABLED | CREATED | OK) printf '%s%s%s' "$C_GRN" "$1" "$C_RST" ;;
	WARN | PARTIAL) printf '%s%s%s' "$C_YEL" "$1" "$C_RST" ;;
	FAIL | ERROR) printf '%s%s%s' "$C_RED" "$1" "$C_RST" ;;
	*) printf '%s%s%s' "$C_BLU" "$1" "$C_RST" ;;
	esac
}

banner() {
	[ "$ORM_QUIET" = 1 ] && return 0
	printf '%s\n' "==================================================" >&2
	printf '%s%*s%s\n' "$C_BLD" $(((50 + ${#1}) / 2)) "$1" "$C_RST" >&2
	printf '%s\n' "==================================================" >&2
}

log_init_colors
