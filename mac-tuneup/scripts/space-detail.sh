#!/bin/bash
# mac-tuneup: read-only follow-up when the startup disk is short of space
# (under ~20% free). Finds where the space went, including what a plain du
# misses: APFS volumes, Xcode simulator runtimes, cloud folders kept locally,
# model caches, single files over 2 GB. Changes nothing.
#
#   bash space-detail.sh > /dev/null 2>&1     report in ./space-<date>.txt
#
# Takes 2-5 minutes. Give Terminal Full Disk Access first (System Settings >
# Privacy & Security > Full Disk Access), or app container sizes come out too low.
# Note: du on /Library/Developer/CoreSimulator/Volumes counts mounted simulator
# images that live elsewhere; trust "xcrun simctl runtime list" for runtime sizes.

OUTDIR="${OUTDIR:-$PWD}"   # reports go to the current folder unless OUTDIR is set
OUT="$OUTDIR/space-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
hdr() { echo; echo "=== $* ==="; }
ind() { sed 's/^ */  /'; }
sizes() { local s=$1; shift; t "$s" du -sh -I CloudStorage "$@" 2>/dev/null | sort -rh; }

echo "Report started $(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------------ overview
hdr "1. Disk overview"
df -h /System/Volumes/Data | awk 'NR==2{print "  Data volume: " $3 " used, " $4 " free of " $2}'
diskutil info / | grep -iE "Container Total|Container Free|Purgeable" | ind
diskutil apfs list 2>/dev/null | grep -E "[|] +Name:|Capacity Consumed:" \
  | sed -E 's/^[ |+-]*//' | paste - - | ind
echo "  Swap files: $(ls /private/var/vm 2>/dev/null | wc -l | tr -d ' '), $(du -sh /private/var/vm 2>/dev/null | cut -f1)"
if ls ~/Library/Safari >/dev/null 2>&1; then
  echo "  Terminal HAS Full Disk Access: container sizes below are complete."
else
  echo "  Terminal has NO Full Disk Access: ~/Library/Containers sizes below are too low."
fi

# ------------------------------------------------------------------ where it is
hdr "2. Top level of your home folder, hidden folders included (CloudStorage skipped)"
sizes 300 ~/* ~/.[!.]* | head -25 | ind

hdr "2a. ~/Library, one level down"
sizes 300 ~/Library/* | head -15 | ind

hdr "2b. Outside your home folder"
sizes 300 /Applications /Library /opt /usr/local /Users/Shared \
  /Library/Developer /Library/Application\ Support "$(dirname "$(getconf DARWIN_USER_DIR)")" | ind

hdr "2c. Cloud folders kept on this Mac (only downloaded files take space)"
for d in ~/Library/CloudStorage/* ~/Library/Mobile\ Documents; do
  [ -e "$d" ] || continue
  t 180 du -sh "$d" 2>/dev/null | ind
done

# ------------------------------------------------------------------ developer
hdr "3. Xcode and simulators"
ls -d /Applications/Xcode*.app 2>/dev/null | sed 's/^/  installed: /'
sizes 120 ~/Library/Developer/Xcode/* ~/Library/Developer/Xcode/UserData/* \
  ~/Library/Developer/CoreSimulator/* /Library/Developer/CoreSimulator/* | head -15 | ind
echo "  iOS DeviceSupport versions:"
ls ~/Library/Developer/Xcode/*DeviceSupport 2>/dev/null | sed 's/^/    /'
if xcode-select -p 2>/dev/null | grep -q Xcode.app; then
  echo "  Simulator devices no longer usable (runtime gone): $(t 60 xcrun simctl list devices unavailable 2>/dev/null | grep -c '(')"
  echo "  Simulator runtimes:"
  t 60 xcrun simctl runtime list 2>/dev/null | grep -vE "^==|^$" | sed 's/^/    /'
fi

# ------------------------------------------------------------------ tools and caches
hdr "4. Model, package and tool caches"
sizes 120 ~/.ollama/* ~/.lmstudio/* ~/.cache/* ~/.npm/* ~/.rustup/toolchains/* \
  ~/Library/Caches/* | head -25 | ind
echo "  Ollama app or CLI installed: $( { ls -d /Applications/Ollama.app 2>/dev/null; command -v ollama; } | tr '\n' ' ')"
echo "  LM Studio installed: $(ls -d /Applications/LM\ Studio.app 2>/dev/null)"
echo "  Ollama models:"
find ~/.ollama/models/manifests -type f 2>/dev/null | sed -E 's|.*/manifests/[^/]+/[^/]+/||; s/^/    /'

hdr "4a. App data folders (largest)"
sizes 180 ~/Library/Application\ Support/* | head -12 | ind
echo "  Inside the three largest app data folders:"
du -sk ~/Library/Application\ Support/* 2>/dev/null | sort -rn | head -3 | cut -f2- \
  | while IFS= read -r d; do sizes 60 "$d"/* | head -5 | sed 's/^/  /'; done

# ------------------------------------------------------------------ apps
hdr "5. Installed apps, largest first"
sizes 180 /Applications/*.app ~/Applications/*.app | head -25 | ind

# ------------------------------------------------------------------ user files
hdr "6. Your own files: biggest items on the Desktop and in Downloads"
sizes 120 ~/Desktop/* | head -12 | ind
echo "  Downloads: installers and archives:"
find ~/Downloads -maxdepth 2 \( -iname "*.dmg" -o -iname "*.pkg" -o -iname "*.zip" -o -iname "*.iso" \) \
  -exec du -sh {} + 2>/dev/null | sort -rh | head -10 | ind
echo "  Photos libraries:"
find ~/Pictures -maxdepth 1 -name "*.photoslibrary" -exec du -sh {} + 2>/dev/null | ind

hdr "6a. Single files over 2 GB in your home folder (CloudStorage skipped)"
t 240 find ~ -xdev \( -path "$HOME/Library/CloudStorage" -o -path "$HOME/Library/Containers" \) -prune \
  -o -type f -size +2G -print 2>/dev/null \
  | while IFS= read -r f; do du -sh "$f" 2>/dev/null; done | sort -rh | head -25 | ind

# ------------------------------------------------------------------ memory + background
hdr "7. Out-of-memory kills, last 30 days (reason tells whether low disk played a part)"
find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name "JetsamEvent*" -mtime -30 2>/dev/null \
  | while IFS= read -r f; do
      r=$(grep -oE '"(reason|largestProcess)" *: *"[^"]*"' "$f" | sed -E 's/"([a-zA-Z]+)" *: *"(.*)"/\1=\2/' | sort -u | tr '\n' ' ')
      echo "  $(stat -f '%Sm' -t '%m-%d %H:%M' "$f")  $r"
    done | sort

hdr "8. Background jobs: which third-party ones are loaded or disabled"
for f in ~/Library/LaunchAgents/*.plist /Library/LaunchAgents/*.plist; do
  [ -e "$f" ] || continue
  label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$f" 2>/dev/null)
  [ -n "$label" ] || continue
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then st=loaded; else st="not loaded"; fi
  printf "  %-11s %s\n" "$st" "$label"
done
echo "  Disabled by you or by System Settings > Login Items (non-Apple):"
launchctl print-disabled "gui/$(id -u)" 2>/dev/null | grep -v com.apple | grep -E "=>" | ind

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"
sleep 1
