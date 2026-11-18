#!/bin/bash
# mac-tuneup: read-only report of what fills iCloud storage, as far as a Mac
# can see it: iCloud Drive (cloud size of every folder, including files not
# downloaded), the Photos library (photos, videos, Recently Deleted, biggest
# videos, size per year, screenshots), Messages attachments, Mail.
# Databases are read from a temporary copy. Changes nothing.
#
#   bash icloud-report.sh > /dev/null 2>&1     report in ./icloud-<date>.txt
#
# Needs Terminal with Full Disk Access (Photos and Messages sections).
# Not visible from a Mac: iCloud device backups and data of apps that are not
# on this Mac. At the end it opens System Settings: a screenshot of
# iCloud > Manage Storage completes the picture.

OUTDIR="${OUTDIR:-$PWD}"   # reports go to the current folder unless OUTDIR is set
OUT="$OUTDIR/icloud-$(date +%Y%m%d-%H%M).txt"
{ exec 3>/dev/tty; } 2>/dev/null || exec 3>&1
exec > >(tee "$OUT") 2>&1

t() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
hdr() { echo; echo "=== $* ==="; }
hum() { awk '{b=$1; if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.0f MB", b/1048576; else printf "%.0f KB", b/1024}'; }
# logical size of everything under a folder = what it takes in iCloud
# (files not downloaded to this Mac still report their full size)
lsize() { t 180 find "$1" -type f -print0 2>/dev/null | xargs -0 stat -f %z 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Report started $(date '+%Y-%m-%d %H:%M:%S')"
if ls ~/Library/Safari >/dev/null 2>&1; then echo "Terminal has Full Disk Access."
else echo "WARNING: Terminal has no Full Disk Access; Photos and Messages sections will be empty."; fi

# ------------------------------------------------------------------ drive
MD="$HOME/Library/Mobile Documents"
CD="$MD/com~apple~CloudDocs"
hdr "1. iCloud Drive"
if [ -d "$CD/Desktop" ] || [ -d "$CD/Documents" ]; then
  echo "  Desktop & Documents sync: ON (Desktop and Documents count against iCloud)"
else
  echo "  Desktop & Documents sync: off"
fi
echo "  Cloud size / on this Mac, per folder in iCloud Drive:"
DRIVE=$(for d in "$CD"/* "$CD"/.Trash; do
  [ -e "$d" ] || continue
  echo "$(lsize "$d") $(du -sk "$d" 2>/dev/null | cut -f1) $(basename "$d")"
done | sort -rn)
printf '%s\n' "$DRIVE" | grep . | head -25 | while read -r b k name; do
  printf "    %10s  / %8s  %s\n" "$(echo "$b" | hum)" "$(echo $((k*1024)) | hum)" "$name"
done
echo "  App data stored in iCloud Drive by apps on this Mac (cloud size):"
APPS=$(for d in "$MD"/*; do
  [ -d "$d" ] && [ "$d" != "$CD" ] || continue
  echo "$(lsize "$d") $(basename "$d")"
done | sort -rn)
printf '%s\n' "$APPS" | awk '$1>10485760' | head -15 | while read -r b name; do
  printf "    %10s  %s\n" "$(echo "$b" | hum)" "$name"
done
echo "  iCloud Drive total (cloud size): $(printf '%s\n%s\n' "$DRIVE" "$APPS" | awk '{s+=$1} END{print s+0}' | hum)"

hdr "1a. Biggest files in iCloud Drive (cloud size, over 100 MB)"
t 180 find "$CD" -type f -size +100M -print0 2>/dev/null | xargs -0 stat -f "%z	%N" 2>/dev/null \
  | sort -rn | head -30 | while IFS=$'\t' read -r b f; do
      printf "    %10s  %s\n" "$(echo "$b" | hum)" "${f#"$CD"/}"
    done

# ------------------------------------------------------------------ photos
LIB="$HOME/Pictures/Photos Library.photoslibrary"
DB="$LIB/database/Photos.sqlite"
hdr "2. Photos library ($(du -sh "$LIB" 2>/dev/null | cut -f1) on this Mac)"
if cp "$DB" "$TMP/p.sqlite" 2>/dev/null; then
  cp "$DB-wal" "$TMP/p.sqlite-wal" 2>/dev/null; cp "$DB-shm" "$TMP/p.sqlite-shm" 2>/dev/null
  Q() { sqlite3 -header -column "$TMP/p.sqlite" "$1" 2>&1 | sed 's/^/    /'; }
  J="FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK"
  echo "  Originals by kind (GB is the full-quality size, which is what iCloud stores):"
  Q "SELECT CASE a.ZTRASHEDSTATE WHEN 1 THEN 'Recently Deleted' ELSE 'Library' END AS place,
            CASE a.ZKIND WHEN 0 THEN 'photo' WHEN 1 THEN 'video' ELSE 'other' END AS kind,
            COUNT(*) AS items, ROUND(SUM(aa.ZORIGINALFILESIZE)/1073741824.0, 1) AS GB
     $J GROUP BY 1, 2 ORDER BY 1, 2;"
  echo "  Items synced with iCloud Photos:"
  Q "SELECT COUNT(*) AS in_icloud FROM ZASSET WHERE ZCLOUDASSETGUID IS NOT NULL AND ZTRASHEDSTATE = 0;"
  echo "  Per year:"
  Q "SELECT strftime('%Y', a.ZDATECREATED + 978307200, 'unixepoch') AS year,
            SUM(a.ZKIND = 0) AS photos, SUM(a.ZKIND = 1) AS videos,
            ROUND(SUM(aa.ZORIGINALFILESIZE)/1073741824.0, 1) AS GB
     $J WHERE a.ZTRASHEDSTATE = 0 GROUP BY 1 ORDER BY 1;"
  echo "  Videos by size band:"
  Q "SELECT CASE WHEN aa.ZORIGINALFILESIZE >= 1073741824 THEN '1 GB+'
                 WHEN aa.ZORIGINALFILESIZE >= 524288000 THEN '500 MB-1 GB'
                 WHEN aa.ZORIGINALFILESIZE >= 104857600 THEN '100-500 MB' ELSE 'under 100 MB' END AS band,
            COUNT(*) AS videos, ROUND(SUM(aa.ZORIGINALFILESIZE)/1073741824.0, 1) AS GB
     $J WHERE a.ZKIND = 1 AND a.ZTRASHEDSTATE = 0 GROUP BY 1 ORDER BY 3 DESC;"
  echo "  30 biggest videos:"
  Q "SELECT ROUND(aa.ZORIGINALFILESIZE/1048576.0) AS MB, date(a.ZDATECREATED + 978307200, 'unixepoch') AS date,
            ROUND(a.ZDURATION/60.0, 1) AS minutes, aa.ZORIGINALFILENAME AS file
     $J WHERE a.ZKIND = 1 AND a.ZTRASHEDSTATE = 0 ORDER BY aa.ZORIGINALFILESIZE DESC LIMIT 30;"
  echo "  Screenshots and hidden items:"
  Q "SELECT SUM(a.ZISDETECTEDSCREENSHOT = 1) AS screenshots,
            ROUND(SUM(CASE WHEN a.ZISDETECTEDSCREENSHOT = 1 THEN aa.ZORIGINALFILESIZE END)/1073741824.0, 1) AS screenshot_GB,
            SUM(a.ZHIDDEN = 1) AS hidden
     $J WHERE a.ZTRASHEDSTATE = 0;"
else
  echo "  Could not read the Photos database (no Full Disk Access, or a different library is in use)."
fi

# ------------------------------------------------------------------ messages
hdr "3. Messages attachments (stored in iCloud when Messages in iCloud is on)"
echo "  On this Mac: $(du -sh ~/Library/Messages/Attachments 2>/dev/null | cut -f1)"
if cp ~/Library/Messages/chat.db "$TMP/c.db" 2>/dev/null; then
  cp ~/Library/Messages/chat.db-wal "$TMP/c.db-wal" 2>/dev/null; cp ~/Library/Messages/chat.db-shm "$TMP/c.db-shm" 2>/dev/null
  echo "  All attachments known to Messages, per year:"
  sqlite3 -header -column "$TMP/c.db" "SELECT strftime('%Y', created_date + 978307200, 'unixepoch') AS year,
      COUNT(*) AS files, ROUND(SUM(total_bytes)/1073741824.0, 2) AS GB
      FROM attachment GROUP BY 1 ORDER BY 1;" 2>&1 | sed 's/^/    /'
  echo "  20 biggest attachments:"
  sqlite3 -header -column "$TMP/c.db" "SELECT ROUND(total_bytes/1048576.0) AS MB,
      date(created_date + 978307200, 'unixepoch') AS date, transfer_name AS file
      FROM attachment ORDER BY total_bytes DESC LIMIT 20;" 2>&1 | sed 's/^/    /'
fi

# ------------------------------------------------------------------ mail + backups
hdr "4. Mail and local device backups"
echo "  Mail on this Mac (all accounts): $(du -sh ~/Library/Mail 2>/dev/null | cut -f1)"
echo "  iPhone/iPad backups on this Mac (local, not iCloud): $(du -sh ~/Library/Application\ Support/MobileSync/Backup 2>/dev/null | cut -f1)"

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"

# ------------------------------------------------------------------ settings
open "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" 2>/dev/null
cat >&3 <<'EOF'

Report saved. One manual step, because a Mac cannot read iCloud backups and
other apps' data from the command line:

  System Settings (now opening) > your name > iCloud > Storage > Manage...
  Take a screenshot of that list (Cmd+Shift+4, Space, click the window) and
  save it next to the report. If the list scrolls, take two.
EOF
sleep 1
