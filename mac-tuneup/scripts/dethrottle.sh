#!/bin/bash
# mac-tuneup: the slowdowns macOS applies ON PURPOSE to save energy, which a
# user may legitimately switch off, each with its trade-off and an undo.
#
#   bash dethrottle.sh            report only (changes nothing)
#   bash dethrottle.sh --apply    asks y/N per item (admin password for pmset/sysctl)
#   bash dethrottle.sh --undo     puts every changed value back
#
# What it covers:
#   1. Energy mode on the charger: Low Power Mode off (or High Power Mode on
#      Macs that have it; louder fans).
#   2. Energy mode on battery: Low Power Mode off (shorter battery life).
#   3. App Nap, globally: background apps are no longer slowed down
#      (more battery use; apps pick it up when relaunched).
#   4. Background disk throttling (debug.lowpri_throttle_enabled) until the
#      next restart, for one long backup or copy. Little benefit on Apple
#      silicon in Eclectic Light's tests, and Spotlight can then swamp the disk.
# Report only: charger wattage, battery condition, thermal state.
#
# What it never touches: thermal limits, the SMC, BD PROCHOT, kernel
# extensions, SIP or the sealed system volume. Heat and hardware-warning
# throttling protect the Mac: measure them with throttle-check.sh and fix
# the cause. Battery health management only changes charging (Apple), not
# CPU speed, so there is nothing to "unlock" there.
#
# Previous values are saved in ~/.local/state/mac-tuneup/dethrottle-before.txt.

STATE="$HOME/.local/state/mac-tuneup/dethrottle-before.txt"
mkdir -p "$(dirname "$STATE")"
ask() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
# value of a pmset key in one power source section ("Battery Power" / "AC Power")
val() { pmset -g custom 2>/dev/null | awk -v sec="$1" -v key="$2" \
  'index($0, sec ":") == 1 {f=1; next} /Power:$/ {f=0} f && $1 == key {print $2; exit}'; }
mode_name() {  # $1 = powermode or lowpowermode value, $2 = key
  case "$2:$1" in
    powermode:0) echo "Automatic" ;; powermode:1) echo "Low Power" ;; powermode:2) echo "High Power" ;;
    lowpowermode:0) echo "Low Power Mode off" ;; lowpowermode:1) echo "Low Power Mode ON" ;;
    *) echo "not available" ;;
  esac
}

# Macs with Power Modes use the key "powermode"; others use "lowpowermode"
if [ -n "$(val "AC Power" powermode)$(val "Battery Power" powermode)" ]; then KEY=powermode; else KEY=lowpowermode; fi
AC=$(val "AC Power" "$KEY"); BAT=$(val "Battery Power" "$KEY")
NAP=$(defaults read -g NSAppSleepDisabled 2>/dev/null || echo unset)
IO=$(sysctl -n debug.lowpri_throttle_enabled 2>/dev/null)

report() {
  echo "Energy-saving slowdowns (the ones you may switch off):"
  echo "  on the charger:  $(mode_name "$(val "AC Power" "$KEY")" "$KEY")"
  echo "  on battery:      $(mode_name "$(val "Battery Power" "$KEY")" "$KEY")"
  n=$(defaults read -g NSAppSleepDisabled 2>/dev/null)
  echo "  App Nap:         $([ "$n" = 1 ] && echo "disabled globally" || echo "on (default)")"
  i=$(sysctl -n debug.lowpri_throttle_enabled 2>/dev/null)
  echo "  background disk throttling: $([ "$i" = 0 ] && echo "OFF (until restart)" || echo "on (default)")"
  echo
  echo "Report only (not settings to switch off):"
  system_profiler SPPowerDataType 2>/dev/null | grep -E "Condition|Maximum Capacity|Wattage" | sed 's/^ */  /'
  pmset -g therm | grep -vE "^Note: No" | sed 's/^/  /'
  pmset -g therm | grep -q "No thermal warning" && echo "  no thermal warning recorded"
  echo "  (Condition 'Service Recommended' on an Intel MacBook can cause hard throttling:"
  echo "   that needs a battery, not a setting. See throttle-check.sh.)"
}

case "$1" in
  "")
    report ;;

  --apply)
    report; echo
    [ -f "$STATE" ] || printf 'KEY=%s\nPREV_AC=%s\nPREV_BAT=%s\nPREV_NAP=%s\nPREV_IO=%s\n' \
      "$KEY" "$AC" "$BAT" "$NAP" "$IO" > "$STATE"

    if [ -n "$AC" ]; then
      if [ "$KEY" = powermode ]; then
        if [ "$AC" = 1 ] && ask "On the charger: switch Low Power to Automatic?"; then sudo pmset -c powermode 0; fi
        if ask "On the charger: High Power Mode (Pro/Max chips only; faster under sustained load, louder fans)?"; then sudo pmset -c powermode 2 || echo "  this Mac has no High Power Mode"; fi
      elif [ "$AC" = 1 ] && ask "On the charger: turn Low Power Mode off?"; then
        sudo pmset -c lowpowermode 0
      fi
    fi
    if [ -n "$BAT" ] && { [ "$BAT" = 1 ] && ask "On battery: turn Low Power Mode off (shorter battery life)?"; }; then
      if [ "$KEY" = powermode ]; then sudo pmset -b powermode 0; else sudo pmset -b lowpowermode 0; fi
    fi
    if [ "$NAP" != 1 ] && ask "Disable App Nap for all apps (background apps run at full speed, more battery use)?"; then
      defaults write -g NSAppSleepDisabled -bool YES && echo "  done; quit and reopen the apps that should benefit"
    fi
    if [ "$IO" = 1 ] && ask "Turn off background disk throttling until the next restart (for one long backup/copy)?"; then
      sudo sysctl debug.lowpri_throttle_enabled=0
    fi
    echo; echo "Now:"; report
    echo; echo "Undo any time:  bash dethrottle.sh --undo" ;;

  --undo)
    [ -f "$STATE" ] || { echo "Nothing saved; nothing to undo."; report; exit 0; }
    # shellcheck disable=SC1090
    . "$STATE"
    echo "Restoring the values saved before --apply (admin password)..."
    [ -n "$PREV_AC" ]  && sudo pmset -c "$KEY" "$PREV_AC"
    [ -n "$PREV_BAT" ] && sudo pmset -b "$KEY" "$PREV_BAT"
    if [ "$PREV_NAP" = unset ]; then defaults delete -g NSAppSleepDisabled 2>/dev/null
    else defaults write -g NSAppSleepDisabled -bool "$([ "$PREV_NAP" = 1 ] && echo YES || echo NO)"; fi
    [ -n "$PREV_IO" ] && sudo sysctl debug.lowpri_throttle_enabled="$PREV_IO" >/dev/null
    rm -f "$STATE" && echo "Restored."
    echo; report ;;

  *)
    grep '^#   bash' "$0" | sed 's/^#//'; exit 1 ;;
esac
