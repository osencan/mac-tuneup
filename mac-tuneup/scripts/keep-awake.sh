#!/bin/bash
# mac-tuneup: keeps the Mac from sleeping during a long job (for example a
# Photos export), even with the lid closed. The screen may still turn off.
#
#   bash keep-awake.sh            turn sleep off (admin password)
#   bash keep-awake.sh --status   show the current state
#   bash keep-awake.sh --undo     restore the previous settings (admin password)
#
# Changes: pmset disablesleep 1 (all power sources) and pmset -c sleep 0
# (on the charger). The previous values are read from pmset and saved in
# ~/.local/state/mac-tuneup/sleep-settings-before.txt; --undo puts them back.
#
# With the lid closed the Mac still makes heat: leave it on a hard surface,
# not in a bag and on the charger.

STATE="$HOME/.local/state/mac-tuneup/sleep-settings-before.txt"
mkdir -p "$(dirname "$STATE")"

ac_sleep() { pmset -g custom | awk '/^AC Power/{f=1; next} /Power:$/{f=0} f && $1=="sleep"{print $2; exit}'; }
disabled() { v=$(pmset -g | awk '$1=="SleepDisabled"{print $2}'); echo "${v:-0}"; }

status() {
  echo "  Sleep disabled (lid too): $(disabled)   (1 = Mac never sleeps)"
  echo "  Sleep on charger after:   $(ac_sleep) min   (0 = never)"
  if pmset -g assertions | grep -q caffeinate; then
    echo "  caffeinate is running (something is keeping the Mac awake)."
  fi
}

case "$1" in
  --status)
    status ;;
  --undo)
    if [ ! -f "$STATE" ]; then echo "No saved settings; nothing to undo."; status; exit 0; fi
    # shellcheck disable=SC1090
    . "$STATE"
    echo "Restoring: disablesleep $PREV_DISABLE, sleep on charger $PREV_AC_SLEEP min (admin password)"
    sudo pmset -a disablesleep "$PREV_DISABLE" && sudo pmset -c sleep "$PREV_AC_SLEEP" \
      && rm -f "$STATE" && echo "Restored."
    status ;;
  "")
    if [ ! -f "$STATE" ]; then   # keep the very first values, even if run twice
      printf 'PREV_DISABLE=%s\nPREV_AC_SLEEP=%s\n' "$(disabled)" "$(ac_sleep)" > "$STATE"
    fi
    echo "Turning sleep off (admin password)..."
    sudo pmset -a disablesleep 1 && sudo pmset -c sleep 0 && echo "Done. Undo later with: bash keep-awake.sh --undo"
    status ;;
  *)
    grep '^#   bash' "$0" | sed 's/^#//'; exit 1 ;;
esac
