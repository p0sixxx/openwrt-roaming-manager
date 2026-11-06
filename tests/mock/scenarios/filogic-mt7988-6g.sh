# OpenWrt 25.12 on MediaTek Filogic 880 (MT7988A + MT7996 tri-band, 6 GHz), WPA3
SC_OS=25.12.0
SC_PKG=apk
SC_MODEL="Banana Pi BPI-R4"
SC_BOARD=bananapi,bpi-r4
SC_COMPAT="bananapi,bpi-r4 mediatek,mt7988a"
SC_PHYS="phy0:mt7996e:2g phy1:mt7996e:5g phy2:mt7996e:6g"
SC_ENC=sae
SC_FEATURES="11r sae eap owe 11ax 11ac 11be acs"
SC_BASEMAC=02:88:00:00
sc_wireless() {
	cat <<W

config wifi-device 'radio0'
	option type 'mac80211'
	option band '2g'
	option channel '6'
	option htmode 'EHT20'

config wifi-device 'radio1'
	option type 'mac80211'
	option band '5g'
	option channel '36'
	option htmode 'EHT160'

config wifi-device 'radio2'
	option type 'mac80211'
	option band '6g'
	option channel '37'
	option htmode 'EHT320'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'Lab6E'
	option encryption 'sae-mixed'
	option key '$SC_KEY'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'Lab6E'
	option encryption 'sae-mixed'
	option key '$SC_KEY'

config wifi-iface 'default_radio2'
	option device 'radio2'
	option network 'lan'
	option mode 'ap'
	option ssid 'Lab6E'
	option encryption 'sae-mixed'
	option key '$SC_KEY'
W
}
