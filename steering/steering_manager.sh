# shellcheck shell=sh
# OpenWrt Roaming Manager - steering manager
#
# Selects exactly one steering backend, installs it when required and
# allowed, configures it and guarantees that no two steering systems run
# at the same time (usteer and DAWN would fight over the same clients).
#
# Selection in "auto" mode:
#   1. a backend that is already installed and enabled (respect the
#      existing setup; usteer preferred if both are)
#   2. usteer, installed from the package feed
#   3. the built-in "native" backend (hostapd BTM driven by roamctl's
#      own policy engine) when no package can be installed

steer_detect_backends() {
	local _be _pk _active
	for _be in $STEER_BACKENDS; do
		if steer_call "$_be" installed; then caps_set "steer.$_be.installed" 1; else caps_set "steer.$_be.installed" 0; fi
		if steer_call "$_be" running; then caps_set "steer.$_be.running" 1; else caps_set "steer.$_be.running" 0; fi
		_pk=$(steer_call "$_be" package)
		[ -n "$_pk" ] && caps_set "steer.$_be.package" "$_pk"
	done
	_active=none
	for _be in usteer dawn native; do
		if [ "$(caps_get "steer.$_be.running")" = 1 ]; then
			if [ "$_active" = none ]; then
				_active=$_be
			else
				caps_set steer.conflict "$_active+$_be"
			fi
		fi
	done
	caps_set steer.active "$_active"
}

# Decide the backend to use. Prints the backend name.
steer_select() {
	local _req _cur _be
	_req=${1:-auto}
	if [ "$_req" != auto ]; then
		steer_valid_backend "$_req" || [ "$_req" = none ] || return 1
		printf '%s' "$_req"
		return 0
	fi
	_cur=$(caps_get steer.active none)
	if [ "$_cur" != none ]; then
		printf '%s' "$_cur"
		return 0
	fi
	for _be in usteer dawn; do
		if [ "$(caps_get "steer.$_be.installed")" = 1 ]; then
			printf '%s' "$_be"
			return 0
		fi
	done
	printf usteer
}

# steer_prepare BACKEND -> installs software if needed, may fall back to
# native. Prints the backend that will actually be used.
steer_prepare() {
	local _be _pk _why
	_be=$1
	[ "$_be" = none ] && {
		printf none
		return 0
	}
	if ! steer_call "$_be" installed; then
		_pk=$(steer_call "$_be" package)
		if [ -n "$_pk" ] && pkg_install "$_pk" "steering backend $_be"; then
			:
		else
			_why=$(caps_get "pkg.fail.$_pk" "not installable")
			caps_set "steer.fallback_reason" "$_be unavailable: $_why"
			log_warn "Steering backend $_be unavailable ($_why); using built-in native backend"
			_be=native
		fi
	fi
	printf '%s' "$_be"
}

# Add plan entries for the backend and disable competing backends.
steer_plan() {
	local _be _other
	_be=$1
	for _other in $STEER_BACKENDS; do
		[ "$_other" = "$_be" ] && continue
		# the native backend shares the roamctl service (boot check, neighbor
		# maintenance); it is "active" only when native steering is enabled
		if [ "$_other" = native ]; then
			[ "$(orm_uci -q get roamctl.global.native_steering)" = 1 ] || continue
		elif [ "$(caps_get "steer.$_other.running")" != 1 ] && ! svc_is_enabled "$_other"; then
			continue
		fi
		list_contains "${ORM_STEER_DISABLE:-}" "$_other" || ORM_STEER_DISABLE="${ORM_STEER_DISABLE:-} $_other"
	done
	plan_set roamctl.global.steering_backend_active "$_be"
	[ "$_be" = none ] && return 0
	steer_call "$_be" configure
}

steer_service_name() {
	case "$1" in
	native) printf roamctl ;;
	*) printf '%s' "$1" ;;
	esac
}

# Post-commit: stop competing backends (journaled), start selected one.
steer_post_apply() {
	local _be _other _svc
	_be=$(roam_get global.steering_backend_active none)
	for _other in ${ORM_STEER_DISABLE:-}; do
		_svc=$(steer_service_name "$_other")
		if svc_is_enabled "$_svc"; then journal_add_svc "$_svc" 1; else journal_add_svc "$_svc" 0; fi
		if [ "$_other" = native ]; then
			orm_uci set roamctl.global.native_steering=0
			orm_uci commit roamctl
		else
			log_info "Disabling competing steering backend $_other"
			steer_call "$_other" disable
		fi
	done
	[ "$_be" = none ] && return 0
	_svc=$(steer_service_name "$_be")
	if svc_is_enabled "$_svc"; then journal_add_svc "$_svc" 1; else journal_add_svc "$_svc" 0; fi
	steer_call "$_be" post_apply
}

# Is the selected backend in the state the configuration expects?
steer_backend_healthy() {
	[ "$1" = none ] && return 0
	[ "$(roam_get global.steering_backend_active none)" = "$1" ] || return 1
	steer_call "$1" running
}

steer_status_line() {
	local _be
	_be=$(roam_get global.steering_backend_active none)
	if [ "$_be" = none ]; then
		printf 'DISABLED'
	elif steer_call "$_be" running; then
		printf 'ENABLED'
	else
		printf 'INACTIVE'
	fi
}
