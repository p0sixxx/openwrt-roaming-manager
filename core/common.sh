# shellcheck shell=sh
# OpenWrt Roaming Manager - common helpers
#
# Paths, atomic file writes, locking, key/value state storage,
# secure random generation and JSON string escaping.
#
# Every filesystem path that refers to the managed system goes through
# $ORM_SYSROOT so the whole tool can be exercised against a mock root
# filesystem in the test-suite. On a real router ORM_SYSROOT is empty.

ORM_VERSION="1.0.0"

: "${ORM_SYSROOT:=}"
: "${ORM_ETC:=${ORM_SYSROOT}/etc/roamctl}"
: "${ORM_STATE:=${ORM_SYSROOT}/var/run/roamctl}"
: "${ORM_BACKUP_DIR:=${ORM_ETC}/backups}"
: "${ORM_KEY_DIR:=${ORM_ETC}/keys}"
: "${ORM_UCI_CONFDIR:=${ORM_SYSROOT}/etc/config}"
: "${ORM_YES:=0}"
: "${ORM_DRYRUN:=0}"

# Field separator used in internal records. Unit separator (0x1f) never
# appears in SSIDs entered through LuCI/UCI in practice, but we still
# reject it explicitly where user data is parsed.
ORM_FS=$(printf '\037')

# sysroot path helper: orm_path /etc/openwrt_release
orm_path() {
	printf '%s%s' "$ORM_SYSROOT" "$1"
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

# uci wrapper honouring the (test) config directory. Every modifying call
# bumps a generation counter so cached "uci show" snapshots (see
# uci_cached_get) are invalidated in this and in every other process.
orm_uci() {
	local _ua _uw _urc
	_uw=0
	for _ua in "$@"; do
		case "$_ua" in
		-*) continue ;;
		set | add | add_list | del_list | delete | commit | revert | rename | reorder | import | batch) _uw=1 ;;
		esac
		break
	done
	if [ -n "$ORM_SYSROOT" ]; then
		uci -c "$ORM_UCI_CONFDIR" "$@"
	else
		uci "$@"
	fi
	_urc=$?
	[ "$_uw" = 1 ] && uci_gen_bump
	return $_urc
}

# ------------------------------------------------------- cached uci reads
# One "uci -X show <config>" snapshot replaces dozens of "uci get" calls
# (each a process - expensive on MT7628/MT7621 class MIPS CPUs). The
# snapshot is reused while the generation counter is unchanged.
ORM_NL='
'
ORM_WL_SHOW='' ORM_WL_GEN='' ORM_RC_SHOW='' ORM_RC_GEN=''

uci_gen_now() {
	ORM_UCI_GEN=0
	[ -r "$ORM_STATE/uci.gen" ] && read -r ORM_UCI_GEN <"$ORM_STATE/uci.gen"
	case "$ORM_UCI_GEN" in "" | *[!0-9]*) ORM_UCI_GEN=0 ;; esac
}

uci_gen_bump() {
	uci_gen_now
	echo "$((ORM_UCI_GEN + 1))" >"$ORM_STATE/uci.gen" 2>/dev/null
	ORM_WL_SHOW='' ORM_RC_SHOW=''
}

# Load both snapshots in the current shell (call before loops whose
# bodies read through $(...) - a subshell cannot fill the parent's cache)
uci_cache_warm() {
	uci_cache_ensure wireless
	uci_cache_ensure roamctl
}

uci_cache_drop() {
	ORM_WL_SHOW='' ORM_RC_SHOW=''
}

# uci_cache_ensure wireless|roamctl -> refreshes ORM_WL_SHOW / ORM_RC_SHOW
uci_cache_ensure() {
	uci_gen_now
	case "$1" in
	wireless)
		if [ -z "$ORM_WL_SHOW" ] || [ "$ORM_WL_GEN" != "$ORM_UCI_GEN" ]; then
			ORM_WL_SHOW="$ORM_NL$(orm_uci -X show wireless 2>/dev/null)$ORM_NL"
			ORM_WL_GEN=$ORM_UCI_GEN
		fi
		;;
	roamctl)
		if [ -z "$ORM_RC_SHOW" ] || [ "$ORM_RC_GEN" != "$ORM_UCI_GEN" ]; then
			ORM_RC_SHOW="$ORM_NL$(orm_uci -X show roamctl 2>/dev/null)$ORM_NL"
			ORM_RC_GEN=$ORM_UCI_GEN
		fi
		;;
	esac
}

# uci_cached_v CONFIG SECTION OPTION [DEFAULT] -> sets UCI_V (no output,
# no subshell: use in loops). Returns 1 if the option does not exist.
# Same value as "uci -q get"; lists are returned space separated. Values
# whose quoting cannot be decoded unambiguously fall back to uci.
uci_cached_v() {
	local _cs _raw
	UCI_V=${4:-}
	case "$1" in
	wireless) uci_cache_ensure wireless; _cs=$ORM_WL_SHOW ;;
	roamctl) uci_cache_ensure roamctl; _cs=$ORM_RC_SHOW ;;
	*)
		UCI_V=$(orm_uci -q get "$1.$2.$3") && return 0
		UCI_V=${4:-}
		return 1
		;;
	esac
	case "$_cs" in
	*"${ORM_NL}$1.$2.$3="*) ;;
	*) return 1 ;;
	esac
	_raw=${_cs#*"${ORM_NL}$1.$2.$3="}
	_raw=${_raw%%"$ORM_NL"*}
	case "$_raw" in
	*"'\\''"*"' '"* | *"' '"*"'\\''"* | [!\']* | *[!\'])
		# escaped quotes inside a list or unexpected format: ask uci
		UCI_V=$(orm_uci -q get "$1.$2.$3") && return 0
		UCI_V=${4:-}
		return 1
		;;
	esac
	_raw=${_raw#\'}
	_raw=${_raw%\'}
	UCI_V=''
	while :; do
		case "$_raw" in
		*"'\\''"*)
			UCI_V="$UCI_V${_raw%%"'\\''"*}'"
			_raw=${_raw#*"'\\''"}
			;;
		*"' '"*)
			UCI_V="$UCI_V${_raw%%"' '"*} "
			_raw=${_raw#*"' '"}
			;;
		*)
			UCI_V="$UCI_V$_raw"
			break
			;;
		esac
	done
	return 0
}

# uci_cached_get CONFIG SECTION OPTION [DEFAULT] -> prints the value
uci_cached_get() {
	local _rc
	uci_cached_v "$@"
	_rc=$?
	printf '%s' "$UCI_V"
	return $_rc
}

ensure_dir() {
	# ensure_dir DIR [MODE]
	[ -d "$1" ] || mkdir -p "$1" || return 1
	[ -n "${2:-}" ] && chmod "$2" "$1"
	return 0
}

# atomic_write FILE [MODE] < content
# Writes stdin to a temporary file in the same directory and renames it
# over FILE, so readers never observe a partially written file.
atomic_write() {
	local _aw_file _aw_mode _aw_dir _aw_tmp
	_aw_file=$1
	_aw_mode=${2:-}
	_aw_dir=$(dirname "$_aw_file")
	ensure_dir "$_aw_dir" || return 1
	_aw_tmp="${_aw_dir}/.$(basename "$_aw_file").tmp.$$"
	(
		[ -n "$_aw_mode" ] && umask 077
		cat >"$_aw_tmp"
	) || {
		rm -f "$_aw_tmp"
		return 1
	}
	[ -n "$_aw_mode" ] && chmod "$_aw_mode" "$_aw_tmp"
	sync_file "$_aw_tmp"
	mv -f "$_aw_tmp" "$_aw_file" || {
		rm -f "$_aw_tmp"
		return 1
	}
	return 0
}

# Flush a file to storage where possible (BusyBox sync may accept files).
sync_file() {
	sync "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------- locking
# A mkdir based lock is atomic on every POSIX filesystem (including the
# tmpfs used for /var/run on OpenWrt). Stale locks left by a crashed run
# are detected through the stored PID.
ORM_LOCK_HELD=0

lock_acquire() {
	local _lk_dir _lk_try _lk_pid
	_lk_dir="${ORM_STATE}/lock"
	ensure_dir "$ORM_STATE" 0755 || return 1
	_lk_try=0
	while ! mkdir "$_lk_dir" 2>/dev/null; do
		_lk_pid=$(cat "$_lk_dir/pid" 2>/dev/null)
		if [ -n "$_lk_pid" ] && ! kill -0 "$_lk_pid" 2>/dev/null; then
			log_warn "Removing stale lock held by dead process $_lk_pid"
			rm -rf "$_lk_dir"
			continue
		fi
		_lk_try=$((_lk_try + 1))
		if [ "$_lk_try" -ge "${ORM_LOCK_WAIT:-10}" ]; then
			log_error "Another roamctl instance is running (pid ${_lk_pid:-unknown})"
			return 1
		fi
		sleep 1
	done
	echo "$$" >"$_lk_dir/pid"
	ORM_LOCK_HELD=1
	return 0
}

lock_release() {
	[ "$ORM_LOCK_HELD" = 1 ] || return 0
	rm -rf "${ORM_STATE}/lock"
	ORM_LOCK_HELD=0
}

# ------------------------------------------------------------- key/value
# Simple line based "key=value" store. Keys are [A-Za-z0-9_.-]; values
# are stored verbatim up to end of line (newlines are stripped).
kv_set() {
	local _kv_file _kv_key _kv_val
	# kv_set FILE KEY VALUE
	_kv_file=$1 _kv_key=$2
	_kv_val=$(printf '%s' "$3" | tr -d '\n')
	ensure_dir "$(dirname "$_kv_file")" || return 1
	touch "$_kv_file"
	{
		grep -v "^${_kv_key}=" "$_kv_file" 2>/dev/null
		printf '%s=%s\n' "$_kv_key" "$_kv_val"
	} | atomic_write "$_kv_file"
}

kv_get() {
	local _kv_line
	# kv_get FILE KEY [DEFAULT]
	_kv_line=$(grep -m1 "^${2}=" "$1" 2>/dev/null) || {
		printf '%s' "${3:-}"
		return 1
	}
	printf '%s' "${_kv_line#*=}"
}

# ------------------------------------------------------------ randomness
# Cryptographically secure random bytes as lowercase hex, read from the
# kernel CSPRNG (/dev/urandom is backed by getrandom() on Linux >= 4.8).
# $RANDOM is intentionally never used.
random_hex() {
	local _rh_src _rh
	# random_hex NBYTES
	_rh_src=${ORM_URANDOM:-/dev/urandom}
	[ -r "$_rh_src" ] || return 1
	# hexdump is part of every OpenWrt BusyBox; od is not always built in
	if have_cmd hexdump; then
		_rh=$(hexdump -v -n "$1" -e '1/1 "%02x"' "$_rh_src" 2>/dev/null)
	else
		_rh=$(od -An -tx1 -N"$1" "$_rh_src" 2>/dev/null | tr -d ' \n')
	fi
	[ "${#_rh}" -eq $(($1 * 2)) ] || return 1
	printf '%s' "$_rh"
}

# -------------------------------------------------------------- strings
# Escape a string for inclusion inside a JSON string literal.
json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' |
		tr -d '\000-\010\013\014\016-\037' | awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

# Validate a MAC address (aa:bb:cc:dd:ee:ff).
is_mac() {
	printf '%s' "$1" | grep -Eq '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$'
}

is_uint() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# Validate a host name / IPv4 / IPv6 literal supplied by the user so it
# can never be interpreted as an ssh option or shell metacharacter.
is_safe_host() {
	case "$1" in
	-* | '') return 1 ;;
	esac
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:%-]+$'
}

lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

upper() {
	printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Short non-reversible fingerprint of secret material. Used to compare
# passphrases/keys between access points without transferring them.
secret_fingerprint() {
	printf '%s' "$1" | sha256sum | cut -c1-16
}

now() {
	date +%s
}

# confirm "Question" -> returns 0 on yes. Honors ORM_YES.
confirm() {
	local _cf_ans
	[ "$ORM_YES" = 1 ] && return 0
	if [ ! -t 0 ] && [ -z "${ORM_FORCE_INTERACTIVE:-}" ]; then
		log_warn "Non-interactive session: '$1' requires --yes"
		return 1
	fi
	printf '%s [y/N]: ' "$1" >&2
	read -r _cf_ans || return 1
	case "$_cf_ans" in
	y | Y | yes | YES | Yes) return 0 ;;
	esac
	return 1
}

# list helpers on space separated words
list_contains() {
	local _lc
	# list_contains "a b c" b
	for _lc in $1; do
		[ "$_lc" = "$2" ] && return 0
	done
	return 1
}
