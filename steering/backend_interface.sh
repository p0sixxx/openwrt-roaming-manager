# shellcheck shell=sh
# OpenWrt Roaming Manager - steering backend API
#
# A steering backend is a set of shell functions named
#   <backend>_be_<operation>
# Required operations:
#   package     print the package providing the backend ("" = built in)
#   installed   0 if the backend software is present
#   running     0 if the backend daemon is running
#   configure   add UCI changes for the selected groups to the plan
#   post_apply  hook after UCI commit (start/restart the service)
#   enable      enable + start the service
#   disable     stop + disable the service (package stays installed)
#   handles_nr  0 if the backend distributes 802.11k neighbor reports
#   features    print supported steering features (space separated)
#   test        add diagnostic results (report_add steering ...)
#
# To add a backend: create steering/<name>_backend.sh implementing these
# functions and add <name> to STEER_BACKENDS.

STEER_BACKENDS="usteer dawn native"

steer_valid_backend() {
	list_contains "$STEER_BACKENDS" "$1"
}

# steer_call BACKEND OPERATION [ARGS...]
steer_call() {
	local _be _op
	_be=$1 _op=$2
	shift 2
	steer_valid_backend "$_be" || {
		log_error "Unknown steering backend '$_be'"
		return 1
	}
	case "$_op" in
	package | installed | running | configure | post_apply | enable | disable | handles_nr | features | test) ;;
	*)
		log_error "internal: invalid backend operation '$_op'"
		return 1
		;;
	esac
	"${_be}_be_${_op}" "$@"
}
