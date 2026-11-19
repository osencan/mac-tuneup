#!/bin/bash
# mac-tuneup: read-only health report for a Mac. Changes nothing.
# Covers: machine, power and throttling, memory pressure, per-app memory,
# out-of-memory kills, CPU sampled over 30 s, disk space and biggest folders,
# third-party launch items (flags ones whose program is gone), login items,
# extensions, Rosetta, crash loops, displays.
#
#   bash diagnose.sh                       report in the terminal and in ./diagnose-<date>.txt
#   bash diagnose.sh > /dev/null 2>&1      report only in the file
#
# Takes 1-2 minutes. Serial number and hardware UUID are left out.
# Terminal may ask for access to Desktop/Documents/Downloads and to control
# "System Events" (login items). Refusing only leaves those lines out.

OUTDIR="${OUTDIR:-$PWD}"   # reports go to the current folder unless OUTDIR is set
OUT="$OUTDIR/diagnose-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

# run a command with a time limit (macOS has no `timeout`); some commands hang
t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
hdr() { echo; echo "=== $* ==="; }
ind() { sed 's/^ */  /'; }
DR=(~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports)

echo "Report started $(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------------ machine
hdr "1. Machine, macOS, uptime"
system_profiler SPHardwareDataType 2>/dev/null \
  | grep -E "Model Name|Model Identifier|Chip|Total Number of Cores|Memory:" | ind
sw_vers | ind
uptime | ind
echo "  booted: $(sysctl -n kern.boottime | sed -E 's/.*} //')"

# ------------------------------------------------------------------ power
hdr "2. Power, battery, throttling"
pmset -g batt | ind
pmset -g | grep -iE "lowpowermode|powermode" | ind
echo "  (energy-saving slowdowns per power source, App Nap, background disk throttling: dethrottle.sh)"
system_profiler SPPowerDataType 2>/dev/null \
  | grep -E "Cycle Count|Condition|Maximum Capacity|Wattage|Charging:|Connected:" | ind
pmset -g therm | grep -v "^Note" | ind
echo "  (CPU_Speed_Limit below 100 or a thermal warning = the Mac is throttling)"
[ "$(uname -m)" = x86_64 ] && sysctl machdep.xcpm.cpu_thermal_level 2>/dev/null | ind
echo "  If it feels throttled (limit below 100, kernel_task busy, fans loud, or an older"
echo "  Intel MacBook stuck slow): run throttle-check.sh for frequency, temperature and cause."

# ------------------------------------------------------------------ memory
RAMGB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
hdr "3. Memory (${RAMGB} GB; compressor + swap are the honest pressure signals)"
top -l 1 -n 0 | grep PhysMem | ind
sysctl vm.swapusage | ind
memory_pressure 2>/dev/null | tail -1 | ind
vm_stat | grep -E "Pageouts|Swapins|Swapouts|Compressions|Decompressions" | ind

hdr "3a. Memory per app, all processes summed (physical footprint)"
# Electron apps run 10-30 helper processes each, so a per-process list hides them.
top -l 1 -o mem -n 1000 -stats command,mem 2>/dev/null | awk -v ram="$RAMGB" '
  /^COMMAND/ {f=1; next}
  f && NF {
    mem=$NF; $NF=""; name=$0
    sub(/ Helper.*| \(.*|[ \t]+$/, "", name)
    v=mem+0; u=substr(mem, length(v)+1, 1)
    mb = (u=="G") ? v*1024 : (u=="M") ? v : (u=="K") ? v/1024 : v/1048576
    agg[name]+=mb; n[name]++; tot+=mb
  }
  END {
    for (k in agg) printf "  %7.2f GB %4d procs  %s\n", agg[k]/1024, n[k], k
    printf "  %7.2f GB        TOTAL (RAM is %s GB)\n", tot/1024, ram
  }' | sort -rn | head -20

hdr "3b. Editor project windows open (Cursor / VS Code; each ~1-1.5 GB)"
ps -Ao command | grep "extension-host (user)" | grep -v grep \
  | sed -E 's/.*extension-host \(user\) (.*) \[.*/  \1/' | sort -u
echo "  claude CLI sessions running: $(pgrep -x claude | wc -l | tr -d ' ')"
echo "  Virtual machines running (Claude desktop sandbox, Docker, UTM ...):"
ps -Ao rss=,command= | grep -iE "Virtualization\.VirtualMachine|com\.docker\.(virtualization|vmnetd|backend)|qemu|vfkit" \
  | grep -v grep | awk '{printf "    %6.2f GB  %s\n", $1/1048576, substr($0, index($0,$2), 90)}'

hdr "3c. Out-of-memory kills (JetsamEvent), last 7 days"
JET=$(find "${DR[@]}" -name "JetsamEvent*" -mtime -7 2>/dev/null)
echo "  count: $(printf '%s' "$JET" | grep -c .)  (0 is the goal)"
printf '%s\n' "$JET" | grep . | while IFS= read -r f; do
  big=$(grep -o '"largestProcess" *: *"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*: *"(.*)"/\1/')
  echo "  $(stat -f '%Sm' -t '%m-%d %H:%M' "$f")  largest process: ${big:-?}"
done | sort | tail -10

# ------------------------------------------------------------------ cpu
hdr "4. CPU: 6 samples, 5 s apart (first top sample has no history, skipped)"
top -l 7 -s 5 -o cpu -n 8 -stats command,cpu 2>/dev/null | awk '
  /^COMMAND/ {s++; c=0; if (s>1) print "  -- sample " s-1; next}
  s>1 && c<8 && NF {print "     " $0; c++}'

hdr "4a. Sync, indexing, crash-reporter and graphics daemons right now (%CPU, RSS)"
ps -Ao %cpu=,rss=,comm= | awk '{
  n=$3; for (i=4;i<=NF;i++) n=n" "$i; sub(/.*\//, "", n)
  if (n ~ /^(bird|cloudd|fileproviderd|photoanalysisd|mediaanalysisd|mds|mds_stores|mdworker.*|corespotlightd|backupd|Dropbox|OneDrive|Google Drive|ReportCrash|coresymbolicationd|WindowServer|kernel_task|routined|spindump|softwareupdated|nsurlsessiond|com.apple.Virtualization.VirtualMachine)$/)
    printf "  %5s%%  %6.0f MB  %s\n", $1, $2/1024, n }' | sort -rn | head -20

# ------------------------------------------------------------------ disk
hdr "5. Startup disk"
df -h /System/Volumes/Data | awk 'NR==2{print "  " $4 " free of " $2 " (" 100-$5 "% free)"}'
diskutil info / | grep -E "SMART|Solid State|Device / Media Name" | ind
echo "  Local Time Machine snapshots:"
tmutil listlocalsnapshots / 2>/dev/null | grep -v "^Snapshots for" | sed 's/^/    /'
tmutil status 2>/dev/null | grep -E "Running|BackupPhase" | ind
echo "  Spotlight:"
mdutil -s / 2>/dev/null | sed 's/^/    /'

hdr "5a. Biggest space users (nested folders overlap; Dropbox/CloudStorage skipped)"
for d in ~/Library ~/Library/Application\ Support ~/Library/Containers \
         ~/Library/Group\ Containers ~/Library/Caches ~/Library/Developer \
         ~/Library/Application\ Support/MobileSync/Backup \
         ~/Downloads ~/Documents ~/Desktop ~/Movies ~/Pictures ~/Music \
         ~/.docker ~/.lmstudio ~/.ollama ~/.npm ~/.cache ~/.cargo ~/.rustup \
         ~/go ~/miniconda3 ~/anaconda3 /Applications; do
  [ -e "$d" ] || continue
  t 90 du -sh -I CloudStorage "$d" 2>/dev/null
done | sort -rh | ind

FREEPCT=$(df /System/Volumes/Data | awk 'NR==2{print 100-$5}')
if [ "${FREEPCT:-100}" -lt 20 ]; then
  hdr "5b. Free space under 20%: largest items inside the big folders"
  for d in ~/Library/Application\ Support ~/Library/Containers ~/Library/Group\ Containers \
           ~/Library/Caches ~/Library/Developer ~/Downloads ~/Movies; do
    [ -d "$d" ] || continue
    echo "  $d"
    t 120 du -sh "$d"/* 2>/dev/null | sort -rh | head -8 | sed 's/^/    /'
  done
fi

# ------------------------------------------------------------------ startup
hdr "6. Third-party launch items (MISSING = its program no longer exists)"
for f in ~/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist /Library/LaunchDaemons/*.plist; do
  [ -e "$f" ] || continue
  prog=$(/usr/libexec/PlistBuddy -c "Print :Program" "$f" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$f" 2>/dev/null)
  if [ -z "$prog" ]; then st="?"; elif [ -e "$prog" ]; then st="ok"; else st="MISSING"; fi
  printf "  %-7s %s\n          -> %s\n" "$st" "$f" "$prog"
done
ls /Library/PrivilegedHelperTools 2>/dev/null | sed 's/^/  helper tool: /'

hdr "6a. Loaded non-Apple jobs (launchctl, this user)"
launchctl list | awk 'NR>1 && $3 !~ /^(com\.apple|application\.)/ {print "  " $0}'

hdr "6b. Login items"
LI=$(t 20 osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)
if [ -n "$LI" ]; then printf '%s\n' "$LI" | tr ',' '\n' | ind
else echo "  (none, or could not read: timed out or not allowed)"; fi

hdr "6c. Third-party system and kernel extensions"
systemextensionsctl list 2>/dev/null | grep -E "\[activated|\[enabled" | ind
kextstat 2>/dev/null | grep -v com.apple | awk 'NR>1 {print "  kext: " $6}'

hdr "6d. Running apps (process count per app bundle)"
ps -axo comm= | awk '{i=index($0, ".app/"); if (i) {p=substr($0, 1, i+3); n=split(p, a, "/"); print a[n]}}' \
  | sort | uniq -c | sort -rn | awk '{c=$1; $1=""; printf "  %4d %s\n", c, substr($0,2)}' \
  | head -40

# ------------------------------------------------------------------ rosetta
hdr "7. Rosetta (Intel-only code on Apple Silicon)"
[ -e /Library/Apple/usr/libexec/oahd ] && echo "  Rosetta is installed." || echo "  Rosetta is not installed (so nothing runs under it)."
echo "  Installed apps without an arm64 build:"
for app in /Applications/*.app /Applications/*/*.app ~/Applications/*.app; do
  [ -d "$app" ] || continue
  exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null)
  [ -n "$exe" ] && [ -f "$app/Contents/MacOS/$exe" ] || continue
  info=$(file -b "$app/Contents/MacOS/$exe" 2>/dev/null)
  case "$info" in *Mach-O*) ;; *) continue ;; esac
  case "$info" in *arm64*) ;; *) echo "    $app" ;; esac
done
echo "  Running processes without an arm64 build:"
ps -axo comm= | grep -E "^/(Applications|Users|Library|opt|usr/local)/" | sort -u \
  | while IFS= read -r p; do
      [ -f "$p" ] || continue
      info=$(file -b "$p" 2>/dev/null)
      case "$info" in *Mach-O*) case "$info" in *arm64*) ;; *) echo "    $p" ;; esac ;; esac
    done

# ------------------------------------------------------------------ crashes
hdr "8. Crash and resource reports, last 7 days, by process"
CR=$(find "${DR[@]}" -type f -mtime -7 \( -name "*.ips" -o -name "*.crash" -o -name "*.diag" \) 2>/dev/null)
names() { sed -E 's|.*/||; s/[-_.][0-9]{4}-[0-9]{2}-[0-9]{2}.*//'; }
printf '%s\n' "$CR" | grep . | names | sort | uniq -c | sort -rn | head -15 | sed 's/^/  /'
echo "  Last 24 hours: $(find "${DR[@]}" -type f -mtime -1 2>/dev/null | wc -l | tr -d ' ') reports"

hdr "8a. Repeat crashers (5+ in 7 days): times and top of the newest backtrace"
printf '%s\n' "$CR" | grep . | names | sort | uniq -c | sort -rn | awk '$1>=5' \
  | while read -r n name; do
      [ "$name" = JetsamEvent ] && continue
      echo "  -- $name: $n reports. Most recent:"
      files=$(printf '%s\n' "$CR" | grep -F "/$name")
      printf '%s\n' "$files" | while IFS= read -r f; do stat -f '%Sm' -t '%m-%d %H:%M' "$f"; done \
        | sort | tail -10 | sed 's/^/       /'
      newest=$(printf '%s\n' "$files" | while IFS= read -r f; do echo "$(stat -f %m "$f") $f"; done \
        | sort -n | tail -1 | cut -d' ' -f2-)
      echo "     newest file: $newest"
      grep -o '"symbol" *: *"[^"]*"' "$newest" 2>/dev/null | head -12 | sed -E 's/.*: *"(.*)"/       \1/'
    done

# ------------------------------------------------------------------ graphics
hdr "9. Displays and visual effects"
system_profiler SPDisplaysDataType 2>/dev/null \
  | grep -E "^ {8}[^ ].*:$|Resolution|UI Looks like|Main Display|Connection Type|Chipset Model" | ind
for k in reduceTransparency reduceMotion; do
  v=$(defaults read com.apple.universalaccess "$k" 2>/dev/null) || v="unknown (Terminal lacks Full Disk Access)"
  echo "  $k: $v"
done
echo "  Items on the Desktop: $(ls -A ~/Desktop 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"
sleep 1
