#!/bin/sh
# Where the RAM goes: totals plus the ten largest process groups (PSS, MB).
free -m
echo
for p in /proc/[0-9]*; do
	pss=$(awk '/^Pss:/{print $2}' "$p/smaps_rollup" 2>/dev/null) || continue
	[ -n "$pss" ] && echo "$pss $(cat "$p/comm")"
done | awk '{s[$2]+=$1} END {for (c in s) printf "%7.1f %s\n", s[c]/1024, c}' \
	| sort -rn | head -n 10
