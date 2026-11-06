# shellcheck shell=sh
# OpenWrt Roaming Manager - FT key manager
#
# Two key distribution models are supported by hostapd and selected per
# roaming group:
#
#  local  - "ft_psk_generate_local=1": every AP derives PMK-R0/PMK-R1
#           locally from the PSK. No R0KH/R1KH communication and no key
#           material besides the passphrase. Only valid for WPA2-PSK
#           (FT-PSK); hostapd cannot do this for SAE or 802.1X.
#
#  shared - R0KH/R1KH with one random 256-bit key per group, configured
#           with hostapd wildcard entries:
#               r0kh=ff:ff:ff:ff:ff:ff * <key>
#               r1kh=00:00:00:00:00:00 00:00:00:00:00:00 <key>
#           PMK-R1 is fetched over the distribution system (ethertype
#           0x890d on the bridge) and protected with AES-SIV using <key>.
#           Required for FT-SAE and FT-EAP. NAS-ID (R0KH-ID) defaults to
#           the BSSID in OpenWrt, R1KH-ID defaults to the BSSID in hostapd,
#           both unique per BSS.
#
# The key is stored in /etc/roamctl/keys/<group>.ftkey (0600, dir 0700),
# is never printed or logged, travels to other APs only through SSH
# stdin, and is compared between APs by fingerprint only.

ft_key_file() {
	printf '%s/%s.ftkey' "$ORM_KEY_DIR" "$1"
}

ft_key_valid() {
	printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

ft_key_read() {
	local _kf _k
	_kf=$(ft_key_file "$1")
	[ -f "$_kf" ] || return 1
	_k=$(tr -d ' \n' <"$_kf")
	ft_key_valid "$_k" || return 1
	printf '%s' "$_k"
}

ft_key_write() {
	# ft_key_write GROUP KEY
	ft_key_valid "$2" || {
		log_error "Refusing to store malformed FT key"
		return 1
	}
	ensure_dir "$ORM_KEY_DIR" 0700 || return 1
	printf '%s\n' "$2" | atomic_write "$(ft_key_file "$1")" 600
}

# ft_key_ensure GROUP -> key exists afterwards (generated once)
ft_key_ensure() {
	local _nk
	ft_key_read "$1" >/dev/null 2>&1 && return 0
	[ "$ORM_DRYRUN" = 1 ] && return 0
	_nk=$(random_hex 32) || {
		log_error "Cannot read the kernel random number generator"
		return 1
	}
	ft_key_write "$1" "$_nk" || return 1
	log_info "Generated new FT R0KH/R1KH key for group $1"
}

ft_key_fingerprint() {
	local _k
	_k=$(ft_key_read "$1") || {
		printf none
		return 1
	}
	secret_fingerprint "$_k"
}

# Rotate: new key; caller must push it to every member AP.
ft_key_rotate() {
	local _nk
	_nk=$(random_hex 32) || return 1
	ft_key_write "$1" "$_nk"
}

# Choose the key model for a group from its security family.
ft_key_mode_for() {
	local _req
	# ft_key_mode_for SECURITY [REQUESTED]
	_req=${2:-auto}
	case "$1" in
	psk)
		[ "$_req" = shared ] && printf shared || printf local ;;
	sae | sae-mixed | eap) printf shared ;;
	*) printf none ;;
	esac
}

ft_r0kh_entry() {
	printf 'ff:ff:ff:ff:ff:ff,*,%s' "$1"
}

ft_r1kh_entry() {
	printf '00:00:00:00:00:00,00:00:00:00:00:00,%s' "$1"
}

# Fingerprint of the R0KH key configured on an interface (consistency
# check without exposing the key).
ft_iface_key_fingerprint() {
	local _e
	_e=$(uci_get_list "wireless.$1.r0kh" | head -n1)
	[ -n "$_e" ] || {
		printf none
		return 0
	}
	secret_fingerprint "${_e##*,}"
}
