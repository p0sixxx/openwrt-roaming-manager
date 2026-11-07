# shellcheck shell=sh
# OpenWrt Roaming Manager - system detection
#
# Detects OpenWrt release, package manager, board, SoC, CPU architecture
# and kernel. Results are written to the capability store (caps_*).

# ---------------------------------------------------------- capability store
# Facts are kept in memory (ORM_CAPS, newline separated "key=value", last
# value wins) so lookups need no extra process - important on single core
# MIPS SoCs such as MT7628 where every fork costs milliseconds. The file
# copy is the source of truth for subshells and other processes; after a
# subshell may have written facts, caps_reload re-reads it.
ORM_CAPS=''

caps_file() {
	printf '%s/caps' "$ORM_STATE"
}

# Re-detection keeps run-scoped facts (run.* - e.g. the backup taken by
# this invocation) and drops everything else.
caps_reset() {
	local _cf _keep
	ensure_dir "$ORM_STATE" 0755
	_cf="$ORM_STATE/caps"
	_keep=''
	[ "${ORM_CAPS_INIT:-0}" = 1 ] && _keep=$(grep '^run\.' "$_cf" 2>/dev/null)
	ORM_CAPS_INIT=1
	if [ -n "$_keep" ]; then
		printf '%s\n' "$_keep" >"$_cf"
		ORM_CAPS="$ORM_NL$_keep"
	else
		: >"$_cf"
		ORM_CAPS=''
	fi
}

caps_reload() {
	ORM_CAPS="$ORM_NL$(cat "$ORM_STATE/caps" 2>/dev/null)"
}

caps_set() {
	local _cv
	_cv=$2
	case "$_cv" in
	*"$ORM_NL"*) _cv=$(printf '%s' "$_cv" | tr '\n' ' ') ;;
	esac
	ORM_CAPS="$ORM_CAPS$ORM_NL$1=$_cv"
	printf '%s=%s\n' "$1" "$_cv" >>"$ORM_STATE/caps"
}

# caps_v KEY [DEFAULT] -> sets CAPS_V without a subshell (for loops)
caps_v() {
	local _cg
	case "$ORM_CAPS" in
	*"$ORM_NL$1="*)
		_cg=${ORM_CAPS##*"$ORM_NL$1="}
		CAPS_V=${_cg%%"$ORM_NL"*}
		;;
	*)
		CAPS_V=${2:-}
		return 1
		;;
	esac
}

# caps_get KEY [DEFAULT] - last value wins
caps_get() {
	local _cg
	case "$ORM_CAPS" in
	*"$ORM_NL$1="*)
		_cg=${ORM_CAPS##*"$ORM_NL$1="}
		printf '%s' "${_cg%%"$ORM_NL"*}"
		;;
	*)
		printf '%s' "${2:-}"
		return 1
		;;
	esac
}

caps_is() {
	[ "$(caps_get "$1")" = "${2:-1}" ]
}

# Read a shell-style KEY='value' assignment from a file without sourcing it.
read_release_var() {
	# read_release_var FILE VAR
	sed -n "s/^$2=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}\$/\1/p" "$1" 2>/dev/null | head -n1
}

# ------------------------------------------------------------------ release
sysdet_release() {
	local _rel _osr _distrib _ver _target _arch _rev _series _major _support
	_rel=$(orm_path /etc/openwrt_release)
	_osr=$(orm_path /etc/os-release)
	_distrib='' _ver='' _target='' _arch='' _rev=''
	if [ -r "$_rel" ]; then
		_distrib=$(read_release_var "$_rel" DISTRIB_ID)
		_ver=$(read_release_var "$_rel" DISTRIB_RELEASE)
		_target=$(read_release_var "$_rel" DISTRIB_TARGET)
		_arch=$(read_release_var "$_rel" DISTRIB_ARCH)
		_rev=$(read_release_var "$_rel" DISTRIB_REVISION)
	elif [ -r "$_osr" ]; then
		_distrib=$(read_release_var "$_osr" ID)
		_ver=$(read_release_var "$_osr" VERSION_ID)
		_target=$(read_release_var "$_osr" OPENWRT_BOARD)
		_arch=$(read_release_var "$_osr" OPENWRT_ARCH)
	fi
	caps_set os.distrib "${_distrib:-unknown}"
	caps_set os.version "${_ver:-unknown}"
	caps_set os.target "${_target:-unknown}"
	caps_set os.pkgarch "${_arch:-unknown}"
	caps_set os.revision "${_rev:-unknown}"

	# Normalised series: 24.10, 25.12, snapshot, ...
	case "$_ver" in
	SNAPSHOT | snapshot) _series=snapshot ;;
	[0-9][0-9].[0-9]*) _series=$(printf '%s' "$_ver" | cut -d. -f1-2 | sed 's/-.*//') ;;
	*) _series=unknown ;;
	esac
	caps_set os.series "$_series"

	_major=$(printf '%s' "$_series" | cut -d. -f1)
	_support=untested
	case "$_series" in
	24.10) _support=supported ;;
	snapshot) _support=supported ;;
	unknown) _support=unknown ;;
	*)
		if is_uint "$_major"; then
			if [ "$_major" -ge 25 ]; then
				_support=supported
			elif [ "$_major" -ge 22 ]; then
				_support=best-effort
			else
				_support=unsupported
			fi
		fi
		;;
	esac
	caps_set os.support "$_support"
}

# --------------------------------------------------------- package manager
sysdet_pkgmgr() {
	local _pm
	# OpenWrt 25.x switched from opkg to apk (apk-tools v3). Detect the
	# binary that actually manages this root filesystem.
	_pm=none
	if have_cmd apk && { [ -d "$(orm_path /etc/apk)" ] || [ -d "$(orm_path /lib/apk)" ]; }; then
		_pm=apk
	elif have_cmd opkg; then
		_pm=opkg
	elif have_cmd apk; then
		_pm=apk
	fi
	caps_set pkg.manager "$_pm"
}

# -------------------------------------------------------------------- board
sysdet_board() {
	local _model _board _cpu _kernel _bj
	_model='' _board='' _cpu='' _kernel=''
	if have_cmd ubus; then
		_bj=$(ubus call system board 2>/dev/null)
		if [ -n "$_bj" ]; then
			_model=$(json_get "$_bj" model)
			_board=$(json_get "$_bj" board_name)
			_cpu=$(json_get "$_bj" system)
			_kernel=$(json_get "$_bj" kernel)
		fi
	fi
	[ -n "$_model" ] || _model=$(cat "$(orm_path /tmp/sysinfo/model)" 2>/dev/null)
	[ -n "$_board" ] || _board=$(cat "$(orm_path /tmp/sysinfo/board_name)" 2>/dev/null)
	[ -n "$_kernel" ] || _kernel=$(uname -r 2>/dev/null)
	caps_set board.model "${_model:-unknown}"
	caps_set board.name "${_board:-unknown}"
	caps_set board.cpu "${_cpu:-unknown}"
	caps_set kernel.version "${_kernel:-unknown}"
	caps_set kernel.uname "$(uname -a 2>/dev/null)"
	caps_set cpu.arch "$(uname -m 2>/dev/null)"

	sysdet_soc
}

# Identify the SoC from the device-tree "compatible" list (most specific
# entries come first, the SoC compatible is usually the last one).
sysdet_soc() {
	local _compat_file _compat _target _soc _vendor _family _c
	_compat_file=$(orm_path /proc/device-tree/compatible)
	_compat=''
	[ -r "$_compat_file" ] && _compat=$(tr '\000' ' ' <"$_compat_file")
	caps_set soc.compatible "${_compat:-unknown}"

	_target=$(caps_get os.target)
	_soc='' _vendor='' _family=''
	for _c in $_compat; do
		case "$_c" in
		mediatek,mt79[0-9][0-9]* | mediatek,mt76[0-9][0-9]* | mediatek,mt7622 | mediatek,mt7623* | ralink,mt7620*)
			_soc=$(upper "${_c#*,}") _vendor=MediaTek
			_soc=${_soc%-SOC} ;;
		qcom,ipq* | qcom,qca* | qcom,qcs*)
			_soc=$(upper "${_c#qcom,}") _vendor=Qualcomm ;;
		qca,ar* | qca,qca* | qca,tp9343)
			_soc=$(upper "${_c#qca,}") _vendor=Qualcomm ;;
		brcm,bcm*)
			_soc=$(upper "${_c#brcm,}") _vendor=Broadcom ;;
		realtek,rtl*)
			_soc=$(upper "${_c#realtek,}") _vendor=Realtek ;;
		marvell,armada*)
			_soc=$(printf '%s' "${_c#marvell,}") _vendor=Marvell ;;
		esac
	done

	case "$_soc" in
	MT7981*) _family="MediaTek Filogic 820" ;;
	MT7986*) _family="MediaTek Filogic 830" ;;
	MT7988*) _family="MediaTek Filogic 880" ;;
	MT7987*) _family="MediaTek Filogic" ;;
	MT7621*) _family="MediaTek MT7621 (ramips, MIPS 1004Kc)" ;;
	MT7628* | MT7688*) _family="MediaTek MT7628/MT7688 (ramips, MIPS 24KEc)" ;;
	MT7620*) _family="MediaTek MT7620 (ramips)" ;;
	IPQ807* | IPQ60* | IPQ50* | IPQ95* | IPQ53*) _family="Qualcomm IPQ (ath11k/ath12k)" ;;
	IPQ40*) _family="Qualcomm IPQ40xx (ath10k)" ;;
	esac
	if [ -z "$_family" ]; then
		case "$_target" in
		mediatek/filogic) _family="MediaTek Filogic" ;;
		qualcommax/* | ipq807x/*) _family="Qualcomm IPQ (ath11k/ath12k)" ;;
		ipq40xx/*) _family="Qualcomm IPQ40xx (ath10k)" ;;
		ath79/*) _family="Qualcomm Atheros (ath79)" ;;
		bcm27xx/* | bcm4908/* | bcm53xx/* | bcm47xx/* | bcm63xx/*) _family="Broadcom" ;;
		ramips/mt7621) _family="MediaTek MT7621 (ramips, MIPS 1004Kc)" ;;
		ramips/mt76x8) _family="MediaTek MT7628/MT7688 (ramips, MIPS 24KEc)" ;;
		ramips/*) _family="MediaTek MIPS (ramips)" ;;
		x86/*) _family="x86" ;;
		esac
	fi
	[ -n "$_vendor" ] || case "$_family" in
	MediaTek*) _vendor=MediaTek ;;
	Qualcomm*) _vendor=Qualcomm ;;
	Broadcom*) _vendor=Broadcom ;;
	esac
	caps_set soc.model "${_soc:-unknown}"
	caps_set soc.vendor "${_vendor:-unknown}"
	caps_set soc.family "${_family:-unknown}"
}

# CPU cores, RAM and free flash. "low" class devices (single core MIPS
# such as MT7628, or <= 64 MB RAM) get lighter defaults: longer daemon
# interval, fewer backups, usteer instead of DAWN.
sysdet_resources() {
	local _cores _mem _class _free
	_cores=$(grep -c '^processor' "$(orm_path /proc/cpuinfo)" 2>/dev/null)
	is_uint "$_cores" && [ "$_cores" -gt 0 ] || _cores=1
	_mem=$(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' "$(orm_path /proc/meminfo)" 2>/dev/null)
	is_uint "$_mem" || _mem=0
	_free=$(flash_free_kb)
	_class=normal
	case "$(caps_get cpu.arch) $(caps_get os.pkgarch)" in
	mips* | *" mips"*)
		[ "$_cores" -le 1 ] && _class=low
		;;
	esac
	[ "$_mem" -gt 0 ] && [ "$_mem" -le 65536 ] && _class=low
	caps_set cpu.cores "$_cores"
	caps_set mem.total_kb "$_mem"
	caps_set flash.free_kb "${_free:-unknown}"
	caps_set device.class "$_class"
}

# Free space (KB) of the writable overlay (or / on images without one)
flash_free_kb() {
	local _m _f
	for _m in /overlay /; do
		[ -d "$(orm_path "$_m")" ] || [ -n "$ORM_SYSROOT" ] || continue
		_f=$(df -Pk "$(orm_path "$_m")" 2>/dev/null | awk 'NR == 2 { print $4; exit }')
		if is_uint "$_f"; then
			printf '%s' "$_f"
			return 0
		fi
	done
	return 1
}

sysdet_all() {
	sysdet_release
	sysdet_pkgmgr
	sysdet_board
	sysdet_resources
}
