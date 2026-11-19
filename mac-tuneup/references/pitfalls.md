# Pitfalls: what went wrong in real sessions and what to do instead

Collected from tuning three Macs (iMac 2019 Intel with Fusion Drive, MacBook Pro
M1 Pro 32 GB, MacBook Pro M3 64 GB) and offloading ~150 GB of iCloud Photos.
Each Mac had a different main cause, which is the whole argument for measuring
before fixing.

## Measuring

- **Some commands hang.** `sfltool dumpbtm` and `osascript ... System Events ...
  login items` can block for minutes. Run them alone with a time limit (macOS
  has no `timeout`; use `perl -e 'alarm shift; exec @ARGV' 20 cmd ...`).
- **zsh aborts on unmatched globs** ("no matches found") and hides the results
  of the globs that did match. Use `find ... -iname` or run scripts with bash.
- **One CPU sample proves nothing.** Daemons like `bird` and `helpd` looked stuck
  in one sample and were idle minutes later. Sample 6 times over 30 s or more.
- **A daemon is busy right after a restart.** Wait and re-sample before calling it stuck.
- **Disk benchmarks lie unless the cache is bypassed.** A plain `dd` read gave
  8900 MB/s, which was RAM. Use `F_NOCACHE` and measure random 4K reads too.
- **`du` undercounts app containers** unless Terminal has Full Disk Access.
  Check with `ls ~/Library/Safari` (works only with FDA) and say so in the report.
- **`du` over `/Library/Developer/CoreSimulator/Volumes` double counts**: it walks
  the mounted simulator images, which live elsewhere. Use
  `xcrun simctl runtime list` for runtime sizes.
- **Free space looks fine but the gap is large.** Compare `df` used space with
  what `du` found; the rest is usually simulators, cloud folders kept locally
  (classic `~/Dropbox`, `~/Library/CloudStorage`), Docker or model caches.
- **Files that read as 0 bytes may be cloud placeholders** (Dropbox online-only,
  iCloud optimized). Staging or catting them does not download them. Ask the
  user to make the folder available offline.
- **`diskutil list` shows ExFAT as "Windows_NTFS".** Use `diskutil info`.
- **`disk0`/`disk1` can swap between boots.** Never hardcode the SSD.
- **An out-of-memory kill is not always RAM shortage.** Read the JetsamEvent
  `reason`: `per-process-limit` means one process hit its own cap; only
  `vm-pageshortage`-type reasons point at the whole Mac.
- **`launchctl list` showing a third-party agent "not loaded"** can mean the
  user's own scheduled jobs are not running at all. Worth one line in the report.
- **Make the reports write themselves to a file** next to the script
  (`exec > >(tee "$OUT") 2>&1`). The agent reads the file; nobody pastes 400 lines.
- **`> /dev/null 2>&1` hides prompts.** Only use it for read-only scripts.
  Anything that asks y/N or for a password must run in the open.

## Causes that mattered

- **iMac 2019:** Fusion Drive with 90% of the data on the hard-disk part, plus
  the `routined` crash loop (below). Fix: boot from an external SSD.
- **MacBook Pro M1 Pro, 32 GB:** ~28 GB of apps open on 32 GB of RAM (editors
  with several project windows, Chrome, AI apps, a sandbox VM). No setting
  fixes that; closing windows, Chrome Memory Saver and weekly restarts do.
- **MacBook Pro M3, 64 GB:** disk 91% full. Xcode simulator runtimes and caches
  (~50 GB), data of uninstalled JetBrains IDEs (17 GB), an unused browser
  (7 GB), developer caches (6 GB). Result: 40 GB free (9%) to 95 GB (21%).

## "Claude removed Apple's throttling": what is real

Viral posts claim an agent "patched the power management profiles, cleared the
related caches and disabled the forced limits" on an old Intel MacBook, which
then ran faster, cooler and longer on battery. Checked against how Macs work:

- **Apple has not said Macs get slower with age.** The 2017 battery throttling
  statement and settlement were about iPhones.
- **The power management profiles are system files.** Since Big Sur they live
  on the signed, sealed system volume; changing them means turning off SIP and
  authenticated root, which weakens security and breaks with updates.
  Heat-based limits are enforced by the SMC and the CPU itself anyway.
- **There is no throttling cache to clear.**
- **Faster, cooler and longer battery at the same time contradicts removing
  limits.** More speed means more power and more heat. When all three improve,
  something else changed: a runaway process stopped, a restart, cleaned vents,
  a different charger.
- **What is real:** thermal throttling (`pmset -g therm`, `kernel_task` taking
  CPU on purpose to cool the Mac) and, on 2013-2016 Intel MacBooks, BD PROCHOT:
  a hardware warning line that pins the CPU near 800 MHz, usually from a worn
  battery, a non-Apple or damaged charger, the charging port or a sensor. Tools
  that switch BD PROCHOT off hide the warning instead of fixing it.
- **What helps:** measure with `throttle-check.sh`; clean fans and vents and
  renew thermal paste on old Macs; original charger; battery service when its
  condition says so; SMC reset on Intel; stop the process causing the load.

## The routined crash loop

`ReportCrash` and `coresymbolicationd` at the top of the CPU list on an idle
Mac, and dozens of `routined-*.ips` reports in bursts: `routined` (Significant
Locations) crashed on its damaged history every time launchd restarted it.
Not scriptable. Fix by hand: Privacy & Security > Location Services > System
Services > Significant Locations: clear history or switch it off. On laptops
prefer that narrow switch over turning off Location Services (Find My).
Lesson: a crash loop never shows as one busy process; look for the crash
reporters, then count reports per process.

## Removing things

- **Ask before removing any app or helper.** A process list does not tell you
  what the user relies on.
- **Match leftovers by bundle id, not by name.** macOS's own CoreDuet has
  nothing to do with the Duet app.
- **Move to `~/.Trash/<name>-removed-<timestamp>/`, prefix each item with its
  parent folder name**; several items share names like `models` or `Caches`.
- **A tool's data folder may hold more than you think.** Moving
  `~/Library/Application Support/JetBrains` also reset JetBrains Toolbox's
  own settings. List the contents before moving.
- **Clearing caches does not speed a Mac up.** Offer it only when free space is
  the actual problem.
- **Never disable security updaters** (Google/Chrome, Software Update, XProtect),
  Spotlight, Gatekeeper, SIP or FileVault for speed.

## iCloud

- **The Manage Storage screen is the truth.** A Mac cannot see iCloud device
  backups or data of apps not installed on it. Get a screenshot of
  System Settings > Apple Account > iCloud > Manage.
- **iCloud backups cannot be downloaded or moved.** Options: delete backups of
  old devices, or shrink the current one by switching off big apps under
  Backups > this iPhone. Photos and Messages are not in it when they sync.
- **Some apps keep their iCloud data in CloudKit, not iCloud Drive files**
  (Notability did: its iCloud Drive container was empty). Export from inside
  the app, on the device that has it.
- **Messages attachments and Photos overlap.** The largest Messages
  attachment was also in Photos, so it was counted twice.
- **WhatsApp's iCloud backup** shrinks a lot when "Include Videos" is off.

## iCloud Photos offload: what did not work

- **osxphotos `--download-missing` (AppleScript route):** waits only 120 s per
  item and this is not configurable from the CLI. Big iCloud-only videos never
  finish in time, so it force-quits Photos and retries in a loop. Even small
  screenshots failed this way. Two files arrived in hours.
- **osxphotos `--use-photokit`:** got some files, then hung ("Python not
  responding") or reported items missing. The project itself labels it
  experimental.
- **Two exports at the same time:** both drive Photos and both stall.
- **Leaving a Photos export running overnight on Wi-Fi:** 13 of 31 videos
  arrived; the rest failed with "Unknown error (-1009)" (= the Mac was offline
  at that moment) and "Could not download from iCloud". The network check
  showed 15 Mbit/s with poor responsiveness and 600+ offline events in the log.

## iCloud Photos offload: what worked

1. Build one album per year and category with osxphotos (`query
   --add-to-album`: reads the database, adds in batches of 10, downloads nothing).
2. Let **Photos** export each album: File > Export > Export Unmodified
   Original. It downloads originals itself and reports per-file errors.
3. Verify every item has a file on the disk; put only the missing ones in a
   retry album and export that.
4. Delete only what is verified by **name and exact byte size**, through
   PhotoKit (`PHAssetChangeRequest.deleteAssets`): macOS asks for
   confirmation and items stay in Recently Deleted for 30 days.
5. Prefer a wired connection and one album at a time; keep the Mac awake
   (`pmset disablesleep 1`, with an undo).
