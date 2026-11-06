# OpenWrt 24.10 on Broadcom BCM2711 (Raspberry Pi 4, brcmfmac fullmac)
SC_OS=24.10.2
SC_TARGET=bcm27xx/bcm2711
SC_ARCH=aarch64_cortex-a72
SC_MODEL="Raspberry Pi 4 Model B Rev 1.4"
SC_BOARD=raspberrypi,4-model-b
SC_COMPAT="raspberrypi,4-model-b brcm,bcm2711"
SC_PHYS="phy0:brcmfmac:2g,5g"
SC_PKGS="base-files busybox dnsmasq dropbear iw iwinfo kmod-brcmfmac libubox ubus uci"
SC_BASEMAC=02:27:11:00
sc_wireless() {
	cat <<W

config wifi-device 'radio0'
	option type 'mac80211'
	option band '5g'
	option channel '36'
	option htmode 'VHT80'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid '$SC_SSID'
	option encryption 'psk2'
	option key '$SC_KEY'
W
}
