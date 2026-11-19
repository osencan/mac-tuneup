#!/bin/bash
# mac-tuneup: frees the space that Apple's own media apps hold in data that
# can be downloaded again: Podcasts episodes and caches, Music, TV and Books
# caches, GarageBand and Logic sound libraries, iPhone/iPad update files.
#
#   bash apple-media-cleanup.sh            report only: sizes per group, changes nothing
#   bash apple-media-cleanup.sh --apply    asks y/N per group, then moves it to the Trash
#
# Undo: everything goes to ~/.Trash/AppleMedia-removed-<timestamp>/. Space is
# freed only when the Trash is emptied; until then, drag a folder back.
# The apps rebuild their caches and download episodes and sounds again on demand.
#
# Left alone on purpose (your data, or not possible to tell apart from it):
#   - the Music library and its Media folder (your own files sit next to
#     Apple Music downloads): remove downloads in Music > Songs > Downloaded
#   - TV downloads in ~/Movies/TV: remove them in the TV app > Library > Downloaded
#   - Podcasts subscriptions and play positions, Books and audiobooks
#   - iPhone/iPad backups, Voice Memos, Photos
#
# Podcasts data is protected by macOS: give Terminal Full Disk Access first
# (System Settings > Privacy & Security > Full Disk Access). An app that is
# open is skipped: quit it and run again.

MODE="$1"
case "$MODE" in ""|--apply) ;; *) grep '^#   bash' "$0" | sed 's/^#//'; exit 1 ;; esac

TRASH="$HOME/.Trash/AppleMedia-removed-$(date +%Y%m%d-%H%M%S)"
PODCASTS="$HOME/Library/Group Containers/243LU875E5.groups.com.apple.podcasts"
TOTAL_KB=0; MOVED_KB=0

ask() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
hum() { awk -v k="$1" 'BEGIN{ if (k>=1048576) printf "%.1f GB", k/1048576; else printf "%.0f MB", k/1024 }'; }
# path -> Trash, prefixed with its parent folder name; 2nd arg "sudo" for root-owned files
to_trash() {
  local p="$1" sudo_cmd="$2"
  [ -e "$p" ] || return 0
  mkdir -p "$TRASH"
  # sudo_cmd is empty or "sudo", so it is left unquoted on purpose
  # shellcheck disable=SC2086
  if $sudo_cmd mv "$p" "$TRASH/$(basename "$(dirname "$p")")-$(basename "$p")" 2>/dev/null; then
    echo "    moved to Trash: $p"; return 0
  elif [ -n "$sudo_cmd" ]; then
    echo "    NOT moved (admin password not accepted; run again): $p"
  else
    echo "    could not move (macOS protects it; harmless): $p"
  fi
  return 1
}

# group <title> <app process name or ""> <"sudo" or ""> <what happens afterwards> <path>...
group() {
  local title="$1" app="$2" sudo_cmd="$3" note="$4"; shift 4
  local p kb sum=0 blocked=0 found=()
  echo; echo "=== $title ==="
  for p in "$@"; do
    [ -e "$p" ] || continue
    if ! ls "$p" >/dev/null 2>&1; then
      echo "    no access (Terminal needs Full Disk Access): $p"; blocked=1; continue
    fi
    kb=$(du -sk "$p" 2>/dev/null | cut -f1); kb=${kb:-0}
    [ "$kb" -ge 1024 ] || continue   # under 1 MB is not worth a question
    printf "  %9s  %s\n" "$(hum "$kb")" "$p"
    found+=("$p"); sum=$((sum + kb))
  done
  if [ ${#found[@]} -eq 0 ]; then
    [ "$blocked" = 1 ] || echo "  nothing here"
    return
  fi
  TOTAL_KB=$((TOTAL_KB + sum))
  echo "  total: $(hum "$sum").  Afterwards: $note"
  [ "$MODE" = "--apply" ] || return
  if [ -n "$app" ] && pgrep -xq "$app"; then
    echo "  SKIPPED: $app is open. Quit it and run again."; return
  fi
  ask "  Move these to the Trash?" || { echo "  kept"; return; }
  for p in "${found[@]}"; do
    kb=$(du -sk "$p" 2>/dev/null | cut -f1)
    to_trash "$p" "$sudo_cmd" && MOVED_KB=$((MOVED_KB + ${kb:-0}))
  done
}

echo "Apple media app data that can be downloaded again ($(date '+%Y-%m-%d %H:%M'))"
if [ "$MODE" = "--apply" ]; then echo "Mode: apply (asks before each group)"; else echo "Mode: report only, nothing is changed"; fi
df -h /System/Volumes/Data | awk 'NR==2{print "Startup disk: " $4 " free of " $2}'

group "Podcasts: downloaded episodes and artwork cache" "Podcasts" "" \
  "subscriptions and play positions stay; episodes download again when played." \
  "$PODCASTS/Library/Cache" \
  "$HOME/Library/Caches/com.apple.podcasts"

group "Music: caches (not the library, not downloaded songs)" "Music" "" \
  "Music rebuilds artwork and streaming caches as you browse." \
  "$HOME/Library/Caches/com.apple.Music" \
  "$HOME/Library/Caches/com.apple.AMPLibraryAgent" \
  "$HOME/Library/Caches/com.apple.AMPArtworkAgent" \
  "$HOME/Library/Caches/com.apple.itunescloudd"

group "TV: caches (not downloaded films or shows)" "TV" "" \
  "the TV app rebuilds its artwork cache." \
  "$HOME/Library/Caches/com.apple.TV"

group "Books: caches (not books or audiobooks)" "Books" "" \
  "Books rebuilds its store and cover caches." \
  "$HOME/Library/Caches/com.apple.iBooksX" \
  "$HOME/Library/Caches/com.apple.BKAgentService"

SOUND_NOTE="GarageBand and Logic offer to download the sounds again (Sound Library menu)."
ls -d /Applications/GarageBand.app /Applications/Logic\ Pro*.app >/dev/null 2>&1 \
  && SOUND_NOTE="GarageBand or Logic IS installed: instruments and loops are missing until downloaded again (Sound Library menu)."
group "GarageBand and Logic sound libraries (needs the admin password)" "GarageBand" "sudo" \
  "$SOUND_NOTE" \
  "/Library/Application Support/GarageBand" \
  "/Library/Application Support/Logic" \
  "/Library/Audio/Apple Loops"

group "iPhone and iPad update files kept by Finder" "" "" \
  "Finder downloads the update again when a device needs it." \
  "$HOME/Library/iTunes/iPhone Software Updates" \
  "$HOME/Library/iTunes/iPad Software Updates"

echo
if [ "$MODE" = "--apply" ]; then
  echo "Moved to the Trash: $(hum "$MOVED_KB") of $(hum "$TOTAL_KB") found."
  [ "$MOVED_KB" -gt 0 ] && echo "In the Trash as: $TRASH
Space is freed when you empty the Trash."
else
  echo "Found: $(hum "$TOTAL_KB") in total. Nothing was changed."
  echo "To choose what to remove:  bash $(basename "$0") --apply"
fi
exit 0
