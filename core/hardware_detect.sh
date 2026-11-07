# shellcheck shell=sh
# OpenWrt Roaming Manager - hardware detection
#
# Enumerates wiphys (radios), their kernel drivers, bands, supported
# PHY standards and interface modes using sysfs, iw and iwinfo.
# Nothing here is inferred from UCI alone.

# Classify a kernel wireless driver:
#   softmac  - mac80211 based: hostapd implements MLME, so 802.11k/v/r work
#   fullmac  - firmware implements MLME (brcmfmac, mwifiex): FT in AP mode
#              is generally not available
#   unknown  - not recognised; capabilities are decided by runtime probes
hw_driver_class() {
	case "$1" in
	mt7* | \
		ath9k* | ath10k* | ath11k* | ath12k* | ath5k | carl9170 | \
		rtw88* | rtw89* | rt2800* | rt2x00* | rtl8xxxu | rtl8192* | rtl818x* | \
		mwlwifi | mwl8k | iwlwifi | b43 | b43legacy | mac80211_hwsim | p54*)
		printf softmac ;;
	brcmfmac | mwifiex* | wl | dhd | qcacld* | morse*)
		printf fullmac ;;
	*) printf unknown ;;
	esac
}

# Vendor guess from driver name (used for display and compatibility notes)
hw_driver_vendor() {
	case "$1" in
	mt7*) printf MediaTek ;;
	ath* | carl9170 | qcacld*) printf Qualcomm ;;
	brcmfmac | b43* | wl | dhd) printf Broadcom ;;
	rtw* | rtl* | rt2*) printf Realtek ;;
	mwlwifi | mwl8k | mwifiex*) printf Marvell ;;
	iwlwifi) printf Intel ;;
	mac80211_hwsim) printf "Linux hwsim" ;;
	*) printf unknown ;;
	esac
}

# Return the driver for a phy using sysfs (device/driver symlink).
hw_phy_driver() {
	local _pd
	_pd=$(orm_path "/sys/class/ieee80211/$1/device/driver")
	if [ -e "$_pd" ] || [ -L "$_pd" ]; then
		basename "$(readlink "$_pd")"
		return 0
	fi
	# Fallback: iwinfo prints the driver for some backends
	printf unknown
	return 1
}

hw_list_phys() {
	local _pdir _p
	_pdir=$(orm_path /sys/class/ieee80211)
	if [ -d "$_pdir" ]; then
		for _p in "$_pdir"/*; do
			[ -e "$_p" ] || continue
			basename "$_p"
		done
		return 0
	fi
	have_cmd iw && iw phy 2>/dev/null | sed -n 's/^Wiphy \(.*\)$/\1/p'
}

# Parse "iw phy X info" for bands, modes and standards. Prints k=v lines.
hw_parse_iw_phy() {
	awk '
	function flush_band() {
		if (band != "") bands = bands " " band
	}
	/^[ \t]*Band [0-9]+:/ {
		n = $2; sub(":", "", n)
		flush_band()
		if (n == 1) band = "2g"; else if (n == 2) band = "5g"; else if (n == 4) band = "6g"; else if (n == 3) band = "60g"; else band = "b" n
		next
	}
	/Supported interface modes:/ { inmodes = 1; next }
	inmodes && /^[ \t]+\* / { m = $0; sub(/^[ \t]+\* /, "", m); if (m == "AP") ap = 1; if (m == "AP/VLAN") apvlan = 1; next }
	inmodes && !/^[ \t]+\* / { inmodes = 0 }
	/Capabilities: 0x/ { ht = 1 }
	/HT20\/HT40|HT TX\/RX MCS/ { ht = 1 }
	/VHT Capabilities/ { vht = 1 }
	/HE Iftypes:.*AP/ { he = 1 }
	/EHT Iftypes:.*AP/ { eht = 1 }
	/^[ \t]*valid interface combinations:/ { }
	/#\{ AP.*\} <= [0-9]+/ {
		s = $0; sub(/.*#\{ [^}]*AP[^}]*\} <= /, "", s); sub(/[^0-9].*/, "", s)
		if (s + 0 > maxap) maxap = s + 0
	}
	/\[ RRM \]/ { rrm = 1 }
	/\[ BEACON_PROTECTION \]/ { bigtk = 1 }
	/\* \[ ?FILS_DISCOVERY ?\]/ { fils = 1 }
	END {
		flush_band()
		sub(/^ /, "", bands)
		std = ""
		if (ht) std = std " n"
		if (vht) std = std " ac"
		if (he) std = std " ax"
		if (eht) std = std " be"
		sub(/^ /, "", std)
		printf "bands=%s\nap=%d\napvlan=%d\nstd=%s\nmaxap=%d\nrrm_ext=%d\n", bands, ap, apvlan, std, maxap, rrm
	}'
}

hw_detect_phy() {
	local _phy _drv _info _k _v _hw
	_phy=$1
	_drv=$(hw_phy_driver "$_phy")
	caps_set "phy.$_phy.driver" "$_drv"
	caps_set "phy.$_phy.driver_class" "$(hw_driver_class "$_drv")"
	caps_set "phy.$_phy.vendor" "$(hw_driver_vendor "$_drv")"

	_info=''
	if have_cmd iw; then
		_info=$(iw phy "$_phy" info 2>/dev/null)
	fi
	if [ -n "$_info" ]; then
		while IFS='=' read -r _k _v; do
			[ -n "$_k" ] && caps_set "phy.$_phy.$_k" "$_v"
		done <<EOF
$(printf '%s\n' "$_info" | hw_parse_iw_phy)
EOF
		caps_set "phy.$_phy.iw" 1
	else
		caps_set "phy.$_phy.iw" 0
	fi

	if have_cmd iwinfo; then
		_hw=$(iwinfo "$_phy" info 2>/dev/null | sed -n 's/^[[:blank:]]*Hardware: *//p' | head -n1)
		[ -n "$_hw" ] && caps_set "phy.$_phy.hardware" "$_hw"
	fi
}

# Map an UCI radio section to its wiphy.
hw_radio_phy() {
	local _r _phy _if _pn _path _p _dev _idx
	_r=$1
	_phy=$(wl_get "$_r" phy)
	if [ -n "$_phy" ]; then
		printf '%s' "$_phy"
		return 0
	fi
	# Running interface of this radio -> /sys/class/net/<if>/phy80211/name
	if [ -n "${ORM_WSTATUS:-}" ]; then
		for _if in $(json_glob "$ORM_WSTATUS" "$_r.interfaces.*.ifname"); do
			_pn=$(cat "$(orm_path "/sys/class/net/$_if/phy80211/name")" 2>/dev/null)
			if [ -n "$_pn" ]; then
				printf '%s' "$_pn"
				return 0
			fi
		done
	fi
	# Match the UCI "path" option against the phy device path
	_path=$(wl_get "$_r" path)
	if [ -n "$_path" ]; then
		for _p in $(hw_list_phys); do
			_dev=$(readlink -f "$(orm_path "/sys/class/ieee80211/$_p/device")" 2>/dev/null)
			case "$_dev" in
			*"$_path") printf '%s' "$_p"; return 0 ;;
			esac
		done
	fi
	# Last resort: OpenWrt names phys after the radio index.
	_idx=${_r#radio}
	if is_uint "$_idx" && [ -e "$(orm_path "/sys/class/ieee80211/phy$_idx")" ]; then
		printf 'phy%s' "$_idx"
		return 0
	fi
	return 1
}

hw_band_from_uci() {
	local _b
	_b=$(wl_get "$1" band)
	if [ -z "$_b" ]; then
		# pre-21.02 configs: hwmode 11g/11a
		case "$(wl_get "$1" hwmode)" in
		11a) _b=5g ;;
		11b | 11g) _b=2g ;;
		esac
	fi
	printf '%s' "$_b"
}

hw_detect_radios() {
	local _radios _count _r _phy _band _up _drv _if _ch
	ORM_WSTATUS=''
	have_cmd ubus && ORM_WSTATUS=$(ubus call network.wireless status 2>/dev/null)
	wl_cache_load
	_radios=$(printf '%s' "$ORM_WL_SHOW" | sed -n 's/^wireless\.\([^.=]*\)=wifi-device$/\1/p')
	caps_set radio.list "$(printf '%s' "$_radios" | tr '\n' ' ' | sed 's/ $//')"
	_count=0
	for _r in $_radios; do
		_count=$((_count + 1))
		_phy=$(hw_radio_phy "$_r") || _phy=''
		_band=$(hw_band_from_uci "$_r")
		caps_set "radio.$_r.phy" "${_phy:-unknown}"
		caps_set "radio.$_r.band" "${_band:-unknown}"
		caps_set "radio.$_r.channel" "$(wl_get "$_r" channel)"
		caps_set "radio.$_r.htmode" "$(wl_get "$_r" htmode)"
		caps_set "radio.$_r.country" "$(wl_get "$_r" country)"
		caps_set "radio.$_r.disabled" "$(wl_get "$_r" disabled 0)"
		_up=0
		[ -n "$ORM_WSTATUS" ] && [ "$(json_get "$ORM_WSTATUS" "$_r.up")" = true ] && _up=1
		caps_set "radio.$_r.up" "$_up"
		if [ -n "$_phy" ]; then
			_drv=$(caps_get "phy.$_phy.driver")
			caps_set "radio.$_r.driver" "$_drv"
			# Actual channel from the running interface, if any
			for _if in $(json_glob "$ORM_WSTATUS" "$_r.interfaces.*.ifname"); do
				_ch=$(iw dev "$_if" info 2>/dev/null | sed -n 's/^[[:blank:]]*channel \([0-9]*\) (\([0-9]*\) MHz), width: \([0-9]*\) MHz.*/\1 \2 \3/p')
				if [ -n "$_ch" ]; then
					# shellcheck disable=SC2086
					set -- $_ch
					caps_set "radio.$_r.cur_channel" "$1"
					caps_set "radio.$_r.cur_freq" "$2"
					caps_set "radio.$_r.cur_width" "$3"
					break
				fi
			done
		fi
	done
	caps_set radio.count "$_count"
}

hw_detect_all() {
	local _phys _phy
	_phys=$(hw_list_phys | tr '\n' ' ' | sed 's/ $//')
	caps_set hw.phys "$_phys"
	for _phy in $_phys; do
		hw_detect_phy "$_phy"
	done
	caps_set kernel.mac80211 "$([ -d "$(orm_path /sys/module/mac80211)" ] && echo 1 || echo 0)"
	caps_set kernel.cfg80211 "$([ -d "$(orm_path /sys/module/cfg80211)" ] && echo 1 || echo 0)"
	caps_set kernel.debugfs_ieee80211 "$([ -d "$(orm_path /sys/kernel/debug/ieee80211)" ] && echo 1 || echo 0)"
	hw_detect_radios
}
