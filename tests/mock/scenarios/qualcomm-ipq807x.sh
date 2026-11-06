# OpenWrt 24.10 on Qualcomm IPQ8074 (ath11k, Dynalink DL-WRX36), full wpad
SC_OS=24.10.1
SC_TARGET=qualcommax/ipq807x
SC_ARCH=aarch64_cortex-a53
SC_MODEL="Dynalink DL-WRX36"
SC_BOARD=dynalink,dl-wrx36
SC_COMPAT="dynalink,dl-wrx36 qcom,ipq8074"
SC_PHYS="phy0:ath11k:5g phy1:ath11k:2g"
SC_WPAD=wpad-mbedtls
SC_PKGS="base-files busybox dnsmasq dropbear firewall4 iw iwinfo kmod-ath11k-ahb libubox ubus uci"
SC_BASEMAC=02:44:00:00
sc_wireless() {
	sc_wireless_default | sed -e "s/option band '2g'/option band 'TMP'/" -e "s/option band '5g'/option band '2g'/" \
		-e "s/option band 'TMP'/option band '5g'/" -e "s/option channel '1'/option channel '149'/" \
		-e "s/option channel '36'/option channel '6'/"
}
