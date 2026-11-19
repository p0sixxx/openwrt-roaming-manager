# Deployment target: Netis NX30 V2 (MT7981B) as second access point, OpenWrt 25.12, apk
SC_OS=25.12.6
SC_PKG=apk
SC_TARGET=mediatek/filogic
SC_ARCH=aarch64_cortex-a53
SC_MODEL="netis NX30 V2"
SC_BOARD=netis,nx30v2
SC_COMPAT="netis,nx30v2 mediatek,mt7981b mediatek,mt7981"
SC_KERNEL=6.12.40
SC_PHYS="phy0:mt7986-wmac:2g phy1:mt7986-wmac:5g"
SC_WPAD=wpad-basic-mbedtls
SC_FEATURES="11r sae owe 11ax 11ac acs"
SC_BASEMAC=02:a4:00:00
SC_FLASH_FREE_KB=90000
SC_MEM_KB=240000
SC_LANIP=192.168.1.2
SC_GATEWAY=192.168.1.1
sc_wireless() {
	sc_wireless_default | sed -e "s/option channel '1'/option channel '11'/" -e "s/option channel '36'/option channel '149'/"
}
