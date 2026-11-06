# shellcheck shell=sh
# OpenWrt Roaming Manager - backup manager
#
# A backup consists of three files in $ORM_BACKUP_DIR:
#   <id>.tar.gz  - /etc/config, /etc/roamctl (without backups) and any
#                  standalone hostapd configuration files
#   <id>.meta    - metadata: date, roamctl/OpenWrt version, reason, MDIDs,
#                  enabled services, sha256 of the archive
#   <id>.pkgs    - installed package list
# The backup directory is mode 0700 because the archive contains the
# Wi-Fi passphrases and FT keys exactly as /etc/config does.

backup_new_id() {
	printf '%s-%s' "$(date +%Y%m%d-%H%M%S)" "$(random_hex 2)"
}

backup_services() {
	local _svc
	# enabled state of services roamctl may touch
	for _svc in usteer dawn roamctl roamctl-steer; do
		[ -x "$(orm_path "/etc/init.d/$_svc")" ] || continue
		if svc_is_enabled "$_svc"; then
			printf '%s=1 ' "$_svc"
		else
			printf '%s=0 ' "$_svc"
		fi
	done
}

# backup_create REASON -> prints backup id
backup_create() {
	local _reason _id _base _root _list _f _files _mdids _g
	_reason=${1:-manual}
	ensure_dir "$ORM_BACKUP_DIR" 0700 || return 1
	_id=$(backup_new_id) || return 1
	_base="$ORM_BACKUP_DIR/$_id"
	_root=${ORM_SYSROOT:-/}

	# Commit pending changes of other tools? No - pending uci changes are
	# recorded as-is in the committed files only; warn the user.
	if [ -n "$(orm_uci changes 2>/dev/null)" ]; then
		log_warn "There are uncommitted UCI changes; the backup contains the committed configuration only"
	fi

	_list="etc/config"
	[ -d "$_root/etc/roamctl" ] && _list="$_list etc/roamctl"
	for _f in "$_root"/etc/hostapd*.conf "$_root"/etc/hostapd*/; do
		[ -e "$_f" ] && _list="$_list ${_f#"$_root"/}"
	done
	# shellcheck disable=SC2086
	if ! (cd "$_root" && tar -czf "$_base.tar.gz.tmp" --exclude 'etc/roamctl/backups' $_list) 2>>"$ORM_LOG"; then
		# BusyBox tar without --exclude support: build the list manually
		_files=$(cd "$_root" && find $_list -type f ! -path 'etc/roamctl/backups/*' 2>/dev/null)
		# shellcheck disable=SC2086
		(cd "$_root" && tar -czf "$_base.tar.gz.tmp" $_files) 2>>"$ORM_LOG" || {
			rm -f "$_base.tar.gz.tmp"
			log_error "Backup archive creation failed"
			return 1
		}
	fi
	chmod 600 "$_base.tar.gz.tmp"
	mv -f "$_base.tar.gz.tmp" "$_base.tar.gz"
	pkg_save_list "$_base.pkgs" 2>/dev/null || : >"$_base.pkgs"
	chmod 600 "$_base.pkgs"

	_mdids=''
	for _g in $(roam_groups); do
		_mdids="$_mdids $_g:$(roam_get "$_g.mdid")"
	done
	{
		printf 'id=%s\n' "$_id"
		printf 'date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf 'epoch=%s\n' "$(now)"
		printf 'reason=%s\n' "$_reason"
		printf 'roamctl=%s\n' "$ORM_VERSION"
		printf 'openwrt=%s\n' "$(caps_get os.version unknown)"
		printf 'model=%s\n' "$(caps_get board.model unknown)"
		printf 'mdids=%s\n' "${_mdids# }"
		printf 'services=%s\n' "$(backup_services)"
		printf 'sha256=%s\n' "$(sha256sum "$_base.tar.gz" | cut -d' ' -f1)"
	} | atomic_write "$_base.meta" 600
	backup_prune
	log_ok "Backup created: $_id"
	printf '%s' "$_id"
}

backup_list() {
	local _bm
	for _bm in "$ORM_BACKUP_DIR"/*.meta; do
		[ -f "$_bm" ] || continue
		_bm=${_bm##*/}
		printf '%s\n' "${_bm%.meta}"
	done | sort
}

backup_latest() {
	backup_list | tail -n1
}

backup_meta() {
	kv_get "$ORM_BACKUP_DIR/$1.meta" "$2"
}

# Integrity: checksum + archive readability + mandatory content
backup_verify() {
	local _id _base _want _have
	_id=$1
	_base="$ORM_BACKUP_DIR/$_id"
	[ -f "$_base.meta" ] && [ -f "$_base.tar.gz" ] || {
		log_error "Backup $_id not found"
		return 1
	}
	_want=$(backup_meta "$_id" sha256)
	_have=$(sha256sum "$_base.tar.gz" | cut -d' ' -f1)
	if [ -z "$_want" ] || [ "$_want" != "$_have" ]; then
		log_error "Backup $_id failed checksum verification"
		return 1
	fi
	tar -tzf "$_base.tar.gz" 2>/dev/null | grep -q '^\(\./\)\{0,1\}etc/config/wireless$' || {
		log_error "Backup $_id does not contain etc/config/wireless"
		return 1
	}
	return 0
}

# backup_restore ID - restores configuration files atomically.
backup_restore() {
	local _id _root _tmp _c _f _dst _mode _known _kv _svc _en
	_id=$1
	backup_verify "$_id" || return 1
	_root=${ORM_SYSROOT:-/}
	_tmp=$(mktemp -d "${ORM_SYSROOT}/tmp/roamctl-restore.XXXXXX" 2>/dev/null) || {
		ensure_dir "${ORM_SYSROOT}/tmp"
		_tmp=$(mktemp -d "${ORM_SYSROOT}/tmp/roamctl-restore.XXXXXX") || return 1
	}
	if ! tar -xzf "$ORM_BACKUP_DIR/$_id.tar.gz" -C "$_tmp" 2>>"$ORM_LOG"; then
		rm -rf "$_tmp"
		log_error "Cannot extract backup $_id"
		return 1
	fi
	# Discard uncommitted UCI changes so they are not applied on top
	for _c in $(cd "$_tmp/etc/config" && ls -1); do
		orm_uci revert "$_c" 2>/dev/null
	done
	(cd "$_tmp" && find etc -type f) | while IFS= read -r _f; do
		_dst="$_root/$_f"
		ensure_dir "$(dirname "$_dst")"
		_mode=644
		case "$_f" in
		etc/roamctl/* | etc/config/wireless) _mode=600 ;;
		esac
		atomic_write "$_dst" "$_mode" <"$_tmp/$_f" || log_error "restore of $_f failed"
	done
	# Config files created after the backup by roamctl itself are removed
	# so the system returns to the exact previous state.
	[ -f "$_tmp/etc/config/roamctl" ] || rm -f "$ORM_UCI_CONFDIR/roamctl"
	if [ -d "$_root/etc/roamctl/keys" ] && [ ! -d "$_tmp/etc/roamctl/keys" ]; then
		rm -rf "$_root/etc/roamctl/keys"
	fi
	rm -rf "$_tmp"
	# Restore service enable state
	_known=$(backup_meta "$_id" services)
	for _kv in $_known; do
		_svc=${_kv%=*} _en=${_kv#*=}
		svc_set_enabled "$_svc" "$_en"
	done
	# steering daemons installed after the backup was taken are stopped
	# and disabled (packages are kept; removal needs explicit consent)
	for _svc in usteer dawn; do
		case " $_known" in *" $_svc="*) continue ;; esac
		[ -x "$(orm_path "/etc/init.d/$_svc")" ] && svc_set_enabled "$_svc" 0
	done
	log_ok "Configuration restored from backup $_id"
	return 0
}

backup_prune() {
	local _keep _n _old
	_keep=$(roam_get global.backup_keep 10)
	is_uint "$_keep" || _keep=10
	[ "$_keep" -lt 2 ] && _keep=2
	_n=$(backup_list | wc -l)
	[ "$_n" -le "$_keep" ] && return 0
	backup_list | head -n $((_n - _keep)) | while IFS= read -r _old; do
		# never prune the backup referenced by a pending rollback
		[ "$(kv_get "$ORM_ETC/pending" id)" = "$_old" ] && continue
		rm -f "$ORM_BACKUP_DIR/$_old".*
		log_debug "pruned backup $_old"
	done
}

# Enable/disable/start/stop an init service
svc_set_enabled() {
	local _svc _en _init
	_svc=$1 _en=$2
	_init=$(orm_path "/etc/init.d/$_svc")
	[ -x "$_init" ] || return 0
	[ "$ORM_DRYRUN" = 1 ] && return 0
	if [ "$_en" = 1 ]; then
		"$_init" enable >/dev/null 2>&1
		"$_init" restart >/dev/null 2>&1
	else
		"$_init" stop >/dev/null 2>&1
		"$_init" disable >/dev/null 2>&1
	fi
	return 0
}

svc_is_enabled() {
	local _init
	_init=$(orm_path "/etc/init.d/$1")
	[ -x "$_init" ] || return 1
	"$_init" enabled >/dev/null 2>&1
}

svc_is_running() {
	local _init
	_init=$(orm_path "/etc/init.d/$1")
	[ -x "$_init" ] || return 1
	"$_init" running >/dev/null 2>&1
}
