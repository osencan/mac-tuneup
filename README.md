# mac-tuneup

A Claude skill and a set of read-only scripts to find out **why** a Mac is
slow or full, fix it safely and free iCloud storage by moving Photos to an
external disk with verified deletion.

Built while tuning three Macs. Each had a different main cause:

| Mac | Main cause | What fixed it |
|-----|------------|---------------|
| iMac 2019, Intel | Fusion Drive (90% of data on the hard-disk part) and `routined` crashing every 20 minutes | Boot from an external SSD; Significant Locations reset |
| MacBook Pro M1 Pro, 32 GB | ~28 GB of apps open on 32 GB of RAM | Fewer editor windows, Chrome Memory Saver, weekly restart |
| MacBook Pro M3, 64 GB | Disk 91% full: Xcode simulators, data of uninstalled IDEs, an unused browser, dev caches | 40 GB free to 95 GB free, after the user chose what goes |

So: measure first. The skill makes an agent do exactly that.

## What is inside

```
mac-tuneup/
  SKILL.md                       the method for the agent
  scripts/
    diagnose.sh                  read-only health report
    space-detail.sh              read-only: where the disk space went
    icloud-report.sh             read-only: what fills iCloud
    network-check.sh             read-only: why iCloud downloads fail
    crash-report.sh              read-only: what keeps crashing, which app or extension owns it, what to do
    throttle-check.sh            read-only (sudo): is the Mac throttling, and why
    dethrottle.sh                report, or switch off (with undo) Low Power Mode, App Nap, background disk throttling
    apple-media-cleanup.sh       report, or move to the Trash (y/N per group) re-downloadable data of Podcasts, Music, TV, Books, GarageBand
    keep-awake.sh                sleep off for long jobs, with --undo
    photos-albums-verify.sh      albums per year, verify export, retry missing
    photos-delete-verified.sh    delete only items verified on disk (name + exact size)
  references/
    pitfalls.md                  what went wrong and what worked instead
    fix-patterns.md              templates for safe fix scripts
```

## Install

- **Claude Code:** `cp -r mac-tuneup ~/.claude/skills/`
- **Claude apps:** download `mac-tuneup.zip` from the latest Release and upload it in
  Settings > Capabilities > Skills (or zip the inner `mac-tuneup` folder yourself:
  `zip -r mac-tuneup.zip mac-tuneup`).
- **Without Claude:** run the read-only scripts yourself:
  `bash mac-tuneup/scripts/diagnose.sh`. Reports are written to the current folder.

Then ask: "My Mac is slow, use mac-tuneup" or "iCloud is almost full".

## What it will not do

Patch power management profiles, write CPU registers or disable SIP to
"remove Apple's throttling". The slowdowns macOS applies on purpose to save
energy (Low Power Mode, App Nap, background disk throttling) are reported and
can be switched off with an undo; protections are not. Heat and hardware-warning throttling are
measured and traced to their cause (dust, paste, battery, charger, load).
`references/pitfalls.md` explains why the viral "faster, cooler and longer
battery" story does not add up.

## Safety

- The diagnostic scripts change nothing.
- The agent asks before removing anything and writes fix scripts you run
  yourself; removals go to the Trash, settings changes have `--undo`.
- Photos deletion only touches items whose file on your disk has the same
  name and byte size, asks y/N, then macOS asks again and everything stays
  in Recently Deleted for 30 days.
- Read the scripts before you run them. They are short on purpose.

## iCloud Photos offload, in short

1. `BACKUP_DIR="/Volumes/MyDisk/icloud-backup" bash photos-albums-verify.sh albums videos`
2. In Photos, export each "Cleanup videos <year>" album with
   File > Export > Export Unmodified Original into the folder it printed.
3. `... photos-albums-verify.sh verify videos` (and `retry videos` for gaps).
4. `... photos-delete-verified.sh videos`, then empty Recently Deleted.

Use a wired connection and one album at a time. osxphotos is used only to
build albums: its iCloud download timed out or hung on large libraries.

## Requirements

macOS 13 or later, bash, Xcode or Command Line Tools for the delete helper
(`swiftc`), Python 3 for osxphotos (installed on first use into
`~/.local/share/osxphotos-venv`). Full Disk Access for Terminal for complete
numbers.

## Support

If mac-tuneup saved you time or iCloud space, you can
[sponsor it on GitHub](https://github.com/sponsors/osencan).

## License

MIT. See LICENSE.
