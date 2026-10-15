# mac-migrate

Move your developer setup to a new Mac when Migration Assistant isn't an option.

This is common on company Macs managed by Jamf, Intune, Kandji or similar. IT enrolls the new Mac from scratch, Migration Assistant is blocked or would drag along old management profiles, and your account may get a new username, for example `firstname.lastname` instead of `firstnamelastname`.

mac-migrate is two shell scripts:

- **`backup.sh`** packs your settings, keys and projects into encrypted archives of a fixed size. You move them through any cloud drive or external disk.
- **`restore.sh`** unpacks them on the new Mac and rewrites old home-folder paths if your username changed.

Both scripts run as your normal user: no admin rights, no app to install, no network pairing between the two Macs. They use only tools that ship with macOS (bash, tar, gzip, openssl, perl).

## What it moves

| Moved | Not moved, and why |
|---|---|
| SSH and GPG keys, cloud CLI configs (`.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`) | Apps: reinstall them, or use the Brewfile it saves |
| Shell, git, editor and terminal config (`.zshrc`, `.gitconfig`, `.config/nvim`, …) | `~/Library`: caches and app data that sync again or rebuild |
| Claude Code settings, skills and memory (`.claude`, `.claude.json`) | Keychain items: CLI tokens stored there need a fresh login |
| Every folder in your project folders (`~/proj`, `~/code`, `~/Developer`, …), including uncommitted work, stashes and local branches | `node_modules`, `.venv`, `.next`, `.terraform` and similar: reinstall per project |
| Desktop and Documents, unless iCloud already syncs them | Browser profiles: use your browser's sync |

Before it packs anything, it writes an inventory to `~/.mac-migration/`: every git repo with its remote and any unpushed or uncommitted work, your apps, VS Code extensions, global npm/pipx/uv tools and a Homebrew `Brewfile`. Repos outside the backed-up folders are listed separately, so nothing is left behind by surprise.

## Quick start

On the old Mac:

```bash
git clone https://github.com/nikolavas/mac-migrate.git
cd mac-migrate
DRY_RUN=1 ./backup.sh    # shows what goes into which archive, creates nothing
./backup.sh              # asks for a password, then packs
```

Save the password in your password manager. Without it the archives can't be opened.

The archives land in `~/mac-migration-archives`. If your disk fills up during the run, the script pauses, lists the finished archives, and waits until you have uploaded them. It then deletes them locally and continues. Copy everything in that folder to your cloud drive or an external disk: the `*.tar.gz.enc` files, `MANIFEST.txt`, `plan.txt` and `restore.sh`.

On the new Mac, put the files in one folder, close Claude Code if you use it, and run:

```bash
bash ~/Downloads/mac-migration-archives/restore.sh
```

Then follow the next steps it prints.

You can stop either script and run it again. Finished archives are skipped.

## Configuration

Copy `config.example.sh` to `config.sh` and change what you need: the output folder, archive size, which settings, personal folders and project folders to include, and which folder names to skip.

## How it works

- **Batches:** each project folder goes whole into one archive, and archives are filled up to about 8 GB of source data. This keeps single uploads manageable and lets the backup run on a nearly full disk.
- **Encryption:** each archive is a gzip'd tar stream encrypted with AES-256-CBC and a key derived from your password (PBKDF2, 200,000 iterations), using the `openssl` that ships with macOS. The password is never written to disk. `MANIFEST.txt` holds a SHA-256 checksum per archive, so the restore can detect a broken download.
- **Relative paths:** archives store paths relative to your home folder, so they unpack under any username. After unpacking, the restore replaces the old home path in shell, git, SSH, cloud CLI and Claude Code config files. It also renames Claude Code's per-project folders, which are named after the project path.
- **Nothing is overwritten silently:** if something already exists on the new Mac at a path the restore is about to fill, it is moved to `~/.mac-migration-restore/replaced-<timestamp>/` first.
- **Cloud placeholders:** Desktop and Documents are skipped when iCloud syncs them, or when they hold files that exist only in the cloud. Reading such a placeholder makes macOS download the file first, which makes a backup crawl.

## Troubleshooting

- **The backup seems stuck.** Watch the progress bar: it shows the speed and the time left. A large folder with many small files (a `.git` with years of history, for example) is slower than its size suggests.
- **"tar skipped some files".** The log in the archives folder lists them. Usually these are files you can't read, owned by another user or by root.
- **Google Drive zips my download.** Drive zips several files when you download them together from the web. Unzip first, or install Google Drive for desktop and copy the files from its folder.
- **The restore says "Close Claude Code first".** Claude Code rewrites `~/.claude.json` while it runs. Quit it, run the restore, then start it again.

## Alternatives

- [IBM Data Shift](https://github.com/IBM/mac-ibm-migration-tool) is the closest match. It's an open-source macOS app built for Macs managed with Jamf Pro. It copies files, apps and preferences directly between two Macs over Wi-Fi or Thunderbolt. You build a version customized for your organization, and both Macs must be connected at the same time. mac-migrate is narrower: it focuses on a developer's home folder, works through any cloud drive or disk, and needs no build step.
- [Mackup](https://github.com/lra/mackup) backs up application settings to a synced folder. It doesn't move projects and doesn't encrypt. Its symlink mode breaks preferences on macOS 14 and later, so use its copy mode.
- Dotfiles managers such as [chezmoi](https://www.chezmoi.io/) or [yadm](https://yadm.io/), together with a Brewfile, are the better long-term answer for reproducible config. They don't cover projects with unpushed work or one-off secrets, which is where mac-migrate helps on migration day.
- Microsoft's macOS migration script and Apple Business Manager's MDM migration move a Mac from one MDM to another on the same device. They don't copy data to a new Mac.

## Before you use it at work

Check your company's policy on copying source code and credentials to a cloud drive, even encrypted. If in doubt, use an encrypted external disk: set `OUT` in `config.sh` to a folder on that disk.

## Tests

```bash
bash tests/roundtrip.sh
```

The test builds a fake home folder in a temporary directory, backs it up, restores it under a different username, and checks about 30 things: identical files, skipped dependencies, kept git changes, rewritten paths, key permissions, wrong-password handling and re-runs. It never touches your real home folder.

## License

MIT, see [LICENSE](LICENSE).
