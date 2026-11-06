# shellcheck shell=sh
# OpenWrt Roaming Manager - IEEE 802.11r Fast BSS Transition
#
# UCI options (OpenWrt netifd wireless handler, translated to hostapd.conf):
#   ieee80211r            1 = enable FT (adds FT-PSK/FT-SAE/FT-EAP AKMs)
#   mobility_domain       4 hex chars, identical within a roaming group
#   ft_over_ds            0 = FT over the air (default, best client compat)
#                         1 = FT over the DS
#   ft_psk_generate_local 1 = derive PMK-R1 locally from the PSK (FT-PSK only)
#   r0kh / r1kh           key holder lists for PMK-R1 distribution
#   reassociation_deadline, r0_key_lifetime - only set in advanced mode
# Only options the installed handler understands are written.

# r_plan_iface SECTION GROUP MDID KEYMODE FTMODE
r_plan_iface() {
	local _s _g _md _km _fm _p _key
	_s=$1 _g=$2 _md=$3 _km=$4 _fm=${5:-air}
	_p="wireless.$_s"
	if [ "$(caps_get "iface.$_s.can_11r")" != 1 ]; then
		log_debug "802.11r skipped on $_s: $(caps_get "iface.$_s.why_11r")"
		return 1
	fi
	plan_set "$_p.ieee80211r" 1
	plan_set "$_p.mobility_domain" "$_md"
	if [ "$(caps_get uciopt.ft_over_ds)" != 0 ]; then
		if [ "$_fm" = ds ]; then plan_set "$_p.ft_over_ds" 1; else plan_set "$_p.ft_over_ds" 0; fi
	fi
	case "$_km" in
	local)
		[ "$(caps_get uciopt.ft_psk_generate_local)" != 0 ] && plan_set "$_p.ft_psk_generate_local" 1
		# stale shared-key entries from a previous mode are removed
		plan_del "$_p.r0kh"
		plan_del "$_p.r1kh"
		;;
	shared)
		[ "$(caps_get uciopt.ft_psk_generate_local)" != 0 ] && plan_set "$_p.ft_psk_generate_local" 0
		_key=$(ft_key_read "$_g") || {
			[ "$ORM_DRYRUN" = 1 ] && _key=$(printf '%064d' 0)
		}
		[ -n "$_key" ] || {
			log_error "FT key for group $_g missing"
			return 1
		}
		plan_list "$_p.r0kh" "$(ft_r0kh_entry "$_key")"
		plan_list "$_p.r1kh" "$(ft_r1kh_entry "$_key")"
		;;
	esac
	if [ -n "${ORM_REASSOC_DEADLINE:-}" ] && [ "$(caps_get uciopt.reassociation_deadline)" != 0 ]; then
		plan_set "$_p.reassociation_deadline" "$ORM_REASSOC_DEADLINE"
	fi
	if [ -n "${ORM_R0_LIFETIME:-}" ] && [ "$(caps_get uciopt.r0_key_lifetime)" != 0 ]; then
		plan_set "$_p.r0_key_lifetime" "$ORM_R0_LIFETIME"
	fi
	return 0
}

# Remove roamctl FT settings from an interface (used by "disable 11r")
r_plan_disable() {
	local _p
	_p="wireless.$1"
	plan_set "$_p.ieee80211r" 0
	plan_del "$_p.r0kh"
	plan_del "$_p.r1kh"
}

# Expected AKMs in hostapd.conf for a security family
r_expected_akm() {
	case "$1" in
	psk) printf FT-PSK ;;
	sae) printf FT-SAE ;;
	sae-mixed) printf 'FT-PSK FT-SAE' ;;
	eap) printf FT-EAP ;;
	esac
}
