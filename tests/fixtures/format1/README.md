# Format 1 fixture

Archives made by mac-migrate before format 2 (commit 0541ed4), from a fake home folder:

- `settings`: `.zshrc`, `.ssh`, `.claude`, `.claude.json` and `.mac-migration` (with `source-home.txt`)
- `personal`: `Desktop/notes.txt`
- `projects-01`: `proj/app/app.txt`
- `extra-downloads`: `Downloads/report.pdf`, added later with `--add Downloads`

Password: `format1-pass`. The old home path is in `.mac-migration/source-home.txt` inside the settings archive, and `.zshrc`, `.ssh/config`, `.claude.json` and the skill refer to it.

`tests/roundtrip.sh` restores this folder with the current `restore.sh`, so older backups keep working.
