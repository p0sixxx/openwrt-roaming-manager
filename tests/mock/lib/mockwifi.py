#!/usr/bin/env python3
"""Mock of OpenWrt netifd + hostapd for the roamctl test-suite.

`wifi [reload|up|down]` reads the (mock) UCI wireless configuration and
produces what a real OpenWrt system would expose afterwards:

  * /var/run/hostapd-phyN.conf generated like the netifd handler would
  * ubus objects: network.wireless (status) and hostapd.<ifname>
  * /sys/class/net/<ifname>/{address,phy80211/name}
  * iw/iwinfo data for the running interfaces

Scenario behaviour is controlled through $MOCK_DIR/scenario.env:
  SC_HANDLER       ucode | legacy | none   (UCI -> hostapd translation)
  SC_UCI_UNSUPPORTED  options the handler ignores
  SC_WNM, SC_RRM   1/0  hostapd built with WNM / exports rrm_* methods
  SC_REJECT        options that make hostapd fail on a radio when enabled
  SC_WIFI_FAIL     1 -> every radio fails to come up
  SC_BASEMAC       first 4 octets of generated BSSIDs
  SC_NOISE         noise floor reported by iwinfo
"""
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

ROOT = os.environ.get("ORM_SYSROOT", "")
MOCK = os.environ["MOCK_DIR"]


def env():
    e = {}
    p = os.path.join(MOCK, "scenario.env")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            e[k] = v.strip().strip("'\"")
    return e


E = env()
FEATURES = open(os.path.join(MOCK, "hostapd_features")).read().split() if os.path.exists(
    os.path.join(MOCK, "hostapd_features")) else []


def log(msg):
    os.makedirs(os.path.join(MOCK, "log"), exist_ok=True)
    with open(os.path.join(MOCK, "log", "messages"), "a") as f:
        f.write(time.strftime("%a %b %d %H:%M:%S %Y") + " " + msg + "\n")


def uci_show(cfg):
    confdir = os.environ.get("ORM_UCI_CONFDIR") or (ROOT + "/etc/config")
    out = subprocess.run(["uci", "-c", confdir, "-X", "show", cfg], capture_output=True, text=True).stdout
    secs, order = {}, []
    for line in out.splitlines():
        key, _, val = line.partition("=")
        parts = key.split(".")
        if len(parts) == 2:
            secs[parts[1]] = {"_type": val, "_name": parts[1]}
            order.append(parts[1])
        elif len(parts) == 3:
            vals = shlex.split(val)
            secs[parts[1]][parts[2]] = vals if len(vals) > 1 or val.count("' '") else (vals[0] if vals else "")
    return [secs[s] for s in order]


def lst(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def write(path, content, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, mode)


def script(path, body):
    write(path, "#!/bin/sh\n" + body, 0o755)


def opclass(band, ht, ch):
    width = 20
    for w in (320, 160, 80, 40):
        if ht and str(w) in ht:
            width = w
            break
    if band == "2g":
        return 81
    if band == "6g":
        return {20: 131, 40: 132, 80: 133, 160: 134, 320: 137}[width]
    return {20: 115 if ch < 52 else 118, 40: 116, 80: 128, 160: 129, 320: 129}[width]


def phytype(band, ht):
    ht = ht or ""
    if ht.startswith("EHT"):
        return 15
    if ht.startswith("HE"):
        return 14
    if band == "2g":
        return 7
    return 9


def akm(enc, ft):
    enc = enc or "none"
    base, ftk = [], []
    if enc.startswith("sae-mixed") or enc.startswith("psk2+sae"):
        base, ftk = ["WPA-PSK", "SAE"], ["FT-PSK", "FT-SAE"]
    elif enc.startswith("sae"):
        base, ftk = ["SAE"], ["FT-SAE"]
    elif enc.startswith("psk"):
        base, ftk = ["WPA-PSK"], ["FT-PSK"]
    elif enc.startswith("wpa"):
        base, ftk = ["WPA-EAP"], ["FT-EAP"]
    else:
        return ""
    return " ".join(base + (ftk if ft else []))


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "reload"
    handler = E.get("SC_HANDLER", "ucode")
    unsupported = E.get("SC_UCI_UNSUPPORTED", "").split()
    reject = E.get("SC_REJECT", "").split()
    base = E.get("SC_BASEMAC", "02:00:00:00")
    ubus = os.path.join(MOCK, "ubus")
    os.makedirs(ubus, exist_ok=True)
    log_actions = os.environ.get("MOCK_LOG")
    if log_actions:
        with open(log_actions, "a") as f:
            f.write("wifi %s\n" % action)

    # remove previous runtime state
    for d in os.listdir(ubus):
        if d.startswith("hostapd."):
            shutil.rmtree(os.path.join(ubus, d))
    for f in os.listdir(ROOT + "/var/run") if os.path.isdir(ROOT + "/var/run") else []:
        if f.startswith("hostapd-") and f.endswith(".conf"):
            os.remove(os.path.join(ROOT + "/var/run", f))
    netdir = ROOT + "/sys/class/net"
    if os.path.isdir(netdir):
        for d in os.listdir(netdir):
            if d.startswith("phy"):
                shutil.rmtree(os.path.join(netdir, d))

    cfg = uci_show("wireless")
    radios = [s for s in cfg if s["_type"] == "wifi-device"]
    ifaces = [s for s in cfg if s["_type"] == "wifi-iface"]
    status = {}
    iwdev = []
    for idx, r in enumerate(radios):
        rname = r["_name"]
        phy = r.get("phy") or "phy%d" % idx
        band = r.get("band", "2g")
        ht = r.get("htmode", "HT20")
        ch = r.get("channel", "auto")
        ch = int(ch) if str(ch).isdigit() else {"2g": 1, "5g": 36, "6g": 37}.get(band, 1)
        freq = {"2g": 2407 + 5 * ch, "5g": 5000 + 5 * ch, "6g": 5950 + 5 * ch}.get(band, 2412)
        disabled = r.get("disabled") == "1" or action == "down"
        members = [i for i in ifaces if i.get("device") == rname and i.get("disabled") != "1"]
        rstat = {"up": False, "pending": False, "autostart": True, "disabled": disabled,
                 "retry_setup_failed": False, "config": {"band": band, "channel": str(ch), "htmode": ht},
                 "interfaces": []}
        status[rname] = rstat
        if disabled:
            continue
        failed = E.get("SC_WIFI_FAIL") == "1"
        for i in members:
            for opt in reject:
                if str(i.get(opt, "")) not in ("", "0"):
                    failed = True
                    log("daemon.err hostapd: Line 42: unknown configuration item '%s'" % opt)
        conf_lines = []
        apn = 0
        for i in members:
            mode = i.get("mode", "ap")
            if mode != "ap":
                continue
            ifname = i.get("ifname") or "%s-ap%d" % (phy, apn)
            bssid = "%s:%02x:%02x" % (base, idx, apn)
            apn += 1
            rstat["interfaces"].append({"section": i["_name"], "ifname": ifname,
                                        "config": {"mode": "ap", "ssid": i.get("ssid", "")}, "vlans": [], "stations": []})
            if failed:
                continue

            def opt(name, default=None):
                if name in unsupported:
                    return default
                return i.get(name, default)
            ft = opt("ieee80211r", "0") == "1" and "11r" in FEATURES and handler != "none"
            enc = i.get("encryption", "none")
            lines = ["%s=%s" % ("interface" if not conf_lines else "bss", ifname),
                     "ssid=%s" % i.get("ssid", ""), "bssid=%s" % bssid]
            k = akm(enc, ft)
            if k:
                lines.append("wpa_key_mgmt=%s" % k)
            if ft:
                md = opt("mobility_domain") or hashlib.md5(i.get("ssid", "").encode()).hexdigest()[:4]
                lines += ["mobility_domain=%s" % md, "ft_over_ds=%s" % opt("ft_over_ds", "0"),
                          "nas_identifier=%s" % bssid.replace(":", ""),
                          "reassociation_deadline=%s" % opt("reassociation_deadline", "1000")]
                if opt("ft_psk_generate_local", "0") == "1":
                    lines.append("ft_psk_generate_local=1")
                for e in lst(opt("r0kh")):
                    lines.append("r0kh=%s" % e.replace(",", " "))
                for e in lst(opt("r1kh")):
                    lines.append("r1kh=%s" % e.replace(",", " "))
            rrm_nr = opt("rrm_neighbor_report", opt("ieee80211k", "0"))
            rrm_bc = opt("rrm_beacon_report", opt("ieee80211k", "0"))
            if handler != "none" and rrm_nr == "1":
                lines.append("rrm_neighbor_report=1")
            if handler != "none" and rrm_bc == "1":
                lines.append("rrm_beacon_report=1")
            btm = opt("bss_transition", "0") == "1"
            if handler == "legacy" and opt("ieee80211v", "0") != "1":
                btm = False
            if handler != "none" and btm and E.get("SC_WNM", "1") == "1":
                lines.append("bss_transition=1")
            conf_lines += lines

            # runtime objects
            write("%s/sys/class/net/%s/address" % (ROOT, ifname), bssid + "\n")
            write("%s/sys/class/net/%s/phy80211/name" % (ROOT, ifname), phy + "\n")
            o = os.path.join(ubus, "hostapd." + ifname)
            os.makedirs(o, exist_ok=True)
            oc = opclass(band, ht, ch)
            nr = bssid.replace(":", "") + "8f090000" + "%02x%02x%02x" % (oc, ch, phytype(band, ht))
            write(o + "/get_status.json", json.dumps({"status": "ENABLED", "bssid": bssid, "ssid": i.get("ssid", ""),
                                                      "freq": freq, "channel": ch, "op_class": oc}) + "\n")
            script(o + "/get_clients.sh", 'exec "$MOCK_LIB/get_clients.sh" %s %d\n' % (shlex.quote(ifname), freq))
            script(o + "/del_client.sh", 'echo "del_client %s $1" >> "$MOCK_DIR/actions.log"\n' % ifname)
            write(o + "/reload.json", "{}\n")
            if E.get("SC_RRM", "1") == "1":
                write(o + "/rrm_nr_get_own.json", json.dumps({"value": [bssid, i.get("ssid", ""), nr]}) + "\n")
                script(o + "/rrm_nr_set.sh", 'printf "%%s\\n" "$1" > "$(dirname "$0")/nr_list.state"\n'
                       'echo "rrm_nr_set %s" >> "$MOCK_DIR/actions.log"\n' % ifname)
                script(o + "/rrm_nr_list.sh",
                       'f="$(dirname "$0")/nr_list.state"; if [ -f "$f" ]; then cat "$f"; else echo \'{"list":[]}\'; fi\n')
                script(o + "/rrm_beacon_req.sh", 'echo "rrm_beacon_req %s $1" >> "$MOCK_DIR/actions.log"\n' % ifname)
                write(o + "/bss_mgmt_enable.json", "{}\n")
            if E.get("SC_WNM", "1") == "1":
                script(o + "/bss_transition_request.sh",
                       'echo "bss_transition_request %s $1" >> "$MOCK_DIR/actions.log"\n' % ifname)
                script(o + "/wnm_disassoc_imminent.sh",
                       'echo "wnm_disassoc_imminent %s $1" >> "$MOCK_DIR/actions.log"\n' % ifname)
            iwdev.append((phy, ifname, bssid, i.get("ssid", ""), ch, freq, ht))
            write("%s/iwinfo/%s.info" % (MOCK, ifname),
                  '%s     ESSID: "%s"\n          Access Point: %s\n          Mode: Master  Channel: %d (%.3f GHz)\n'
                  '          Tx-Power: 20 dBm  Link Quality: unknown/70\n          Signal: unknown  Noise: %s dBm\n'
                  '          Hardware: embedded [MediaTek MT7986]\n' % (ifname, i.get("ssid", ""), bssid.upper(), ch,
                                                                      freq / 1000.0, E.get("SC_NOISE", "-92")))
        if failed:
            log("daemon.err hostapd: %s: interface state UNINITIALIZED->DISABLED" % phy)
            continue
        rstat["up"] = True
        if conf_lines:
            write("%s/var/run/hostapd-%s.conf" % (ROOT, phy), "\n".join(conf_lines) + "\n")
            log("daemon.notice hostapd: %s: interface state COUNTRY_UPDATE->ENABLED" % phy)

    write(os.path.join(ubus, "network.wireless", "status.json"), json.dumps(status, indent=1) + "\n")
    out = []
    for phy in sorted(set(d[0] for d in iwdev)):
        out.append("phy#%s" % phy[3:])
        for d in [x for x in iwdev if x[0] == phy]:
            w = "".join(c for c in (d[6] or "20") if c.isdigit()) or "20"
            out.append("\tInterface %s\n\t\tifindex 10\n\t\twdev 0x1\n\t\taddr %s\n\t\tssid %s\n\t\ttype AP\n"
                       "\t\tchannel %d (%d MHz), width: %s MHz, center1: %d MHz" % (d[1], d[2], d[3], d[4], d[5], w, d[5]))
    write(os.path.join(MOCK, "iw", "dev.txt"), "\n".join(out) + "\n")
    # a running usteer re-registers the new BSSes and redistributes neighbors
    for svc in ("usteer", "dawn"):
        if os.path.exists(os.path.join(MOCK, "svc", svc + ".running")):
            subprocess.run([os.path.join(os.environ["MOCK_LIB"], "svc_hook.sh"), svc, "start"])


if __name__ == "__main__":
    main()
