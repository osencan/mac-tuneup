#!/bin/bash
# mac-tuneup: read-only check of why iCloud Photos downloads fail or crawl
# (Photos export errors like "Unknown error (-1009)" = no internet at that
# moment, or "Could not download from iCloud"). Covers sleep/wake events,
# active network and VPNs, reachability of iCloud, Apple's networkQuality
# speed test and Photos/iCloud errors in the system log. Changes nothing.
#
#   bash network-check.sh > /dev/null 2>&1     report in ./network-<date>.txt
#
# Takes 2-4 minutes. Set BACKUP_DIR to also show the backup disk's free space.

OUTDIR="${OUTDIR:-$PWD}"   # reports go to the current folder unless OUTDIR is set
OUT="$OUTDIR/network-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1
t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
hdr() { echo; echo "=== $* ==="; }

echo "Report started $(date '+%Y-%m-%d %H:%M:%S')"

hdr "1. Sleep settings and what kept the Mac awake"
pmset -g | grep -E "SleepDisabled|^ sleep|displaysleep|powernap|tcpkeepalive|networkoversleep" | sed 's/^ */  /'
pmset -g assertions | grep -E "PreventUserIdleSystemSleep|PreventSystemSleep|caffeinate" | sed 's/^ */  /' | head -8

hdr "1a. Sleep and wake events, last 14 hours (night of the export)"
since=$(date -v-14H '+%Y-%m-%d %H:%M')
pmset -g log 2>/dev/null | awk -v s="$since" 'substr($0,1,16) >= s' \
  | awk '$4 ~ /^(Sleep|Wake|DarkWake|Maintenance)$/ {print "  " $1, $2, $4, $5, $6, $7, $8, $9, $10}' | tail -40

hdr "2. Network now"
dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
echo "  default route via: ${dev:-none}"
networksetup -listallhardwareports 2>/dev/null | grep -B1 "Device: $dev" | head -1 | sed 's/^/  /'
echo "  VPN / tunnel interfaces up:"
ifconfig 2>/dev/null | awk '/^utun|^ipsec|^ppp/{i=$1} i && /inet /{print "    " i " " $2; i=""}'
echo "  VPN apps running:"
ps -axo comm= | grep -iE "tunnelblick|openvpn|wireguard|duckduckgo|nordvpn|mullvad|proton|surfshark|cloudflare|warp" \
  | sed -E 's|.*/||' | sort -u | sed 's/^/    /'
scutil --nc list 2>/dev/null | grep -E "Connected|Connecting" | sed 's/^/  configured VPN: /'
scutil --proxy 2>/dev/null | grep -E "Enable : 1|Proxy :" | sed 's/^ */  proxy: /'

hdr "3. Reaching iCloud"
for h in https://www.icloud.com https://p01-content.icloud.com https://gateway.icloud.com; do
  r=$(curl -sS -o /dev/null --max-time 15 -w "%{http_code} in %{time_total}s" "$h" 2>&1)
  echo "  $h -> $r"
done

hdr "4. Connection speed (Apple's networkQuality, ~20 s)"
t 90 networkQuality -s 2>/dev/null | grep -E "Uplink capacity|Downlink capacity|Responsiveness|Idle Latency" | sed 's/^/  /' \
  || echo "  speed test failed or timed out"

hdr "5. iCloud Photos download errors in the system log, last 14 hours"
t 240 log show --last 14h --style compact \
  --predicate 'process == "cloudphotod" OR process == "photolibraryd" OR process == "Photos"' 2>/dev/null \
  > "/tmp/photos-log-$$.txt"
echo "  log lines read: $(wc -l < "/tmp/photos-log-$$.txt" | tr -d ' ')"
echo "  lines mentioning -1009 / offline: $(grep -ciE -- "-1009|offline|not connected|NetworkUnavailable" "/tmp/photos-log-$$.txt")"
echo "  lines mentioning low data / constrained / rate limit: $(grep -ciE "low data|constrained|expensive|rate limit|too many requests" "/tmp/photos-log-$$.txt")"
echo "  last 25 error-like lines:"
grep -iE "error|fail|-1009|offline|constrained" "/tmp/photos-log-$$.txt" | grep -v "throttle: " | tail -25 | cut -c1-220 | sed 's/^/    /'
rm -f "/tmp/photos-log-$$.txt"

hdr "6. Space"
df -h /System/Volumes/Data | awk 'NR==2{print "  Mac: " $4 " free"}'
[ -n "$BACKUP_DIR" ] && df -h "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print "  backup disk: " $4 " free"}'
du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null | awk '{print "  Photos library on this Mac: " $1}'

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"
sleep 1
