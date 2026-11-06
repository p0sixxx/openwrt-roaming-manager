#!/bin/sh
# Simulates package installation side effects (files, init scripts,
# auto enable + start like OpenWrt does for new services).
R=$ORM_SYSROOT
case "$1" in
usteer)
	mkdir -p "$R/sbin" "$R/etc/config" "$R/etc/init.d"
	touch "$R/sbin/usteerd"; chmod +x "$R/sbin/usteerd"
	[ -f "$R/etc/config/usteer" ] || printf "\nconfig usteer\n\toption network 'lan'\n\toption syslog '1'\n\toption local_mode '0'\n\toption ipv6 '0'\n\toption debug_level '2'\n" >"$R/etc/config/usteer"
	cp "$MOCK_LIB/mock-init" "$R/etc/init.d/usteer"; chmod +x "$R/etc/init.d/usteer"
	"$R/etc/init.d/usteer" enable; "$R/etc/init.d/usteer" start ;;
dawn)
	mkdir -p "$R/usr/sbin" "$R/etc/config" "$R/etc/init.d"
	touch "$R/usr/sbin/dawn"; chmod +x "$R/usr/sbin/dawn"
	cp "$MOCK_LIB/dawn.config" "$R/etc/config/dawn"
	cp "$MOCK_LIB/mock-init" "$R/etc/init.d/dawn"; chmod +x "$R/etc/init.d/dawn"
	"$R/etc/init.d/dawn" enable; "$R/etc/init.d/dawn" start ;;
esac
exit 0
