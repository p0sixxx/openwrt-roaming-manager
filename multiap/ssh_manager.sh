# shellcheck shell=sh
# OpenWrt Roaming Manager - SSH manager
#
# Remote APs are managed over SSH with public key authentication only.
#  * a dedicated identity in /etc/roamctl/ssh (0700) - OpenSSH or dropbear
#    format, matching the installed client
#  * host keys are pinned on first use and verified afterwards
#  * passwords are never accepted as arguments or stored; the one-time
#    key installation ("roamctl multiap copy-id") lets ssh itself prompt
#  * secrets (FT keys, DAWN secret) are sent on stdin of the encrypted
#    session, never on the remote command line (visible in ps)
#  * every remote command is a fixed "roamctl agent <verb>" invocation;
#    user supplied values are validated before use

ssh_dir() {
	printf '%s/ssh' "$ORM_ETC"
}

ssh_client_type() {
	if [ -n "${ORM_SSH_TYPE:-}" ]; then
		printf '%s' "$ORM_SSH_TYPE"
		return 0
	fi
	if have_cmd ssh && ssh -V 2>&1 | grep -q OpenSSH; then
		printf openssh
	elif have_cmd dbclient || have_cmd ssh; then
		printf dropbear
	else
		printf none
	fi
}

ssh_identity() {
	case "$(ssh_client_type)" in
	openssh) printf '%s/id_ed25519' "$(ssh_dir)" ;;
	*) printf '%s/id_dropbear' "$(ssh_dir)" ;;
	esac
}

ssh_valid_user() {
	printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'
}

# Generate the controller identity if needed; prints the public key.
ssh_key_ensure() {
	local _d _id
	_d=$(ssh_dir)
	ensure_dir "$_d" 0700 || return 1
	_id=$(ssh_identity)
	if [ ! -f "$_id" ]; then
		case "$(ssh_client_type)" in
		openssh)
			ssh-keygen -q -t ed25519 -N '' -C "roamctl@$(cat "$(orm_path /proc/sys/kernel/hostname)" 2>/dev/null || echo openwrt)" -f "$_id" >/dev/null 2>&1 || return 1 ;;
		dropbear)
			dropbearkey -t ed25519 -f "$_id" >/dev/null 2>&1 ||
				dropbearkey -t rsa -s 3072 -f "$_id" >/dev/null 2>&1 || return 1 ;;
		*)
			log_error "No SSH client available (install dropbear or openssh-client)"
			return 1 ;;
		esac
		chmod 600 "$_id"
		log_info "Generated SSH identity $_id"
	fi
	ssh_pubkey
}

ssh_pubkey() {
	local _id
	_id=$(ssh_identity)
	case "$(ssh_client_type)" in
	openssh) cat "$_id.pub" 2>/dev/null ;;
	*) dropbearkey -y -f "$_id" 2>/dev/null | grep -E '^(ssh-|ecdsa-)' ;;
	esac
}

# Build the argument vector into "$@" for the configured client.
# ssh_exec HOST USER PORT REMOTE_COMMAND  (stdin forwarded)
ssh_exec() {
	local _h _u _p _cmd _id _to _tw
	_h=$1 _u=${2:-root} _p=${3:-22} _cmd=$4
	is_safe_host "$_h" || { log_error "Invalid host '$_h'"; return 255; }
	ssh_valid_user "$_u" || { log_error "Invalid user '$_u'"; return 255; }
	is_uint "$_p" || { log_error "Invalid port '$_p'"; return 255; }
	_id=$(ssh_identity)
	_to=${ORM_SSH_TIMEOUT:-60}
	_tw=''
	have_cmd timeout && _tw="timeout $_to"
	case "$(ssh_client_type)" in
	openssh)
		# shellcheck disable=SC2086
		$_tw ssh -T -i "$_id" -p "$_p" \
			-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 \
			-o StrictHostKeyChecking=accept-new \
			-o UserKnownHostsFile="$(ssh_dir)/known_hosts" \
			-o LogLevel=ERROR -- "$_u@$_h" "$_cmd"
		;;
	dropbear)
		# -y: accept and remember an unknown host key (TOFU), reject changes
		# shellcheck disable=SC2086
		$_tw ssh -T -y -i "$_id" -p "$_p" "$_u@$_h" "$_cmd"
		;;
	*) return 255 ;;
	esac
}

# Run a roamctl agent verb on an AP section of /etc/config/roamctl.
# ssh_agent AP_SECTION VERB [ARGS...] (stdin forwarded)
ssh_agent() {
	local _ap _verb _args _x _host _user _port
	_ap=$1 _verb=$2
	shift 2
	case "$_verb" in
	ping | info | apply | nr-own | nr-set | health | rollback | backup | diag | version | watch) ;;
	*) log_error "internal: invalid agent verb $_verb"; return 255 ;;
	esac
	_args=''
	for _x in "$@"; do
		printf '%s' "$_x" | grep -Eq '^[A-Za-z0-9_.:-]+$' || return 255
		_args="$_args $_x"
	done
	_host=$(orm_uci -q get "roamctl.$_ap.host") || return 255
	_user=$(orm_uci -q get "roamctl.$_ap.user" || echo root)
	_port=$(orm_uci -q get "roamctl.$_ap.port" || echo 22)
	ssh_exec "$_host" "$_user" "$_port" "roamctl agent $_verb$_args"
}

ssh_reachable() {
	local _out
	_out=$(ssh_agent "$1" ping </dev/null 2>/dev/null)
	[ "$_out" = pong ]
}

# Install the controller key on a remote AP. ssh prompts for the password
# itself (interactive TTY); nothing is passed on the command line.
ssh_copy_id() {
	local _h _u _p _pub _remote
	_h=$1 _u=${2:-root} _p=${3:-22}
	is_safe_host "$_h" && ssh_valid_user "$_u" && is_uint "$_p" || return 1
	_pub=$(ssh_key_ensure) || return 1
	log_info "Installing roamctl public key on $_u@$_h (you may be asked for the password by ssh)"
	# shellcheck disable=SC2016 # expanded on the remote side
	_remote='umask 077; mkdir -p /etc/dropbear; touch /etc/dropbear/authorized_keys; k=$(cat); grep -qxF "$k" /etc/dropbear/authorized_keys || printf "%s\n" "$k" >> /etc/dropbear/authorized_keys; [ -d "$HOME/.ssh" ] && { touch "$HOME/.ssh/authorized_keys"; grep -qxF "$k" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$k" >> "$HOME/.ssh/authorized_keys"; }; echo ok'
	case "$(ssh_client_type)" in
	openssh)
		printf '%s\n' "$_pub" | ssh -p "$_p" -o StrictHostKeyChecking=accept-new \
			-o UserKnownHostsFile="$(ssh_dir)/known_hosts" -- "$_u@$_h" "$_remote" ;;
	*)
		printf '%s\n' "$_pub" | ssh -y -p "$_p" "$_u@$_h" "$_remote" ;;
	esac
}
