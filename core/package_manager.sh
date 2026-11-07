# shellcheck shell=sh
# OpenWrt Roaming Manager - package manager abstraction (opkg / apk)
#
# OpenWrt <= 24.10 uses opkg, OpenWrt 25.x uses apk-tools v3. All
# operations are idempotent; nothing is removed without confirmation and
# the active Wi-Fi backend (wpad/hostapd) is never replaced implicitly.

PKG_INDEX_FRESH=0

pkg_mgr() {
	caps_get pkg.manager none
}

# Print installed package names, one per line.
pkg_installed_list() {
	case "$(pkg_mgr)" in
	opkg) opkg list-installed 2>/dev/null | awk '{print $1}' ;;
	apk)
		# apk v3: "name-1.2.3-r1 arch {origin} (license) [installed]"
		apk list --installed 2>/dev/null | awk '{print $1}' |
			sed -E 's/-[0-9][^-]*(-r[0-9]+)?$//' ;;
	*) return 1 ;;
	esac
}

pkg_detect_installed() {
	local _pl
	_pl=$(pkg_installed_list 2>/dev/null | tr '\n' ' ')
	caps_set pkg.installed " $_pl"
}

pkg_is_installed() {
	case "$(caps_get pkg.installed)" in
	*" $1 "*) return 0 ;;
	esac
	# fall back to a live query (state may have changed)
	pkg_installed_list 2>/dev/null | grep -qx -- "$1"
}

# --------------------------------------------------------- preflight
net_check_dns() {
	local _host
	# Resolve a well known name; BusyBox nslookup exits non-zero on failure.
	_host=${1:-downloads.openwrt.org}
	nslookup "$_host" >/dev/null 2>&1
}

net_check_internet() {
	local _t
	_t=${ORM_PING_TARGET:-1.1.1.1}
	ping -c 1 -W 2 "$_t" >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1
}

# Base URL(s) of configured feeds
pkg_repo_urls() {
	case "$(pkg_mgr)" in
	opkg)
		cat "$(orm_path /etc/opkg/distfeeds.conf)" "$(orm_path /etc/opkg/customfeeds.conf)" 2>/dev/null |
			awk '$1 ~ /^src/ {print $3}' ;;
	apk)
		cat "$(orm_path /etc/apk/repositories)" "$(orm_path /etc/apk/repositories.d)"/*.list 2>/dev/null |
			grep -Ev '^[[:blank:]]*(#|$)' ;;
	esac
}

pkg_check_repo() {
	local _url _host
	_url=$(pkg_repo_urls | head -n1)
	[ -n "$_url" ] || return 1
	_host=$(printf '%s' "$_url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
	net_check_dns "$_host" || return 1
	return 0
}

# Run all preflight checks; records the result in caps (pkg.preflight).
pkg_preflight() {
	local _pf_reason
	_pf_reason=''
	if [ "$(pkg_mgr)" = none ]; then
		_pf_reason="no supported package manager (opkg/apk) found"
	elif ! net_check_internet; then
		_pf_reason="no internet connectivity"
	elif ! net_check_dns; then
		_pf_reason="DNS resolution failed"
	elif ! pkg_check_repo; then
		_pf_reason="package repository host is unreachable"
	fi
	if [ -n "$_pf_reason" ]; then
		caps_set pkg.preflight fail
		caps_set pkg.preflight_reason "$_pf_reason"
		log_warn "Package installation unavailable: $_pf_reason"
		return 1
	fi
	caps_set pkg.preflight ok
	return 0
}

# Approximate flash needed to install a package with its usual
# dependencies (KB). Small (8 MB flash) MT7628/MT7621 devices often have
# well under 1 MB free.
pkg_size_kb() {
	case "$1" in
	usteer) echo 160 ;;
	dawn) echo 512 ;;
	iw | iw-full) echo 192 ;;
	tcpdump*) echo 640 ;;
	wpad* | hostapd*) echo 800 ;;
	*) echo 256 ;;
	esac
}

# pkg_flash_ok PKG -> 0 if enough free flash (or unknown), records reason
pkg_flash_ok() {
	local _need _free
	_need=$(($(pkg_size_kb "$1") + 128))
	_free=$(caps_get flash.free_kb)
	is_uint "$_free" || _free=$(flash_free_kb)
	is_uint "$_free" || return 0
	if [ "$_free" -lt "$_need" ]; then
		caps_set "pkg.fail.$1" "insufficient flash: ${_free} KB free, about ${_need} KB needed"
		log_warn "Not installing $1: only ${_free} KB of flash free (about ${_need} KB needed)"
		return 1
	fi
	return 0
}

pkg_update() {
	[ "$PKG_INDEX_FRESH" = 1 ] && return 0
	log_info "Updating package index ($(pkg_mgr))..."
	case "$(pkg_mgr)" in
	opkg) opkg update >>"$ORM_LOG" 2>&1 ;;
	apk) apk update >>"$ORM_LOG" 2>&1 ;;
	*) return 1 ;;
	esac || {
		log_warn "Package index update failed"
		return 1
	}
	PKG_INDEX_FRESH=1
	return 0
}

pkg_is_available() {
	case "$(pkg_mgr)" in
	opkg) [ -n "$(opkg list "$1" 2>/dev/null | awk -v p="$1" '$1==p')" ] ;;
	apk) apk list --available "$1" 2>/dev/null | awk '{print $1}' |
		sed -E 's/-[0-9][^-]*(-r[0-9]+)?$//' | grep -qx -- "$1" ;;
	*) return 1 ;;
	esac
}

# Architecture check: the package must exist for this device's arch in
# the configured feeds. opkg/apk only list packages for compatible archs,
# so availability implies an arch match; we additionally verify opkg's
# reported Architecture field when present.
pkg_arch_ok() {
	local _a _mine
	case "$(pkg_mgr)" in
	opkg)
		_a=$(opkg info "$1" 2>/dev/null | sed -n 's/^Architecture: //p' | head -n1)
		[ -z "$_a" ] && return 0
		[ "$_a" = all ] && return 0
		_mine=$(caps_get os.pkgarch)
		[ "$_mine" = unknown ] && return 0
		[ "$_a" = "$_mine" ] ;;
	*) return 0 ;;
	esac
}

# Packages that conflict with each other in the wpad/hostapd family.
pkg_wpad_family() {
	case "$1" in
	wpad | wpad-* | hostapd | hostapd-basic* | hostapd-mini | hostapd-openssl | hostapd-wolfssl | hostapd-mbedtls) return 0 ;;
	esac
	return 1
}

# Save the currently installed package list (used by backups)
pkg_save_list() {
	pkg_installed_list 2>/dev/null | sort | atomic_write "$1"
}

# pkg_install PKG REASON - idempotent install with full preflight.
# Returns 0 if installed (or already present), 1 otherwise. On failure,
# the reason is recorded as caps "pkg.fail.<pkg>".
pkg_install() {
	local _pkg _why _cur _rc
	_pkg=$1 _why=${2:-}
	if pkg_is_installed "$_pkg"; then
		log_debug "package $_pkg already installed"
		return 0
	fi
	if pkg_wpad_family "$_pkg"; then
		_cur=$(caps_get hostapd.package none)
		if [ "$_cur" != none ] && [ "$_cur" != "$_pkg" ]; then
			caps_set "pkg.fail.$_pkg" "would replace the active Wi-Fi backend $_cur (use 'roamctl backend replace')"
			log_warn "Refusing to install $_pkg: it conflicts with the active backend $_cur"
			return 1
		fi
	fi
	if [ "$ORM_DRYRUN" = 1 ]; then
		log_info "[dry-run] would install $_pkg ($_why)"
		return 0
	fi
	pkg_flash_ok "$_pkg" || return 1
	if [ "$(caps_get pkg.preflight)" != ok ]; then
		pkg_preflight || {
			caps_set "pkg.fail.$_pkg" "$(caps_get pkg.preflight_reason)"
			return 1
		}
	fi
	pkg_update || {
		caps_set "pkg.fail.$_pkg" "package index update failed"
		return 1
	}
	if ! pkg_is_available "$_pkg"; then
		caps_set "pkg.fail.$_pkg" "package not available in configured feeds"
		log_warn "Package $_pkg is not available in the configured repositories"
		return 1
	fi
	if ! pkg_arch_ok "$_pkg"; then
		caps_set "pkg.fail.$_pkg" "architecture mismatch"
		return 1
	fi
	log_info "Installing $_pkg${_why:+ ($_why)}..."
	case "$(pkg_mgr)" in
	opkg) opkg install "$_pkg" >>"$ORM_LOG" 2>&1 ;;
	apk) apk add "$_pkg" >>"$ORM_LOG" 2>&1 ;;
	esac
	_rc=$?
	if [ "$_rc" -ne 0 ] || ! pkg_installed_list | grep -qx -- "$_pkg"; then
		caps_set "pkg.fail.$_pkg" "installation failed (see $ORM_LOG)"
		log_warn "Installation of $_pkg failed"
		return 1
	fi
	caps_set pkg.installed "$(caps_get pkg.installed)$_pkg "
	journal_add_pkg "$_pkg"
	log_ok "Installed $_pkg"
	return 0
}

# pkg_remove PKG - always asks for confirmation (system package removal)
pkg_remove() {
	pkg_is_installed "$1" || return 0
	if pkg_wpad_family "$1"; then
		log_error "Refusing to remove Wi-Fi backend package $1"
		return 1
	fi
	confirm "Remove package $1?" || return 1
	[ "$ORM_DRYRUN" = 1 ] && {
		log_info "[dry-run] would remove $1"
		return 0
	}
	case "$(pkg_mgr)" in
	opkg) opkg remove "$1" >>"$ORM_LOG" 2>&1 ;;
	apk) apk del "$1" >>"$ORM_LOG" 2>&1 ;;
	*) return 1 ;;
	esac
}

# Replace the Wi-Fi backend (e.g. wpad-mini -> wpad-basic-mbedtls).
# Only on explicit request. The new package is downloaded *before* the
# old one is removed so a failed download cannot leave the AP without
# hostapd.
pkg_replace_backend() {
	local _old _new _dl
	_old=$1 _new=$2
	pkg_wpad_family "$_new" || {
		log_error "$_new is not a hostapd/wpad package"
		return 1
	}
	log_warn "Replacing the Wi-Fi backend $_old with $_new will restart all wireless interfaces."
	confirm "Replace $_old with $_new?" || return 1
	pkg_preflight || return 1
	pkg_update || return 1
	pkg_is_available "$_new" || {
		log_error "$_new not available"
		return 1
	}
	_dl=$(mktemp -d "${ORM_SYSROOT}/tmp/roamctl-pkg.XXXXXX") || return 1
	case "$(pkg_mgr)" in
	opkg)
		(cd "$_dl" && opkg download "$_new") >>"$ORM_LOG" 2>&1 || {
			rm -rf "$_dl"
			log_error "Download of $_new failed; backend unchanged"
			return 1
		}
		opkg remove "$_old" >>"$ORM_LOG" 2>&1
		if ! opkg install "$_dl"/*.ipk >>"$ORM_LOG" 2>&1; then
			log_error "Install of $_new failed, reinstalling $_old"
			opkg install "$_old" >>"$ORM_LOG" 2>&1
			rm -rf "$_dl"
			return 1
		fi
		;;
	apk)
		apk fetch -o "$_dl" "$_new" >>"$ORM_LOG" 2>&1 || {
			rm -rf "$_dl"
			log_error "Download of $_new failed; backend unchanged"
			return 1
		}
		apk del "$_old" >>"$ORM_LOG" 2>&1
		if ! apk add "$_dl"/*.apk >>"$ORM_LOG" 2>&1; then
			log_error "Install of $_new failed, reinstalling $_old"
			apk add "$_old" >>"$ORM_LOG" 2>&1
			rm -rf "$_dl"
			return 1
		fi
		;;
	esac
	rm -rf "$_dl"
	log_ok "Wi-Fi backend replaced: $_old -> $_new"
	return 0
}
