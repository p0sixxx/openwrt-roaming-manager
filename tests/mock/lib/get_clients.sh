#!/bin/sh
# get_clients for a BSS: $MOCK_DIR/clients/<ifname>.json, optionally gated by
# $MOCK_DIR/roam_plan lines "<from> <to> <ifname> <mac> <signal>".
# from/to are epochs, or "+N" seconds relative to the first client poll of
# the main AP (shared anchor file), which keeps live tests independent of
# how long detection takes on a slow machine.
ifn=$1 freq=$2
if [ -f "$MOCK_DIR/roam_plan" ]; then
	t=$(date +%s)
	anchor_dir=$MOCK_DIR
	main=1
	if [ -n "${MOCK_HOSTS:-}" ]; then
		anchor_dir="$(dirname "$MOCK_HOSTS")/main/mock"
		[ "$MOCK_DIR" = "$anchor_dir" ] || main=0
	fi
	anchor=$(cat "$anchor_dir/live_anchor" 2>/dev/null)
	if [ -z "$anchor" ] && [ "$main" = 1 ]; then
		anchor=$t
		echo "$t" >"$anchor_dir/live_anchor"
	fi
	printf '{"freq": %s, "clients": {' "$freq"
	first=1
	while read -r from to i mac sig; do
		[ "$i" = "$ifn" ] || continue
		case "$from$to" in
		*+*)
			[ -n "$anchor" ] || continue
			from=$((anchor + ${from#+})) to=$((anchor + ${to#+}))
			;;
		esac
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
