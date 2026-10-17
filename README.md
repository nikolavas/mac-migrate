<p align="center"><img src="site/icon.png" width="96" alt=""></p>

<h1 align="center">Mac Migrate</h1>

<p align="center">Move your developer setup to a new Mac when Migration Assistant isn't an option.<br>
<a href="https://nikolavas.github.io/mac-migrate/">Website</a> · <a href="docs/guide.md">Guide</a> · <a href="CHANGELOG.md">Changelog</a></p>

<p align="center"><a href="https://github.com/nikolavas/mac-migrate/actions/workflows/test.yml"><img src="https://github.com/nikolavas/mac-migrate/actions/workflows/test.yml/badge.svg" alt="Tests"></a></p>

For company Macs that IT sets up from scratch. Mac Migrate packs your settings, keys and projects into encrypted archives, moves them through a cloud drive or a disk, and restores them on the new Mac, even under a new username.

<p align="center">
<picture><source media="(prefers-color-scheme: dark)" srcset="site/screenshots/destination-dark.png"><img src="site/screenshots/destination.png" width="400" alt="Choosing where the backup goes: Google Drive, iCloud Drive or a disk"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="site/screenshots/include-dark.png"><img src="site/screenshots/include.png" width="400" alt="Choosing what goes into the backup, with sizes"></picture>
</p>

## Features

- **Projects with unpushed work**, SSH and GPG keys, dotfiles, cloud CLI and Claude Code settings. `node_modules` and similar stay behind.
- **Google Drive, iCloud Drive, OneDrive, Dropbox or a disk.** For cloud drives, each archive is freed on the Mac once uploaded, so a nearly full Mac works.
- **Safe restore:** old home paths rewritten, nothing overwritten, every file checked.
- **Your apps back** through a generated Brewfile and setup script.
- **Free up space** by clearing caches that tools rebuild.
- **No admin rights, nothing to install.** A native app you build on your Mac, or plain Terminal scripts.

## Get started

On the old Mac, build the app and choose **Back up this Mac**:

```bash
git clone https://github.com/nikolavas/mac-migrate.git
cd mac-migrate && ./make-app.sh --install
```

On the new Mac, sign in to the cloud drive (or connect the disk) and restore:

```bash
curl -fsSL https://github.com/nikolavas/mac-migrate/archive/refs/tags/v2.0.0.tar.gz | tar xz
/bin/bash mac-migrate-2.0.0/restore.sh --from ~/Library/CloudStorage
```

Prefer Terminal throughout? `backup.sh --to <folder>`, `restore.sh --from <folder>` and `cleanup.sh` do everything the app does. Every option is in the [guide](docs/guide.md).

## Compared with IBM Data Shift

| | Mac Migrate | [IBM Data Shift](https://github.com/IBM/mac-ibm-migration-tool) |
|---|---|---|
| Transfer | Cloud drive or disk | Mac to Mac, over Wi-Fi or Thunderbolt |
| Both Macs on at once | No | Yes |
| Resumes after a stop | Yes | Not documented |
| Backup kept afterwards | Yes, encrypted | No |
| New username | Paths rewritten | Not documented |
| Developer extras | Unpushed work, Brewfile, skips `node_modules` | Not documented |
| Permissions | Desktop, Documents, Downloads | Full Disk Access |
| Apps and their preferences | Apps reinstalled, preferences stay | Moved |
| Speed | Upload, then download | Faster |

Pick Data Shift when IT supports it and both Macs can sit side by side. Pick Mac Migrate when they can't, or when your developer setup is what matters. Both are free. "Not documented" means IBM's README doesn't mention it; [details](docs/guide.md#compared-with-ibm-data-shift).

## Security

Archives are encrypted with AES-256 and a key derived from your password, using the `openssl` that ships with macOS. A signed manifest and a checksum per file catch tampering and broken downloads. The password never appears on a command line. Check your company's policy before you put work files in a cloud drive.

## Development

```bash
for t in tests/*.sh; do bash "$t"; done
```

CI runs the tests on macOS 14, 15 and the latest. More in the [guide](docs/guide.md#development).

## License

MIT, see [LICENSE](LICENSE).
