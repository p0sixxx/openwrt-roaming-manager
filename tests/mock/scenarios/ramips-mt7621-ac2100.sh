# OpenWrt 25.12 on MediaTek MT7621 with MT7603E + MT7615E (4x4 5 GHz),
# apk: Xiaomi Redmi Router AC2100
SC_OS=25.12.0
SC_PKG=apk
SC_TARGET=ramips/mt7621
SC_ARCH=mipsel_24kc
SC_MODEL="Xiaomi Redmi Router AC2100"
SC_BOARD=xiaomi,redmi-router-ac2100
SC_COMPAT="xiaomi,redmi-router-ac2100 mediatek,mt7621-soc"
SC_CPU="MIPS 1004Kc V2.15"
SC_CORES=4
SC_MEM_KB=124000
SC_FLASH_FREE_KB=95000
SC_PHYS="phy0:mt7603e:2g phy1:mt7615e:5g"
SC_FEATURES="11r sae eap 11ac"
SC_BASEMAC=02:21:00:00
sc_wireless() {
	sc_wireless_default | sed -e "s/HE20/HT20/" -e "s/HE80/VHT80/"
}
