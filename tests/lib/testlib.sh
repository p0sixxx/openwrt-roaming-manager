# shellcheck shell=sh
# roamctl test library: fixtures (mock OpenWrt systems) and assertions.

: "${ORM_REPO:?ORM_REPO must point to the repository}"
MOCK_LIB="$ORM_REPO/tests/mock/lib"
MOCK_BIN="$ORM_REPO/tests/mock/bin"
SCEN_DIR="$ORM_REPO/tests/mock/scenarios"
export ORM_REPO MOCK_LIB

# ---------------------------------------------------------------- asserts
TEST_FAILS=0

fail() {
	printf '    ASSERTION FAILED: %s\n' "$*" >&2
	TEST_FAILS=$((TEST_FAILS + 1))
	return 1
}

assert_eq() {
	# assert_eq EXPECTED ACTUAL [MSG]
	[ "$1" = "$2" ] || fail "${3:-values differ}: expected '$1', got '$2'"
}

assert_ne() {
	[ "$1" != "$2" ] || fail "${3:-values equal}: '$1'"
}

assert_contains() {
	# assert_contains HAYSTACK NEEDLE [MSG]
	case "$1" in
	*"$2"*) return 0 ;;
	esac
	fail "${3:-missing text}: '$2' not found in: $(printf '%s' "$1" | tr '\n' ' ' | head -c 400)"
}

assert_not_contains() {
	case "$1" in
	*"$2"*) fail "${3:-unexpected text}: '$2' found" ;;
	esac
	return 0
}

assert_match() {
	printf '%s' "$1" | grep -Eq -- "$2" || fail "${3:-no match}: /$2/ in: $(printf '%s' "$1" | head -c 800)"
}

assert_file() {
	[ -f "$1" ] || fail "file $1 missing"
}

assert_no_file() {
	[ ! -e "$1" ] || fail "file $1 should not exist"
}

assert_rc() {
	# assert_rc EXPECTED ACTUAL [MSG]
	[ "$1" = "$2" ] || fail "${3:-exit code}: expected $1, got $2"
}

# --------------------------------------------------------------- fixtures
# fx_new SCENARIO [HOSTNAME] -> creates a mock OpenWrt system; sets FX,
# ORM_SYSROOT, MOCK_DIR and PATH for the current (sub)shell.
fx_new() {
	_scen=$1 _host=${2:-}
	FX_BASE=${FX_BASE:-$(mktemp -d "${TMPDIR:-/tmp}/roamctl-test.XXXXXX")}
	if [ -n "$_host" ]; then
		_d="$FX_BASE/hosts/$_host"
	else
		_d="$FX_BASE/main"
	fi
	mkdir -p "$_d/root" "$_d/mock"
	(
		unset MOCK_LOG
		ORM_SYSROOT="$_d/root" MOCK_DIR="$_d/mock"
		export ORM_SYSROOT MOCK_DIR
		fx_build "$_scen"
	) || return 1
	if [ -z "$_host" ]; then
		FX=$_d
		ORM_SYSROOT="$_d/root"
		MOCK_DIR="$_d/mock"
		MOCK_HOSTS="$FX_BASE/hosts"
		MOCK_LOG="$_d/mock/calls.log"
		export FX ORM_SYSROOT MOCK_DIR MOCK_HOSTS MOCK_LOG
	fi
}

fx_cleanup() {
	[ -n "${FX_BASE:-}" ] && rm -rf "$FX_BASE"
	FX_BASE=''
	unset MOCK_LOG
}

# Scenario variables with defaults; scenario files override them.
sc_defaults() {
	SC_OS=24.10.2 SC_TARGET=mediatek/filogic SC_ARCH=aarch64_cortex-a53 SC_PKG=opkg
	SC_MODEL="GL.iNet GL-MT6000" SC_BOARD=glinet,gl-mt6000
	SC_COMPAT="glinet,gl-mt6000 mediatek,mt7986a"
	SC_CPU="ARMv8 Processor rev 4" SC_KERNEL=6.6.86
	SC_PHYS="phy0:mt7915e:2g phy1:mt7915e:5g"
	SC_HANDLER=ucode SC_UCI_UNSUPPORTED='' SC_WNM=1 SC_RRM=1 SC_REJECT='' SC_WIFI_FAIL=0
	SC_FEATURES="11r sae eap owe 11ax 11ac acs"
	SC_HOSTAPD_VERSION=2.11-devel
	SC_WPAD=wpad-basic-mbedtls
	SC_PKGS="base-files busybox dnsmasq dropbear firewall4 iw iwinfo kmod-mt7915e libubox ubus uci"
	SC_AVAILABLE="usteer dawn wpad-mbedtls wpad-basic-mbedtls iw-full tcpdump"
	SC_INTERNET=1 SC_DNS=1 SC_GATEWAY=192.168.1.254 SC_LANIP=192.168.1.1
	SC_BASEMAC=02:11:22:33 SC_NOISE=-92
	SC_SSID=HomeNet SC_KEY=correct-horse-battery SC_ENC=psk2
}

sc_wireless_default() {
	cat <<EOF

config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc/18000000.wifi'
	option band '2g'
	option channel '1'
	option htmode 'HE20'
	option country 'DE'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc/18000000.wifi+1'
	option band '5g'
	option channel '36'
	option htmode 'HE80'
	option country 'DE'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid '$SC_SSID'
	option encryption '$SC_ENC'
	option key '$SC_KEY'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid '$SC_SSID'
	option encryption '$SC_ENC'
	option key '$SC_KEY'

config wifi-iface 'guest_radio1'
	option device 'radio1'
	option network 'guest'
	option mode 'ap'
	option ssid 'HomeNet-Guest'
	option encryption 'psk2'
	option key 'guestpassword'
	option isolate '1'

config wifi-iface 'iot_radio0'
	option device 'radio0'
	option network 'iot'
	option mode 'ap'
	option ssid 'HomeNet-IoT'
	option encryption 'psk2'
	option key 'iotpassword1'
EOF
}

fx_iw_phy() {
	# fx_iw_phy PHY BANDS
	printf 'Wiphy %s\n\twiphy index: %s\n\tmax # scan SSIDs: 4\n' "$1" "${1#phy}"
	for _b in $2; do
		case "$_b" in
		2g) printf '\tBand 1:\n\t\tCapabilities: 0x1ff\n\t\t\tHT20/HT40\n\t\tHE Iftypes: managed, AP\n\t\tFrequencies:\n\t\t\t* 2412.0 MHz [1] (20.0 dBm)\n\t\t\t* 2437.0 MHz [6] (20.0 dBm)\n' ;;
		5g) printf '\tBand 2:\n\t\tCapabilities: 0x1ff\n\t\t\tHT20/HT40\n\t\tVHT Capabilities (0x339071b2):\n\t\tHE Iftypes: managed, AP\n\t\tFrequencies:\n\t\t\t* 5180.0 MHz [36] (23.0 dBm)\n' ;;
		6g) printf '\tBand 4:\n\t\tHE Iftypes: managed, AP\n\t\tEHT Iftypes: managed, AP\n\t\tFrequencies:\n\t\t\t* 5955.0 MHz [1] (23.0 dBm)\n' ;;
		esac
	done
	printf '\tSupported interface modes:\n\t\t * IBSS\n\t\t * managed\n\t\t * AP\n\t\t * AP/VLAN\n\t\t * monitor\n\t\t * mesh point\n'
	printf '\tvalid interface combinations:\n\t\t * #{ AP, mesh point } <= 16, #{ managed } <= 19,\n\t\t   total <= 19, #channels <= 1\n'
	printf '\tSupported extended features:\n\t\t* [ RRM ]: RRM\n\t\t* [ BEACON_PROTECTION ]: beacon protection support\n'
}

fx_build() {
	sc_defaults
	sc_wireless() { sc_wireless_default; }
	# shellcheck disable=SC1090
	. "$SCEN_DIR/$1.sh" || return 1
	# per-test overrides: FXO_<VAR>=value
	for _v in SC_OS SC_PKG SC_HANDLER SC_UCI_UNSUPPORTED SC_WNM SC_RRM SC_REJECT SC_WIFI_FAIL \
		SC_FEATURES SC_WPAD SC_PKGS SC_AVAILABLE SC_INTERNET SC_DNS SC_BASEMAC SC_KEY SC_ENC SC_SSID SC_PHYS SC_NOISE; do
		eval "_o=\${FXO_$_v-__unset__}"
		# shellcheck disable=SC2154
		[ "$_o" != __unset__ ] && eval "$_v=\$_o"
	done
	R=$ORM_SYSROOT M=$MOCK_DIR
	mkdir -p "$R/etc/config" "$R/etc/init.d" "$R/etc/rc.d" "$R/tmp" "$R/var/run" "$R/proc/device-tree" \
		"$R/sys/class/ieee80211" "$R/sys/class/net" "$R/sys/module/mac80211" "$R/sys/module/cfg80211" \
		"$R/sys/bus/drivers" "$M/ubus" "$M/iw/phy" "$M/iwinfo" "$M/pkg" "$M/net" "$M/log" "$M/svc" "$M/clients"
	cat >"$R/etc/openwrt_release" <<EOF
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='$SC_OS'
DISTRIB_REVISION='r28427-6df0e3d02a'
DISTRIB_TARGET='$SC_TARGET'
DISTRIB_ARCH='$SC_ARCH'
DISTRIB_DESCRIPTION='OpenWrt $SC_OS'
EOF
	printf '%s' "$SC_COMPAT" | tr ' ' '\000' >"$R/proc/device-tree/compatible"
	printf '\000' >>"$R/proc/device-tree/compatible"
	sc_wireless >"$R/etc/config/wireless"
	chmod 600 "$R/etc/config/wireless"
	cat >"$R/etc/config/network" <<'EOF'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
EOF
	printf "\nconfig dhcp 'lan'\n\toption interface 'lan'\n\toption start '100'\n" >"$R/etc/config/dhcp"
	for _p in $SC_PHYS; do
		_phy=${_p%%:*} _rest=${_p#*:}
		_drv=${_rest%%:*} _bands=$(printf '%s' "${_rest#*:}" | tr ',' ' ')
		mkdir -p "$R/sys/bus/drivers/$_drv" "$R/sys/class/ieee80211/$_phy/device"
		ln -s "../../../../bus/drivers/$_drv" "$R/sys/class/ieee80211/$_phy/device/driver"
		fx_iw_phy "$_phy" "$_bands" >"$M/iw/phy/$_phy.info"
	done
	case "$SC_HANDLER" in
	ucode)
		mkdir -p "$R/usr/share/ucode/wifi" "$R/usr/share/schema"
		_opts="ieee80211r mobility_domain ft_over_ds ft_psk_generate_local reassociation_deadline r0_key_lifetime r1_key_holder pmk_r1_push r0kh r1kh nasid ieee80211k rrm_neighbor_report rrm_beacon_report bss_transition wnm_sleep_mode wnm_sleep_mode_no_keys time_advertisement"
		for _o in $_opts; do
			list_has "$SC_UCI_UNSUPPORTED" "$_o" || printf '\t"%s": { "type": "string" },\n' "$_o"
		done >"$R/usr/share/schema/wireless.wifi-iface.json"
		printf '// mock hostapd.uc\n' >"$R/usr/share/ucode/wifi/hostapd.uc"
		;;
	legacy)
		mkdir -p "$R/lib/netifd"
		_opts="ieee80211r mobility_domain ft_over_ds ft_psk_generate_local reassociation_deadline r0_key_lifetime r1_key_holder pmk_r1_push r0kh r1kh nasid ieee80211k rrm_neighbor_report rrm_beacon_report ieee80211v bss_transition wnm_sleep_mode time_advertisement"
		for _o in $_opts; do
			list_has "$SC_UCI_UNSUPPORTED" "$_o" || printf '\tjson_get_vars %s\n' "$_o"
		done >"$R/lib/netifd/hostapd.sh"
		;;
	esac
	[ "$SC_PKG" = apk ] && mkdir -p "$R/etc/apk" && printf 'https://downloads.openwrt.org/releases/%s/packages/%s/base/packages.adb\n' "$SC_OS" "$SC_ARCH" >"$R/etc/apk/repositories"
	[ "$SC_PKG" = opkg ] && mkdir -p "$R/etc/opkg" && printf 'src/gz openwrt_base https://downloads.openwrt.org/releases/%s/packages/%s/base\n' "$SC_OS" "$SC_ARCH" >"$R/etc/opkg/distfeeds.conf"
	cat >"$M/scenario.env" <<EOF
SC_HANDLER=$SC_HANDLER
SC_UCI_UNSUPPORTED=$SC_UCI_UNSUPPORTED
SC_WNM=$SC_WNM
SC_RRM=$SC_RRM
SC_REJECT=$SC_REJECT
SC_WIFI_FAIL=$SC_WIFI_FAIL
SC_BASEMAC=$SC_BASEMAC
SC_NOISE=$SC_NOISE
EOF
	printf '%s\n' "$SC_FEATURES" >"$M/hostapd_features"
	printf '%s\n' "$SC_HOSTAPD_VERSION" >"$M/hostapd_version"
	printf '%s\n' "$SC_ARCH" >"$M/pkgarch"
	{
		for _p in $SC_PKGS; do echo "$_p"; done
		[ -n "$SC_WPAD" ] && echo "$SC_WPAD"
	} >"$M/pkg/installed"
	for _p in $SC_AVAILABLE; do echo "$_p"; done >"$M/pkg/available"
	[ "$SC_INTERNET" = 1 ] && touch "$M/net/internet"
	[ "$SC_DNS" = 1 ] && touch "$M/net/dns"
	echo "$SC_GATEWAY" >"$M/net/gateway"
	echo "$SC_LANIP" >"$M/net/lanip"
	mkdir -p "$M/ubus/system" "$M/ubus/network.interface.lan"
	printf '{"kernel":"%s","hostname":"OpenWrt","system":"%s","model":"%s","board_name":"%s","release":{"distribution":"OpenWrt","version":"%s","target":"%s"}}\n' \
		"$SC_KERNEL" "$SC_CPU" "$SC_MODEL" "$SC_BOARD" "$SC_OS" "$SC_TARGET" >"$M/ubus/system/board.json"
	printf '{"up": true, "ipv4-address": [{"address": "%s", "mask": 24}]}\n' "$SC_LANIP" >"$M/ubus/network.interface.lan/status.json"
	for _svc in dnsmasq roamctl; do
		cp "$MOCK_LIB/mock-init" "$R/etc/init.d/$_svc"
		chmod +x "$R/etc/init.d/$_svc"
	done
	touch "$M/svc/dnsmasq.running"
	for _p in $SC_PKGS; do
		case "$_p" in usteer | dawn) "$MOCK_LIB/postinst.sh" "$_p" >/dev/null 2>&1 ;; esac
	done
	# shellcheck disable=SC2034
	type sc_post >/dev/null 2>&1 && sc_post
	# hostapd binary presence is controlled by the fixture PATH (fx_path)
	PATH="$(fx_path)" wifi up >/dev/null
}

list_has() {
	for _lh in $1; do [ "$_lh" = "$2" ] && return 0; done
	return 1
}

# PATH for the fixture: mock bin (minus disabled tools), busybox applets
# in busybox mode, then the system PATH.
fx_path() {
	_fb="$MOCK_DIR/bin"
	if [ ! -d "$_fb" ]; then
		mkdir -p "$_fb"
		for _t in "$MOCK_BIN"/*; do
			_n=$(basename "$_t")
			list_has "${FXO_NO_CMDS:-}" "$_n" && continue
			ln -s "$_t" "$_fb/$_n"
		done
	fi
	if [ -n "${BB_BIN:-}" ]; then
		printf '%s:%s:%s' "$_fb" "$BB_BIN" "$SYS_PATH"
	else
		printf '%s:%s' "$_fb" "$SYS_PATH"
	fi
}

# Run roamctl inside the fixture. Sets OUT (stdout), ERR (stderr), RC.
rc_run() {
	_o="$FX/out.$$" _e="$FX/err.$$"
	PATH="$(fx_path)" ORM_COLOR=never ORM_SETTLE_MIN=0 ORM_SETTLE_TIMEOUT=4 ORM_LOCK_WAIT=2 \
		ORM_WATCHDOG_TIMEOUT=${ORM_WATCHDOG_TIMEOUT:-60} \
		$TEST_SH "$ORM_REPO/roamctl" "$@" </dev/null >"$_o" 2>"$_e"
	RC=$?
	OUT=$(cat "$_o")
	ERR=$(cat "$_e")
	rm -f "$_o" "$_e"
	[ -n "${TEST_DEBUG:-}" ] && printf '%s\n%s\n' "$OUT" "$ERR" >&2
	return 0
}

# Run a shell snippet with all roamctl modules loaded (unit tests)
mod_run() {
	_o="$FX/out.$$" _e="$FX/err.$$"
	PATH="$(fx_path)" ORM_COLOR=never ORM_SETTLE_MIN=0 ORM_SETTLE_TIMEOUT=4 \
		$TEST_SH -c '
		ORM_ROOT=$ORM_REPO
		for m in core/common.sh core/logger.sh core/json.sh core/report.sh core/system_detect.sh core/hardware_detect.sh \
			core/wireless_detect.sh core/package_manager.sh core/compatibility.sh core/config_engine.sh \
			core/backup_manager.sh core/rollback_manager.sh roaming/mobility_domain.sh roaming/ieee80211k.sh \
			roaming/ieee80211v.sh roaming/ieee80211r.sh roaming/neighbor_report.sh roaming/roaming_validator.sh \
			steering/backend_interface.sh steering/steering_optimizer.sh steering/policy.sh steering/usteer_backend.sh \
			steering/dawn_backend.sh steering/native_backend.sh steering/band_steering.sh steering/steering_manager.sh \
			multiap/key_manager.sh multiap/ssh_manager.sh multiap/topology_manager.sh multiap/ap_discovery.sh \
			multiap/ap_sync.sh diagnostics/hardware_test.sh diagnostics/package_test.sh diagnostics/config_test.sh \
			diagnostics/hostapd_test.sh diagnostics/roaming_test.sh diagnostics/steering_test.sh \
			diagnostics/connectivity_test.sh core/orchestrator.sh; do . "$ORM_REPO/$m"; done
		ensure_dir "$ORM_STATE"
		'"$1" </dev/null >"$_o" 2>"$_e"
	RC=$?
	OUT=$(cat "$_o")
	ERR=$(cat "$_e")
	rm -f "$_o" "$_e"
	[ -n "${TEST_DEBUG:-}" ] && printf '%s\n%s\n' "$OUT" "$ERR" >&2
	return 0
}

# uci inside the fixture
fx_uci() {
	PATH="$(fx_path)" uci -c "$ORM_SYSROOT/etc/config" "$@"
}

fx_host_uci() {
	# fx_host_uci HOST args...
	_h=$1
	shift
	PATH="$(fx_path)" uci -c "$FX_BASE/hosts/$_h/root/etc/config" "$@"
}

fx_actions() {
	cat "$MOCK_DIR/actions.log" 2>/dev/null
}
