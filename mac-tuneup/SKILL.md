---
name: mac-tuneup
description: Diagnose and fix a slow Mac, a nearly full disk or nearly full iCloud storage by measuring first and fixing second, with read-only diagnostic scripts, safe fix-script patterns and a verified iCloud Photos offload to an external disk. Use when a Mac feels slow, the startup disk or iCloud is nearly full, or the user wants a safe cleanup.
---

# mac-tuneup

Find out with measurements why a Mac is slow or full, tell the user what
matters most and give them small scripts they run themselves. Three Macs
tuned with this method had three different main causes (a Fusion Drive plus a
crash-looping daemon, too little RAM for the open apps, a full disk), so never
fix before measuring.

## Ground rules

- **Read-only first.** Change nothing while investigating.
- **The user runs the fixes.** Write scripts; never apply changes yourself
  unless asked. Anything with `sudo` goes in a script (you cannot type their password).
- **Ask before removing any app, helper or data.** Present candidates with
  sizes and a recommendation; let the user choose.
- **Never delete user data.** Move to `~/.Trash/<name>-removed-<timestamp>/`.
  Settings changes take `--undo` and record the previous value.
- **Never disable** security updaters, Spotlight, Gatekeeper, SIP or FileVault,
  and never erase, partition or reformat a disk.
- **Never remove thermal or power protections.** Do not patch power
  management profiles or kexts, write CPU registers (for example to turn off
  BD PROCHOT), or disable the sealed system volume to "unlock" speed.
  Throttling from heat or a hardware warning is a symptom: find and fix the
  cause. Treat "Claude removed Apple's throttling" stories as claims to test,
  not recipes (see `references/pitfalls.md`).
- **Be honest about the gain.** Say when a fix helps only a little, and correct
  yourself in the README when a finding turns out wrong.

## Where things run

The scripts must run on the Mac. If you have a shell on it, run the read-only
ones yourself. If you only have a sandbox or a synced folder, put the scripts
in a folder the user can reach, have them run
`bash <script> > /dev/null 2>&1` and read the report file the script writes
next to where it ran (`diagnose-<date>.txt` etc.). Scripts that ask y/N or for
a password must run without `> /dev/null`.

If files you need read as 0 bytes, they are probably cloud placeholders
(Dropbox online-only, iCloud optimized): ask the user to make the folder
available offline.

## Workflow

1. **Diagnose.** `scripts/diagnose.sh` (1-2 min): machine, power and
   throttling, memory pressure and per-app memory, out-of-memory kills, CPU
   over 30 s, disk space, launch items whose program is gone, login items,
   Rosetta, repeat crashers, displays.
2. **Rank and report early.** Main finding first, in plain words, with numbers.
   Then a short "what is fine" list.
3. **Dig where it matters.**
   - Disk under ~20% free: `scripts/space-detail.sh` (give Terminal Full Disk
     Access first). Use `xcrun simctl runtime list` for simulator sizes.
   - Memory: name the apps; compressor over ~3 GB, swap over ~2 GB or
     out-of-memory kills mean pressure (check the JetsamEvent `reason`).
   - Throttling suspected (CPU_Speed_Limit below 100, busy `kernel_task`,
     loud fans, an older Intel MacBook stuck slow): `scripts/throttle-check.sh`
     (sudo, read-only). It measures frequency, temperature, thermal pressure,
     charger and battery, and names the pattern: heat (clean vents/fans,
     paste, load), BD PROCHOT on Intel (battery, charger, port, sensor; SMC
     reset) or no throttling at all.
   - A daemon crashing every few minutes (`ReportCrash`/`coresymbolicationd`
     busy, many `.ips` files for one process): read the backtrace.
4. **Ask.** One question per area with sizes and a recommended option
   (simulators, models, old app data, caches, helpers). Use multi-select.
5. **Write the fix scripts** with the patterns in
   `references/fix-patterns.md`: numbered, one fix each, y/N per group, Trash
   not rm, sizes shown first. Run `bash -n` and `shellcheck` on each.
6. **Verify.** Write a read-only check that every removed item is gone and
   every job unloaded, compare free space with the baseline, then restart and
   run `diagnose.sh` again. The second pass catches what the first missed.
7. **README** in the user's folder: findings table, what is fine, what they
   kept, run order, what was applied, expected gain.

## iCloud nearly full

1. `scripts/icloud-report.sh` (Full Disk Access needed): iCloud Drive by
   folder (cloud size), Photos by kind and year with the biggest videos and
   screenshots, Messages attachments, Mail.
2. Ask for a screenshot of System Settings > Apple Account > iCloud > Manage.
   Backups and data of apps not on the Mac are only visible there.
3. Plan with the user. Usual levers: big videos and old screenshots to an
   external disk, old device backups, big apps excluded from the iPhone
   backup, WhatsApp backup without videos, large Messages attachments.
   Mention the bigger plan as the honest alternative when the library grows
   faster than cleanup frees.
4. Photos offload (needs `BACKUP_DIR`, e.g. `/Volumes/MyDisk/icloud-backup`):
   - `scripts/photos-albums-verify.sh albums videos|screenshots|years ...`
     builds one album per year (nothing downloaded or deleted).
   - The user exports each album **from Photos** (Export Unmodified
     Original). Do not use osxphotos to download from iCloud; see pitfalls.
   - `... verify <kind>` lists albums fully on disk; `... retry <kind>`
     makes albums of the missing items only.
   - `scripts/photos-delete-verified.sh <kind>` deletes only items whose file
     on disk has the same name and byte size, via PhotoKit, into Recently
     Deleted (30 days). The user empties Recently Deleted to free iCloud.
   - Downloads failing with -1009 or crawling: `scripts/network-check.sh`;
     use a wired connection, one album at a time,
     `scripts/keep-awake.sh` during long exports (`--undo` afterwards).
5. App data in iCloud (for example notes apps): it may live in CloudKit, not in
   files. Export from inside the app before deleting it in Manage Storage.

## Read before writing fixes

- `references/pitfalls.md`: what went wrong in real sessions (hanging
  commands, lying benchmarks, du traps, the routined crash loop, osxphotos
  timeouts, overnight exports on Wi-Fi) and what worked instead.
- `references/fix-patterns.md`: script templates for Trash moves, launchd
  items, settings with `--undo`, simulators, click-only fixes, verify passes.
