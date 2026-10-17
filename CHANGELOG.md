# Changelog

## 2.0.0

### New

- **Mac Migrate.app**, a native app for backup, restore and Free up space, built on your Mac with `./make-app.sh --install`. It shows progress with Stop, can quit and attach to a running backup again, and ends with the exact command for the new Mac.
- **Destinations**: `--to` writes the backup to Google Drive, iCloud Drive, OneDrive, Dropbox or Box through their desktop apps, or straight to a disk. For cloud drives each archive is freed on the Mac once uploaded, so a backup larger than the free space fits. The backup only reports done when everything has uploaded, and stops with an explanation when uploads stall.
- **Free up space** (`cleanup.sh`): lists caches and build output that tools recreate, by tier, and clears what you pick.
- **Split archives** for FAT32 disks and Box.
- `restore.sh --from` finds a backup below a folder, `--plan` shows what a restore will do, `--verify [--deep]` checks a backup without restoring.
- `backup.sh --list-places`, `--list-sources`, `--status`, `--plan` and `--redo NAME`.
- Logs in `~/.mac-migration/logs`. Configuration in `~/.mac-migration/config.sh`.

### Safer

- Format 2: `MANIFEST.txt` is signed with an HMAC derived from the password and lists every part with its size and checksum. The restore refuses changed manifests and damaged parts, and tells a wrong password apart from tampering. Format 1 backups still restore after a confirmation.
- Every archive is read back right after packing.
- The password reaches openssl through a file descriptor, never the command line.
- The Mac stays awake during a backup or restore, and only one runs at a time.
- Missing privacy access to Desktop, Documents or Downloads stops the backup instead of producing near-empty archives.

### Fixed

- A restore could overwrite files in Downloads when an archive had no plan entry.
- Restoring again after a username change from `/Users/name` to `/Users/name.surname` turned paths into `/Users/name.surname.surname`.
- tar failures were ignored, so a relative `OUT` produced empty archives marked as done.
- `EXCLUDE_NAMES` could drop listed settings items, such as `.gradle/gradle.properties`.
- The archives folder could be packed into a later archive when it was inside a backed-up folder.
- Typing `uploaded` deleted archives without checking where they were. Archives in a synced folder are now never deleted.
- A folder too large for the free space stopped the whole backup. It is now skipped and reported.
- `--add` accepted a folder that contained one already in the backup.
- The Homebrew hint after a restore missed Intel-to-Apple-silicon moves.
- The software package build no longer fails silently when the cask list or `brew bundle dump` is unavailable.

## 1.x

- `backup.sh`, `restore.sh` and `make-setup.sh`: encrypted archives of a fixed size, a restore that rewrites old home paths, and a software package with a Brewfile and setup script.
- Adding folders after a backup, merging top-level folders, keeping bundles such as Photos libraries whole.
