#!/bin/bash
# mac-tuneup: offload step 4. Deletes from Photos (and so from iCloud) ONLY the
# items whose original is verifiably on the backup disk: a file in its
# compartment with the same name (Photos' " (1)" clash suffix allowed) AND
# exactly the same size in bytes as the original in Photos. Everything else
# is kept and counted.
#
#   bash photos-delete-verified.sh videos
#   bash photos-delete-verified.sh screenshots
#   bash photos-delete-verified.sh years
#
# Safety:
#   - Shows count and size per year, writes the full list to BACKUP_DIR/_logs,
#     and asks y/N before deleting.
#   - Deletes through PhotoKit, so macOS shows its own "Allow Terminal to
#     delete N items?" dialog as a second confirmation.
#   - Deleted items go to Photos > Recently Deleted for 30 days. iCloud space
#     is freed when Recently Deleted is emptied.
#   - Live Photos: only the still image is size-checked.
#   - Needs swiftc (Xcode or Command Line Tools) and Terminal with Full Access
#     in System Settings > Privacy & Security > Photos, plus Full Disk Access.
#
# Settings (environment variables):
#   BACKUP_DIR        required: folder on the backup disk, e.g. "/Volumes/MyDisk/icloud-backup"
#   SCREENSHOTS_UNTIL last year whose screenshots move (default: last year)
MB100=104857600
BASE="$BACKUP_DIR"
LOGS="$BASE/_logs"
UNTIL="${SCREENSHOTS_UNTIL:-$(( $(date +%Y) - 1 ))}"
KIND="$1"
case "$KIND" in
  videos)      DEST="$BASE/photos/videos-100MB-plus" ;;
  screenshots) DEST="$BASE/photos/screenshots-until-$UNTIL" ;;
  years)       DEST="$BASE/photos/years" ;;
  *) grep '^#   bash' "$0" | sed 's/^#//'; exit 1 ;;
esac
[ -n "$BACKUP_DIR" ] || { echo 'Set BACKUP_DIR first, e.g.: export BACKUP_DIR="/Volumes/MyDisk/icloud-backup"'; exit 1; }
case "$BACKUP_DIR" in /Volumes/*) VOL="/Volumes/$(echo "${BACKUP_DIR#/Volumes/}" | cut -d/ -f1)" ;; *) VOL="$BACKUP_DIR" ;; esac
[ -d "$VOL" ] || { echo "The backup disk ($VOL) is not connected."; exit 1; }
mkdir -p "$BACKUP_DIR" || { echo "Cannot write to $BACKUP_DIR"; exit 1; }
[ -d "$DEST" ] || { echo "Not found: $DEST (nothing exported there yet?)"; exit 1; }
command -v swift >/dev/null || { echo "swift not found (needs Xcode or its command line tools)."; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STAMP=$(date +%Y%m%d-%H%M)
hum() { awk '{b=$1; if (b>=1073741824) printf "%.1f GB", b/1073741824; else printf "%.0f MB", b/1048576}'; }

# ---------------------------------------------------------------- files on the backup disk: size <TAB> stem
find "$DEST" -type f ! -name ".*" ! -name "*_edited.*" -size +0 -print0 2>/dev/null \
  | xargs -0 stat -f "%z	%N" 2>/dev/null \
  | awk -F'\t' '{n=$2; sub(/.*\//, "", n); sub(/\.[^.]*$/, "", n); sub(/ \([0-9]+\)$/, "", n); print $1 "\t" tolower(n)}' \
  > "$TMP/ondisk"
echo "Files on the backup disk in $(basename "$DEST"): $(wc -l < "$TMP/ondisk" | tr -d ' ')"

# ---------------------------------------------------------------- items in Photos: uuid size stem name year
DB="$HOME/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"
cp "$DB" "$TMP/p.sqlite" && { cp "$DB-wal" "$TMP/p.sqlite-wal" 2>/dev/null; true; } \
  || { echo "Cannot read the Photos database (Terminal needs Full Disk Access)."; exit 1; }
Y="strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch')"
case "$KIND" in
  videos)      COND="a.ZKIND = 1 AND aa.ZORIGINALFILESIZE >= $MB100" ;;
  screenshots) COND="a.ZISDETECTEDSCREENSHOT = 1 AND $Y <= '$UNTIL'" ;;
  years)       COND="NOT (a.ZKIND = 1 AND aa.ZORIGINALFILESIZE >= $MB100) AND COALESCE(a.ZISDETECTEDSCREENSHOT, 0) = 0" ;;
esac
sqlite3 -separator $'\t' "$TMP/p.sqlite" \
  "SELECT a.ZUUID, aa.ZORIGINALFILESIZE, aa.ZORIGINALFILENAME, $Y
   FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
   WHERE a.ZTRASHEDSTATE = 0 AND aa.ZORIGINALFILESIZE > 0 AND $COND;" > "$TMP/photos" \
  || { echo "Query failed."; exit 1; }

# ---------------------------------------------------------------- match on name + exact size
awk -F'\t' -v OFS='\t' '
  NR==FNR {have[$2 SUBSEP $1]=1; next}
  { stem=tolower($3); sub(/\.[^.]*$/, "", stem)
    if ((stem SUBSEP $2) in have) print "OK", $1, $2, $3, $4; else print "NO", $1, $2, $3, $4 }' \
  "$TMP/ondisk" "$TMP/photos" > "$TMP/match"

grep '^OK' "$TMP/match" | cut -f2- > "$TMP/ok"
n_ok=$(wc -l < "$TMP/ok" | tr -d ' ')
gb_ok=$(awk -F'\t' '{s+=$2} END{print s+0}' "$TMP/ok" | hum)
n_no=$(grep -c '^NO' "$TMP/match")
echo "Backed up (same name and size on disk): $n_ok items, $gb_ok"
echo "Not (yet) on disk, will be kept:          $n_no items"
echo "Backed up, per year:"
awk -F'\t' '{n[$4]++; s[$4]+=$2} END{for (y in n) printf "  %s  %4d items  %6.1f GB\n", y, n[y], s[y]/1073741824}' "$TMP/ok" | sort

[ "$n_ok" -gt 0 ] || { echo "Nothing to delete."; exit 0; }

LIST="$LOGS/delete-$KIND-$STAMP.tsv"
mkdir -p "$LOGS"
{ printf 'uuid\tbytes\tfilename\tyear\n'; cat "$TMP/ok"; } > "$LIST"
echo "Full list: $LIST"
echo
read -r -p "Delete these $n_ok items from Photos and iCloud (they go to Recently Deleted)? [y/N] " a
[[ "$a" =~ ^[Yy]$ ]] || { echo "Nothing deleted."; exit 0; }

cut -f1 "$TMP/ok" > "$TMP/uuids"
cat > "$TMP/delete.swift" <<'SWIFT'
import Foundation
import Photos

let path = CommandLine.arguments[1]
let ids = (try? String(contentsOfFile: path, encoding: .utf8))?
  .split(separator: "\n").map { "\($0)/L0/001" } ?? []

PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
  guard status == .authorized else {
    print("No full Photos access for Terminal (status \(status.rawValue)).")
    print("System Settings > Privacy & Security > Photos > Terminal: Full Access, then run again.")
    exit(2)
  }
  let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
  print("Found \(assets.count) of \(ids.count) items in Photos.")
  guard assets.count > 0 else { exit(1) }
  print("Confirm the macOS dialog to delete them...")
  PHPhotoLibrary.shared().performChanges({
    PHAssetChangeRequest.deleteAssets(assets)
  }) { ok, error in
    if ok {
      print("Deleted \(assets.count) items. They are in Photos > Recently Deleted for 30 days.")
      exit(0)
    } else {
      print("Nothing deleted: \(error?.localizedDescription ?? "cancelled")")
      exit(1)
    }
  }
}
dispatchMain()
SWIFT

echo "Compiling a small PhotoKit helper (a few seconds)..."
if swiftc -O -o "$TMP/photos-delete" "$TMP/delete.swift" 2>"$TMP/swift.err"; then
  "$TMP/photos-delete" "$TMP/uuids" | tee -a "$LIST.result.txt"
else
  echo "Could not build the helper:"; cat "$TMP/swift.err"; exit 1
fi

cat <<'EOF'

To free the iCloud space now: Photos > Recently Deleted > Delete All
(otherwise it happens by itself after 30 days). Until then you can
recover anything from Recently Deleted.
EOF
