#!/bin/sh
# get_clients for a BSS: $MOCK_DIR/clients/<ifname>.json, optionally gated by
# $MOCK_DIR/roam_plan lines "<from_epoch> <to_epoch> <ifname> <mac> <signal>"
ifn=$1 freq=$2
if [ -f "$MOCK_DIR/roam_plan" ]; then
	t=$(date +%s)
	printf '{"freq": %s, "clients": {' "$freq"
	first=1
	while read -r from to i mac sig; do
		[ "$i" = "$ifn" ] || continue
		[ "$t" -ge "$from" ] && [ "$t" -lt "$to" ] || continue
		[ "$first" = 1 ] || printf ','
		first=0
		printf '"%s": {"auth": true, "assoc": true, "authorized": true, "rrm": [115,0,0,0,0], "extended_capabilities": [4,0,8,0], "signal": %s}' "$mac" "$sig"
	done <"$MOCK_DIR/roam_plan"
	printf '}}\n'
	exit 0
fi
if [ -f "$MOCK_DIR/clients/$ifn.json" ]; then
	cat "$MOCK_DIR/clients/$ifn.json"
else
	printf '{"freq": %s, "clients": {}}\n' "$freq"
fi
