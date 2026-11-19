#!/bin/bash
# mac-tuneup: offload iCloud Photos items to a backup disk, step 1 and 3.
# Photos itself downloads and exports (File > Export > Export Unmodified
# Original); osxphotos' own iCloud download proved unreliable (timeouts, hangs).
# This script does what Photos cannot:
#
#   1. albums: one album per year with exactly the items to move, e.g.
#      "Cleanup videos 2023". Reads the library and adds to albums only:
#      nothing is downloaded, exported or deleted. Creates matching folders.
#   2. verify: after you exported an album from Photos, checks that every item
#      has a file in its folder, so you know which albums are safe to delete.
#   3. retry: puts only the items still missing into "Cleanup retry <kind> <year>".
#
#   bash photos-albums-verify.sh albums videos               videos of 100 MB or more
#   bash photos-albums-verify.sh albums screenshots          screenshots up to SCREENSHOTS_UNTIL
#   bash photos-albums-verify.sh albums years 2018 2019 ...  everything else from those years
#   bash photos-albums-verify.sh verify videos|screenshots|years
#   bash photos-albums-verify.sh retry videos|screenshots|years
#
# The export, per album, in Photos:
#   open the album > click one item > Cmd+A > File > Export >
#   Export Unmodified Original For N Items... > File Name: Use File Name,
#   Subfolder Format: None > Export > pick the folder the script printed.
#   One album at a time, on a stable (ideally wired) connection; watch the
#   Mac's free space (Photos keeps downloaded originals for a while).
#
# Layout under BACKUP_DIR: photos/videos-100MB-plus/<year>/,
# photos/screenshots-until-<year>/<year>/, photos/years/<year>/.
# Run only one tool that drives Photos at a time. Installs osxphotos (open
# source) on first run into ~/.local/share/osxphotos-venv.
#
# Settings (environment variables):
#   BACKUP_DIR        required: folder on the backup disk, e.g. "/Volumes/MyDisk/icloud-backup"
#   SCREENSHOTS_UNTIL last year whose screenshots move (default: last year)
VENV="$HOME/.local/share/osxphotos-venv"
MB100=104857600

usage() { grep '^#   bash' "$0" | sed 's/^#//'; exit 1; }
ACTION="$1"; KIND="$2"; shift 2 2>/dev/null
case "$ACTION" in albums|verify|retry) ;; *) usage ;; esac
case "$KIND" in videos|screenshots|years) ;; *) usage ;; esac
[ -n "$BACKUP_DIR" ] || { echo 'Set BACKUP_DIR first, e.g.: export BACKUP_DIR="/Volumes/MyDisk/icloud-backup"'; exit 1; }
case "$BACKUP_DIR" in /Volumes/*) VOL="/Volumes/$(echo "${BACKUP_DIR#/Volumes/}" | cut -d/ -f1)" ;; *) VOL="$BACKUP_DIR" ;; esac
[ -d "$VOL" ] || { echo "The backup disk ($VOL) is not connected."; exit 1; }
mkdir -p "$BACKUP_DIR" || { echo "Cannot write to $BACKUP_DIR"; exit 1; }
BASE="$BACKUP_DIR"
UNTIL="${SCREENSHOTS_UNTIL:-$(( $(date +%Y) - 1 ))}"

if pgrep -f "bin/osxphotos" >/dev/null; then
  echo "Another osxphotos run is still active. Stop it first:  pkill -f bin/osxphotos"; exit 1
fi
OXP=$(command -v osxphotos)
[ -z "$OXP" ] && [ -x "$VENV/bin/osxphotos" ] && OXP="$VENV/bin/osxphotos"
if [ -z "$OXP" ]; then
  PY=$(command -v /opt/homebrew/bin/python3 python3 | head -1)
  echo "Installing osxphotos into $VENV (one time, ~1 minute)..."
  "$PY" -m venv "$VENV" && "$VENV/bin/pip" install -q --upgrade pip osxphotos \
    || { echo "Install failed. Nothing changed."; exit 1; }
  OXP="$VENV/bin/osxphotos"
fi

case "$KIND" in
  videos)      DEST="$BASE/photos/videos-100MB-plus";              PREFIX="Cleanup videos" ;;
  screenshots) DEST="$BASE/photos/screenshots-until-$UNTIL";       PREFIX="Cleanup screenshots" ;;
  years)       DEST="$BASE/photos/years";                          PREFIX="Cleanup year" ;;
esac
free_gb() { df -k "$1" | awk 'NR==2{print int($4/1048576)}'; }

# ---------------------------------------------------------------- which years
DB="$HOME/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$DB" "$TMP/p.sqlite" 2>/dev/null; cp "$DB-wal" "$TMP/p.sqlite-wal" 2>/dev/null
J="FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK WHERE a.ZTRASHEDSTATE = 0"
Y="strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch')"
plan() { sqlite3 "$TMP/p.sqlite" "SELECT $Y, COUNT(*), ROUND(SUM(aa.ZORIGINALFILESIZE)/1073741824.0, 1) $J AND $1 GROUP BY 1 ORDER BY 1;" 2>/dev/null | tr '|' ' '; }

case "$KIND" in
  videos)      PLAN=$(plan "a.ZKIND = 1 AND aa.ZORIGINALFILESIZE >= $MB100") ;;
  screenshots) PLAN=$(plan "a.ZISDETECTEDSCREENSHOT = 1 AND $Y <= '$UNTIL'") ;;
  years)
    if [ $# -gt 0 ]; then
      WANT=$(printf "'%s'," "$@"); WANT=${WANT%,}
    elif [ "$ACTION" != albums ]; then  # verify/retry: the years that have a folder on the backup disk
      WANT=$(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name "[12][0-9][0-9][0-9]" -exec basename {} \; | sed "s/.*/'&'/" | paste -sd, -)
    fi
    [ -n "$WANT" ] || { echo "Name the years, e.g.: bash $0 albums years 2018 2019 2020"; echo "Items per year:"; plan "1 = 1" | awk '{printf "  %s %6s items %5s GB\n",$1,$2,$3}'; exit 1; }
    PLAN=$(plan "$Y IN ($WANT) AND NOT (a.ZKIND = 1 AND aa.ZORIGINALFILESIZE >= $MB100) AND COALESCE(a.ZISDETECTEDSCREENSHOT, 0) = 0") ;;
esac
[ -n "$PLAN" ] || { echo "Nothing matches (could not read the Photos database?)."; exit 1; }

# ---------------------------------------------------------------- albums
if [ "$ACTION" = albums ]; then
  echo "Albums to create for '$KIND' (items / GB per year):"
  printf '%s\n' "$PLAN" | awk -v p="$PREFIX" '{printf "  %s %s   %5s items  %5s GB\n", p, $1, $2, $3}'
  read -r -p "Create these albums in Photos (adds to albums only, nothing is deleted)? [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "Nothing changed."; exit 0; }
  for yr in $(printf '%s\n' "$PLAN" | awk '{print $1}'); do
    album="$PREFIX $yr"; mkdir -p "$DEST/$yr"
    echo; echo "== $album"
    case "$KIND" in
      videos)      "$OXP" query --year "$yr" --only-movies --min-size "$MB100" --add-to-album "$album" --quiet ;;
      screenshots) "$OXP" query --year "$yr" --screenshot --add-to-album "$album" --quiet ;;
      years)       "$OXP" query --year "$yr" --only-photos --not-screenshot --add-to-album "$album" --quiet
                   "$OXP" query --year "$yr" --only-movies --max-size $((MB100 - 1)) --add-to-album "$album" --quiet ;;
    esac
    echo "   export it to: $DEST/$yr"
  done
  cat <<EOF

Done. In Photos (sidebar > Albums), export each "$PREFIX <year>" album as
described at the top of this script into its folder, one album at a time.
Mac free now: $(free_gb /System/Volumes/Data) GB. Backup disk free: $(free_gb "$VOL") GB.
Then:  bash $0 verify $KIND
EOF
  exit 0
fi

# ---------------------------------------------------------------- verify / retry
echo "Checking each '$PREFIX <year>' album against its backup folder..."
SAFE=(); TODO=()
for yr in $(printf '%s\n' "$PLAN" | awk '{print $1}'); do
  album="$PREFIX $yr"; dir="$DEST/$yr"
  # uuid + name Photos has for the album's items (name: stem only, lower case)
  "$OXP" query --album "$album" --print "{uuid}|{original_name}" --quiet 2>/dev/null \
    | awk -F'|' 'NF==2 {print $1 "|" tolower($2)}' | sed 's/[[:space:]]*$//' > "$TMP/items"
  cut -d'|' -f2 "$TMP/items" | grep . | sort > "$TMP/want"
  n=$(wc -l < "$TMP/want" | tr -d ' ')
  if [ "$n" = 0 ]; then printf "  %-26s no album or empty\n" "$album"; continue; fi
  # stems of files on the backup disk (Photos adds " (1)" etc. on name clashes)
  find "$dir" -maxdepth 1 -type f ! -name ".*" -size +0 2>/dev/null \
    | sed -E 's|.*/||; s/\.[^.]*$//; s/_edited$//; s/ \([0-9]+\)$//' | tr '[:upper:]' '[:lower:]' | sort -u > "$TMP/have"
  # a clash-renamed duplicate covers one more item with the same stem
  miss=$(comm -23 <(uniq "$TMP/want") "$TMP/have")
  dupe_want=$(uniq -d "$TMP/want" | wc -l | tr -d ' ')
  nf=$(find "$dir" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | wc -l | tr -d ' ')
  if [ -z "$miss" ]; then
    printf "  %-26s OK       %5s items, %5s files on disk%s\n" "$album" "$n" "$nf" \
      "$([ "$dupe_want" -gt 0 ] && echo " ($dupe_want names used twice; check counts)")"
    SAFE+=("$album")
  else
    printf "  %-26s MISSING  %5s of %s items have no file, e.g.:\n" "$album" "$(printf '%s\n' "$miss" | wc -l | tr -d ' ')" "$n"
    printf '%s\n' "$miss" | head -5 | sed 's/^/      /'
    TODO+=("$album")
    if [ "$ACTION" = retry ]; then
      ralbum="Cleanup retry $KIND $yr"
      printf '%s\n' "$miss" > "$TMP/missnames"
      awk -F'|' 'NR==FNR {m[$0]=1; next} ($2 in m) {print $1}' "$TMP/missnames" "$TMP/items" > "$TMP/missuuids"
      "$OXP" query --uuid-from-file "$TMP/missuuids" --add-to-album "$ralbum" --quiet 2>&1 | grep -v "^Adding" | sed 's/^/      /'
      echo "      -> album \"$ralbum\" ($(wc -l < "$TMP/missuuids" | tr -d ' ') items): export it to $dir"
    fi
  fi
done
echo
[ ${#SAFE[@]} -gt 0 ] && { echo "Safe to delete from Photos/iCloud (all files are on the backup disk):"; printf '  %s\n' "${SAFE[@]}"; }
[ ${#TODO[@]} -gt 0 ] && { echo "Not yet: export these again (if Photos asks about files that already exist, replace or skip them):"; printf '  %s\n' "${TODO[@]}"; }
cat <<'EOF'

To delete a safe album's items: open it in Photos > click one > Cmd+A >
Cmd+Delete ("Delete N items"); then Recently Deleted > Delete All.
EOF
