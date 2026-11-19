# Fix-script patterns

Write one small bash script per fix, numbered in run order (`01-...sh`). The
user runs them; anything needing `sudo` must be inside a script. Test every
script with `bash -n` and `shellcheck -S warning`, and check any output
parsing against real output from that Mac.

## Header

State what was measured (numbers and date), what the script does, how to undo
it and what it deliberately leaves alone.

```bash
#!/bin/bash
# <What was found, with numbers and date.>
# What it does: ... Asks y/N per group.
#   bash 03-remove-leftover-helpers.sh
# Undo: everything is moved to ~/.Trash/Leftovers-removed-<timestamp>/.
# Left alone on purpose: <updaters, apps the user said to keep>.
```

## Ask, move to the Trash, never rm

```bash
TRASH="$HOME/.Trash/Leftovers-removed-$(date +%Y%m%d-%H%M%S)"
ask() { read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
# path -> Trash, prefixed with its parent folder name; 2nd arg "sudo" for root-owned files
to_trash() {
  local p="$1" sudo_cmd="$2"
  [ -e "$p" ] || return 0
  mkdir -p "$TRASH"
  if $sudo_cmd mv "$p" "$TRASH/$(basename "$(dirname "$p")")-$(basename "$p")" 2>/dev/null; then
    echo "  moved to Trash: $p"
  elif [ -n "$sudo_cmd" ]; then
    echo "  NOT moved (admin password not accepted; run again): $p"
  else
    echo "  could not move (macOS protects it; harmless): $p"
  fi
}
```

Show sizes before asking: `du -sh "$p"` for each item.

## Launch agents and daemons

```bash
GUI="gui/$(id -u)"
launchctl bootout "$GUI/com.vendor.agent" 2>/dev/null          # user agent
to_trash "$HOME/Library/LaunchAgents/com.vendor.agent.plist"
sudo launchctl bootout system/com.vendor.helper 2>/dev/null    # root daemon
to_trash /Library/LaunchDaemons/com.vendor.helper.plist sudo
to_trash /Library/PrivilegedHelperTools/com.vendor.helper sudo
# user leftovers by bundle id only
find "$HOME/Library" -maxdepth 2 \( -name "com.vendor.*" -o -name "*.com.vendor.*" \) 2>/dev/null
```

Flag orphans in the diagnosis by reading `Program` / `ProgramArguments:0` with
`/usr/libexec/PlistBuddy` and checking the path exists.

## Settings with --undo

Read the current value first, save it, restore it on `--undo`.

```bash
STATE="$HOME/.local/state/mac-tuneup/<fix>-before.txt"
case "$1" in
  --undo) . "$STATE" && sudo pmset -a disablesleep "$PREV" && rm -f "$STATE" ;;
  *) [ -f "$STATE" ] || echo "PREV=$(pmset -g | awk '$1=="SleepDisabled"{print $2}')" > "$STATE"
     sudo pmset -a disablesleep 1 ;;
esac
```

`defaults write com.apple.universalaccess ...` (Reduce transparency/motion)
fails without Full Disk Access: try, and on failure open the settings pane and
name the two switches.

## Xcode simulators

```bash
xcrun simctl list devices unavailable          # devices whose runtime is gone
xcrun simctl delete unavailable
xcrun simctl runtime list                      # runtimes, ids and total size
xcrun simctl runtime delete <id>               # re-downloadable in Xcode > Settings > Components
# stale dyld caches: folders under this path not named after `sw_vers -buildVersion`
ls /Library/Developer/CoreSimulator/Caches/dyld
```

Keep the newest runtimes the user tests on; ask about older ones and tvOS/watchOS.
iOS DeviceSupport is recreated when a device is plugged in; Archives are needed
for symbolicating shipped builds, so keep them.

## Fixes that need clicks

Write a guide script: print the numbers, open the pane
(`open "x-apple.systempreferences:..."`), list the exact clicks and offer a
`--check` mode that measures whether it worked (for example: no crash report
newer than the change).

## Throttling (measure, then fix the cause)

Never script around a protection. After `throttle-check.sh`:
- Heat: guide the user to clean vents and fans (older Macs: thermal paste by a
  repair shop), use a hard flat surface and stop the process causing load.
- BD PROCHOT pattern on Intel (low frequency, CPU not hot): test with the
  original Apple charger, compare on battery vs charger, check battery
  condition, then an SMC reset (Apple's steps differ per model: Macs with T2
  chip vs older; Apple silicon has no SMC reset, a restart does it).
- Low Power Mode on: say it caps performance on purpose; switching it off is
  the user's choice (Battery settings).
Re-run `throttle-check.sh` afterwards and compare the numbers.

## Verify pass

After the user ran the fixes, write a read-only verify script: every removed
path gone (`OK` / `STILL THERE`), every job not loaded
(`launchctl print <domain>/<label>`), caches that were rebuilt reported as
`BACK` (normal), free space versus the baseline, Trash size. Then restart and
run the diagnosis again: the second pass found the iMac's crash loop.

## README per Mac

Findings table (finding, impact, script), what is fine, what the user chose
to keep, run order, what was applied (with dates and numbers) and an honest
expectation of the gain.
