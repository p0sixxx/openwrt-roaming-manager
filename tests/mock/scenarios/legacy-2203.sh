# OpenWrt 22.03 on Qualcomm Atheros ath79 (ath9k + ath10k), shell netifd handler
SC_OS=22.03.7
SC_TARGET=ath79/generic
SC_ARCH=mips_24kc
SC_MODEL="TP-Link Archer C7 v5"
SC_BOARD=tplink,archer-c7-v5
SC_COMPAT="tplink,archer-c7-v5 qca,qca9563"
SC_PHYS="phy0:ath10k_pci:5g phy1:ath9k:2g"
SC_HANDLER=legacy
SC_FEATURES="11r sae eap 11ac"
SC_HOSTAPD_VERSION=2.10
SC_WPAD=wpad-basic-wolfssl
SC_BASEMAC=02:c7:00:00
sc_wireless() {
	sc_wireless_default | sed -e "s/option band '2g'/option band 'TMP'/" -e "s/option band '5g'/option band '2g'/" \
		-e "s/option band 'TMP'/option band '5g'/" -e "s/HE20/VHT80/" -e "s/HE80/HT20/" \
		-e "s/option channel '36'/option channel '6'/" -e "s/option channel '1'/option channel '36'/"
}
