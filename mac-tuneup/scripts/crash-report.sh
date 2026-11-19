#!/bin/bash
# mac-tuneup: read-only report of what keeps crashing on this Mac and who owns
# it. Reads macOS's own crash and resource reports and, per process, shows how
# often and when it failed, whether it is an app, a helper, an app extension
# (Quick Look, thumbnail, share ...) or a part of macOS, which app it belongs
# to or was working for, and whether that program is still installed.
# Changes nothing.
#
#   bash crash-report.sh            last 7 days; report also in ./crashes-<date>.txt
#   bash crash-report.sh 30         last 30 days
#   MIN=5 bash crash-report.sh      detail only for processes with 5+ reports (default 3)
#
# Reads ~/Library/Logs/DiagnosticReports and /Library/Logs/DiagnosticReports.
# macOS deletes old reports itself, so long periods may be incomplete.
# Also lists slow shutdowns (decoded with spindump), hang reports and kernel
# panics. Out-of-memory kills (JetsamEvent) are in diagnose.sh, not here.

DAYS="${1:-7}"
MIN="${MIN:-3}"
case "$DAYS" in ''|*[!0-9]*) grep '^#   ' "$0" | sed 's/^#//'; exit 1 ;; esac

OUTDIR="${OUTDIR:-$PWD}"   # reports go to the current folder unless OUTDIR is set
OUT="$OUTDIR/crashes-$(date +%Y%m%d-%H%M).txt"
exec > >(tee "$OUT") 2>&1

hdr() { echo; echo "=== $* ==="; }
DR=(~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports)
US=$'\x1f'   # field separator that cannot occur in a path
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NOW=$(date +%s)

echo "Report started $(date '+%Y-%m-%d %H:%M:%S'), looking back $DAYS days"

# first "key":"value" in a .ips file, JSON slashes unescaped
jget() { grep -m1 -oE "\"$1\" ?: ?\"[^\"]*\"" "$2" | sed -E 's/^"[^"]*" ?: ?"(.*)"$/\1/; s|\\/|/|g'; }
# first "Key:   value" line in a text report (.diag, .hang, .spin, .crash)
tget() { grep -m1 "^$1:" "$2" | sed -E "s/^$1: *//"; }

# ------------------------------------------------------------------ one line per report
find "${DR[@]}" -maxdepth 1 -type f -mtime "-$DAYS" \
  \( -name "*.ips" -o -name "*.diag" -o -name "*.crash" -o -name "*.hang" -o -name "*.spin" \) 2>/dev/null \
  | while IFS= read -r f; do
      name=$(basename "$f" | sed -E 's/[-_.][0-9]{4}-[0-9]{2}-[0-9]{2}.*//')
      case "$name" in JetsamEvent*|shutdown_stall*|"") continue ;; esac
      path="" resp="" coal="" bid="" exc=""
      case "$f" in
        *.ips)
          kind="crash"
          case "$name" in ExcUserFault_*) kind="fault, kept running"; name=${name#ExcUserFault_} ;; esac
          path=$(jget procPath "$f"); resp=$(jget responsibleProc "$f"); coal=$(jget coalitionName "$f")
          bid=$(head -1 "$f" | grep -oE '"bundleID":"[^"]*"' | cut -d'"' -f4)
          e=$(grep -m1 -oE '"exception" ?: ?\{[^}]*\}' "$f")
          exc=$(echo "$e" | grep -oE '"type":"[^"]*"' | cut -d'"' -f4)
          sig=$(echo "$e" | grep -oE '"signal":"[^"]*"' | cut -d'"' -f4)
          [ -n "$sig" ] && exc="$exc $sig" ;;
        *)
          kind=$(tget Event "$f"); kind="${kind:-resource report}"
          case "$f" in *.crash) kind="crash"; exc=$(tget "Exception Type" "$f") ;; esac
          path=$(tget Path "$f"); resp=$(tget Responsible "$f"); bid=$(tget Identifier "$f") ;;
      esac
      printf '%s\n' "$(stat -f %m "$f")$US$name$US$kind$US$path$US$resp$US$coal$US$bid$US$exc$US$f"
    done > "$TMP/all"

total=$(wc -l < "$TMP/all" | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo; echo "No crash or resource reports in the last $DAYS days."
  echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"; sleep 1; exit 0
fi

# ------------------------------------------------------------------ per process + kind, newest report wins
awk -F"$US" -v OFS="$US" -v now="$NOW" '
  { k=$2 FS $3; n[k]++; if (now-$1 < 86400) d[k]++
    if (!(k in first) || $1 < first[k]) first[k]=$1
    if ($1 >= last[k]) { last[k]=$1; row[k]=$2 OFS $3 OFS $4 OFS $5 OFS $6 OFS $7 OFS $8 OFS $9 } }
  END { for (k in n) print n[k], d[k]+0, first[k], last[k], row[k] }' "$TMP/all" \
  | sort -t"$US" -k1,1nr -k4,4nr > "$TMP/agg"

# outermost .app bundle in a path, or nothing
app_of() { echo "$1" | awk -F/ '{p=""; for (i=2; i<=NF; i++) { p=p "/" $i; if ($i ~ /\.app$/) { print p; exit } } }'; }
is_apple() { case "$1" in /System/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*|/usr/libexec/*|/sbin/*|/bin/*|/Library/Apple/*) return 0 ;; esac; return 1; }
when() { date -r "$1" '+%m-%d %H:%M'; }

# sets TYPE, WHAT, OWNER, LABEL (one line for the tables) and HINT for the current row
describe() {
  local app appname type trigger=""
  # resource reports hide the user name; put it back so the path can be checked
  path=${path/#\/Users\/USER\//$HOME/}
  app=$(app_of "$path"); appname=$(basename "${app:-}" .app)
  case "$path" in
    *.appex/*) type="extension" ;;
    *.xpc/*)   type="XPC service" ;;
    "$app/Contents/MacOS/"*) type="app" ;;
    *.app/*)   type="helper" ;;
    "")        type="process" ;;
    *)         type="tool" ;;
  esac
  [ -n "$resp" ] && [ "$resp" != "$name" ] && trigger="$resp"
  if [ -z "$trigger" ]; then
    case "$coal" in ""|com.apple.*) ;; *) is_apple "$path" && trigger="$coal" ;; esac
  fi
  TYPE="$type"
  GONE=0
  case "$path" in ""|*\**) ;; *) [ -e "$path" ] || GONE=1 ;; esac   # a shortened path (*) cannot be checked

  if [ -z "$path" ]; then
    WHAT="$type"; OWNER="unknown (report has no path)"
  elif is_apple "$path"; then
    WHAT="macOS $type"; OWNER="Apple${trigger:+, working for $trigger}"
  else
    WHAT="$type"; OWNER="${appname:-$(dirname "$path")}"
    [ "$type" = app ] || WHAT="$type of ${appname:-a non-Apple program}"
  fi
  [ "$GONE" = 1 ] && OWNER="$OWNER (no longer installed)"
  case "$WHAT" in app|process|tool|macOS*) LABEL="$WHAT: $OWNER" ;; *) LABEL="$WHAT"; [ "$GONE" = 1 ] && LABEL="$LABEL (no longer installed)" ;; esac

  case "$kind" in crash|fault*) ;; *)
    HINT="Not a crash: macOS logged \"$kind\" for it. Worth a look only if it repeats daily or the Mac is hot or slow at those times."
    return ;;
  esac
  if [ "$GONE" = 1 ]; then
    HINT="The program is no longer on this Mac, so these reports are history. Nothing to do."
  elif is_apple "$path" && [ -n "$trigger" ]; then
    HINT="A part of macOS failed while working for $trigger. The cause is usually that app: update it, and if it continues, see whether it stops while $trigger is closed."
  elif is_apple "$path"; then
    HINT="Part of macOS. Restart, install pending macOS updates, and run this again in a few days."
  elif [ "$type" = extension ]; then
    state=""
    [ -n "$bid" ] && case "$(pluginkit -m -A -i "$bid" 2>/dev/null | head -1 | cut -c1)" in
      -) state=" It is currently switched off." ;; "") ;; *) state=" It is currently switched on." ;;
    esac
    HINT="An extension that $appname adds to macOS (Finder previews, thumbnails, sharing ...).$state Update $appname; if it keeps crashing, switch the extension off in System Settings > General > Login Items & Extensions, or remove the app if unused."
  else
    HINT="Update ${appname:-it}. If it keeps crashing after the update, reinstall it or report it to its developer with the newest file below."
  fi
}

# ------------------------------------------------------------------ overview
hdr "1. Everything that produced a report, most frequent first ($total reports)"
printf "  %5s %4s  %-11s  %-34s %-22s %s\n" count 24h last process what "owner"
while IFS="$US" read -r n d _first last name kind path resp coal bid exc _file; do
  describe
  printf "  %5s %4s  %-11s  %-34s %-22s %s\n" "$n" "$d" "$(when "$last")" "${name:0:34}" "${kind:0:22}" "$LABEL"
done < "$TMP/agg"

# ------------------------------------------------------------------ detail
hdr "2. Repeat offenders ($MIN or more reports): cause and what to do"
shown=0
while IFS="$US" read -r n d first last name kind path resp coal bid exc file; do
  [ "$n" -ge "$MIN" ] || continue
  shown=1
  describe
  quiet=$(( (NOW - last) / 86400 ))
  echo "  -- $name: $n x $kind, $(when "$first") to $(when "$last"), $d in the last 24 h"
  [ "$quiet" -ge 2 ] && echo "     quiet for $quiet days: it may already have stopped"
  echo "     what:   $WHAT"
  echo "     owner:  $OWNER"
  [ -n "$path" ] && echo "     path:   $path"
  [ -n "$exc" ]  && echo "     error:  $exc"
  echo "     -> $HINT" | fold -s -w 96 | sed -e 's/ *$//' -e '2,$s/^/        /'
  echo "     newest: $file"
  case "$file" in *.ips)
    grep -o '"symbol" *: *"[^"]*"' "$file" 2>/dev/null | head -6 | sed -E 's/.*: *"(.*)"/       \1/' ;;
  esac
done < "$TMP/agg"
[ "$shown" = 1 ] || echo "  none"

# ------------------------------------------------------------------ extensions
hdr "3. App extensions and helpers of non-Apple apps that crashed at least once"
found=0
while IFS="$US" read -r n _d _first last name kind path resp coal bid exc _file; do
  case "$kind" in crash|fault*) ;; *) continue ;; esac
  is_apple "$path" && continue
  describe
  case "$TYPE" in extension|"XPC service"|helper) ;; *) continue ;; esac
  found=1
  printf "  %4s x  %-34s %s (last %s)\n" "$n" "${name:0:34}" "$LABEL" "$(when "$last")"
done < "$TMP/agg"
[ "$found" = 1 ] || echo "  none"

# ------------------------------------------------------------------ stalls and panics
hdr "4. Slow shutdowns, hangs and kernel panics"
# a shutdownStall report is a binary sample of what was still running 2 s into
# a slow shutdown or restart; spindump turns it into text (no admin needed)
stalls=$(find "${DR[@]}" -maxdepth 1 -type f -mtime "-$DAYS" -name "*.shutdownStall" 2>/dev/null)
if [ -z "$stalls" ]; then
  echo "  slow shutdowns: none"
else
  printf '%s\n' "$stalls" | while IFS= read -r f; do
    # the file is often written hours later, so take the time from its name
    ts=$(basename "$f" | sed -nE 's/.*[0-9]{4}-([0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})[0-9]{2}.*/\1 \2:\3/p')
    echo "  slow shutdown or restart on ${ts:-$(when "$(stat -f %m "$f")")}"
    if ! perl -e 'alarm shift; exec @ARGV' 120 spindump -i "$f" -o "$TMP/stall.txt" >/dev/null 2>&1; then
      echo "     could not be decoded; open it with: spindump -i \"$f\""; continue
    fi
    awk '/^Process:/{p=$2} /^Path:/{sub(/^Path: */, ""); print p "\t" $0}' "$TMP/stall.txt" > "$TMP/stallprocs"
    echo "     still running at that moment: $(wc -l < "$TMP/stallprocs" | tr -d ' ') processes"
    other=0
    while IFS=$'\t' read -r p pth; do
      is_apple "$pth" && continue
      other=1; echo "     NOT part of macOS, may have held it up: $p ($pth)"
    done < "$TMP/stallprocs"
    [ "$other" = 1 ] || echo "     all of them part of macOS: no app held it up. One slow shutdown is normal; many are not."
    rm -f "$TMP/stall.txt"
  done
fi
hangs=$(grep -cE "\.(hang|spin)$" "$TMP/all")
echo "  apps reported as not responding (hang or spin reports): $hangs$([ "$hangs" -gt 0 ] && echo ", listed in section 1")"
panics=$(find "${DR[@]}" -maxdepth 1 -type f -mtime "-$DAYS" -iname "*panic*" 2>/dev/null)
if [ -z "$panics" ]; then
  echo "  kernel panics (the whole Mac restarting by itself): none"
else
  echo "  kernel panics (the whole Mac restarting by itself):"
  printf '%s\n' "$panics" | while IFS= read -r f; do echo "     $(when "$(stat -f %m "$f")")  $f"; done
  echo "     Repeated panics point at hardware, a kernel extension or a driver: show the file to Apple Support."
fi

echo
echo "Report finished $(date '+%H:%M:%S'). Saved to: $OUT"
sleep 1
