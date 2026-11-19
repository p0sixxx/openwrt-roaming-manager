# Deployment target: Routerich AX3000 v1 (MT7981B + MT7976CN), OpenWrt 25.12, apk
SC_OS=25.12.6
SC_PKG=apk
SC_TARGET=mediatek/filogic
SC_ARCH=aarch64_cortex-a53
SC_MODEL="Routerich AX3000 v1"
SC_BOARD=routerich,ax3000-v1
SC_COMPAT="routerich,ax3000-v1 mediatek,mt7981b mediatek,mt7981"
SC_KERNEL=6.12.40
SC_PHYS="phy0:mt7986-wmac:2g phy1:mt7986-wmac:5g"
SC_WPAD=wpad-basic-mbedtls
SC_FEATURES="11r sae owe 11ax 11ac acs"
SC_BASEMAC=02:a3:00:00
SC_FLASH_FREE_KB=90000
SC_MEM_KB=240000
