# OpenWrt 24.10 on MediaTek MT7621 (ramips, MIPS 1004Kc dual core) with
# MT7603E (2.4 GHz) + MT7612E (5 GHz): Xiaomi Mi Router 4A Gigabit Edition
SC_OS=24.10.2
SC_TARGET=ramips/mt7621
SC_ARCH=mipsel_24kc
SC_MODEL="Xiaomi Mi Router 4A Gigabit Edition"
SC_BOARD=xiaomi,mi-router-4a-gigabit
SC_COMPAT="xiaomi,mi-router-4a-gigabit mediatek,mt7621-soc"
SC_CPU="MIPS 1004Kc V2.15"
SC_CORES=4
SC_MEM_KB=124000
SC_FLASH_FREE_KB=8200
SC_PHYS="phy0:mt7603e:2g phy1:mt76x2e:5g"
SC_FEATURES="11r sae eap 11ac"
SC_PKGS="base-files busybox dnsmasq dropbear firewall4 iwinfo kmod-mt7603 kmod-mt76x2 libubox ubus uci"
SC_BASEMAC=02:76:21:00
sc_wireless() {
	sc_wireless_default | sed -e "s/HE20/HT20/" -e "s/HE80/VHT80/"
}
