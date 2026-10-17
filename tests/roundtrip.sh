#!/bin/bash
# Backs up a fake home, restores it under another username and checks the result.
set -o pipefail

# shellcheck source=tests/support/helpers.sh
. "$(dirname "$0")/support/helpers.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
OLD="$T/old/alice"
NEW="$T/new/alice.smith"
PASS=correct-horse

echo "Building a fake home in $T"
mkdir -p "$OLD"/{proj/app/node_modules/dep,"proj/with space",Code/tool,.ssh,.claude/skills/demo,Documents,Desktop} "$NEW"
head -c 3000000 /dev/urandom > "$OLD/proj/app/data.bin"
head -c 3000000 /dev/urandom > "$OLD/proj/with space/data.bin"
head -c 3000000 /dev/urandom > "$OLD/Code/tool/data.bin"
echo "dependency" > "$OLD/proj/app/node_modules/dep/index.js"
(
  cd "$OLD/proj/app" && git init -q && printf 'node_modules\n' > .gitignore && echo v1 > app.txt &&
  git add . && git -c user.email=t@example.com -c user.name=t commit -qm init && echo v2 >> app.txt
)
echo "PRIVATE KEY" > "$OLD/.ssh/id_ed25519"; chmod 644 "$OLD/.ssh/id_ed25519"
printf 'Host example\n  IdentityFile %s/.ssh/id_ed25519\n' "$OLD" > "$OLD/.ssh/config"
echo "export PATH=$OLD/.local/bin:\$PATH" > "$OLD/.zshrc"
echo "{\"projects\":{\"$OLD/proj/app\":{}}}" > "$OLD/.claude.json"
echo "Read $OLD/proj/app first." > "$OLD/.claude/skills/demo/SKILL.md"
OLD_SLUG=$(printf '%s' "$OLD" | sed 's/[^A-Za-z0-9]/-/g')
NEW_SLUG=$(printf '%s' "$NEW" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$OLD/.claude/projects/$OLD_SLUG/memory" "$OLD/.claude/projects/$OLD_SLUG-proj-app"
echo "Projects live in $OLD/proj." > "$OLD/.claude/projects/$OLD_SLUG/memory/MEMORY.md"
echo "notes" > "$OLD/Desktop/notes.txt"
echo "icloud" > "$OLD/Documents/synced.txt"
xattr -w com.apple.icloud.desktop 1 "$OLD/Documents"
# relative bind keeps the socket path under the 104-character limit
(cd "$OLD/.ssh" && /usr/bin/python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("agent.sock")' 2>/dev/null)
echo "fresh install" > "$NEW/.zshrc"
mkdir -p "$OLD/Downloads" && echo "report" > "$OLD/Downloads/report.pdf"

mkapp() {
  mkdir -p "$T/apps/$1.app/Contents"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string>%s</dict></plist>\n' \
    "$2" "${3:+<key>$3</key><true/>}" > "$T/apps/$1.app/Contents/Info.plist"
}
mkapp "Visual Studio Code" com.microsoft.VSCode
mkapp "Codex" com.openai.codex
mkapp "Google Drive" com.google.drivefs
mkapp "GIMP-2.10" org.gimp.gimp-2.10
mkapp "JetBrains Toolbox" com.jetbrains.toolbox
mkapp "Rider" com.jetbrains.rider
mkapp "Slack" com.tinyspeck.slackmacgap
mkapp "Mystery Tool" com.example.mystery
mkapp "Helper" com.example.helper LSBackgroundOnly
mkapp "Safari" com.apple.Safari
mkapp "Store App" com.example.store && mkdir -p "$T/apps/Store App.app/Contents/_MASReceipt"
echo 'SETUP_SKIP_APPS=("Slack")' > "$T/config.sh"

run_backup() {
  local pass="$1"; shift
  HOME="$OLD" MIG_PASS="$pass" MIG_RUN="$T/run" MAX_BATCH_KB=4000 SKIP_BREW=1 APPS_PATH="$T/apps" \
    CASK_INDEX="$REPO/tests/fixtures/cask.json" MIGRATE_CONFIG="$T/config.sh" /bin/bash "$REPO/backup.sh" "$@"
}

echo "Backup"
mkdir -p "$T/run"
out=$(run_backup "$PASS" 2>&1); rc=$?
check "backup exits 0" [ $rc -eq 0 ]
check "no tar errors (sockets skipped)" [ -z "$(ls "$OLD/mac-migration-archives"/*.errors.log 2>/dev/null)" ]
check "settings archive created" [ -f "$OLD/mac-migration-archives/settings.tar.gz.enc" ]
check "projects split into several archives" [ "$(find "$OLD/mac-migration-archives" -name 'projects-*.tar.gz.enc' | wc -l)" -ge 2 ]
check "iCloud-synced Documents skipped" grep -q "Skipping ~/Documents" <<< "$out"
# shellcheck disable=SC2016  # awk program
check "status shows the finished total" awk -F'\t' '$1 == "done" && $3 == $4 && $3 > 0 {f = 1} END {exit !f}' "$T/run/status"
check "result recorded for the app" grep -qx "result	0	" "$T/run/events.tsv"
check "manifest is format 2 and complete" grep -q "^# mac-migrate format 2 .*complete=yes" "$OLD/mac-migration-archives/MANIFEST.txt"
check "repo with uncommitted work reported" grep -q "proj/app" <<< "$out"
check "case-only duplicate folder packed once" [ "$(grep -oi "code/tool" "$OLD/mac-migration-archives/plan.txt" | wc -l | tr -d " ")" = 1 ]
check "folder keeps its real name" grep -q "Code/tool" "$OLD/mac-migration-archives/plan.txt"

echo "Software package"
SETUP="$OLD/.mac-migration/new-mac-setup"
check "Brewfile has an app matched by name" grep -qx 'cask "visual-studio-code"' "$SETUP/Brewfile"
check "Brewfile has an app matched by bundle id" grep -qx 'cask "google-drive"' "$SETUP/Brewfile"
check "Brewfile has an app matched without its version" grep -qx 'cask "gimp"' "$SETUP/Brewfile"
check "discontinued cask replaced" grep -qx 'cask "chatgpt"' "$SETUP/Brewfile"
check_not "discontinued cask left out" grep -q 'codex-app"' "$SETUP/Brewfile"
check_not "Toolbox-managed IDE left out" grep -q 'cask "rider"' "$SETUP/Brewfile"
check_not "company app left out" grep -q 'cask "slack' "$SETUP/Brewfile"
check "company app listed for self-service" grep -q "^- Slack$" "$SETUP/README.md"
check "IDE listed for Toolbox" grep -q "^- Rider$" "$SETUP/README.md"
check "unknown app listed to install by hand" grep -q "^- Mystery Tool$" "$SETUP/README.md"
check "App Store app without an id listed" grep -q "^- Store App (App Store)$" "$SETUP/README.md"
check_not "helper and system apps ignored" grep -qE "Helper|Safari" "$SETUP/README.md" "$SETUP/Brewfile"
check "setup.sh is valid bash" /bin/bash -n "$SETUP/setup.sh"
check "package copied next to the archives" [ -f "$OLD/mac-migration-archives/new-mac-setup/setup.sh" ]

out=$(run_backup "$PASS" 2>&1)
check "second run skips finished archives" grep -q "already done" <<< "$out"
out=$(run_backup wrong 2>&1)
check "second run with another password refused" grep -q "isn't the password" <<< "$out"

out=$(run_backup "$PASS" --add Downloads proj/app 2>&1)
check "--add packs a folder after the backup finished" [ -f "$OLD/mac-migration-archives/extra-downloads.tar.gz.enc" ]
check "--add skips a folder already in the backup" grep -q "proj/app is already in the backup" <<< "$out"

mkdir -p "$NEW/Downloads"
echo "downloaded on the new Mac" > "$NEW/Downloads/new-mac-file.txt"
echo "new Mac version" > "$NEW/Downloads/report.pdf"
ARCH="$NEW/Downloads/mac-migration-archives"
cp -R "$OLD/mac-migration-archives" "$ARCH"

# a process named claude, like a running Claude Code
mkdir -p "$T/bin" && printf '#include <unistd.h>\nint main(void){sleep(120);return 0;}\n' > "$T/bin/claude.c"
cc -o "$T/bin/claude" "$T/bin/claude.c" 2>/dev/null && { "$T/bin/claude" & CLAUDE_PID=$!; disown; }
trap 'kill $CLAUDE_PID 2>/dev/null; rm -rf "$T"' EXIT

echo "Restore"
out=$(HOME="$NEW" MIG_PASS=wrong FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1)
check "wrong password refused" grep -q "Wrong password" <<< "$out"
out=$(HOME="$NEW" MIG_PASS="$PASS" /bin/bash "$ARCH/restore.sh" 2>&1)
check "refuses while Claude Code runs and its files are pending" grep -q "Close Claude Code first" <<< "$out"
out=$(HOME="$NEW" MIG_PASS="$PASS" FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1); rc=$?
check "restore exits 0" [ $rc -eq 0 ]
check "project files identical" cmp -s "$OLD/proj/app/data.bin" "$NEW/proj/app/data.bin"
check "folder with a space restored" cmp -s "$OLD/proj/with space/data.bin" "$NEW/proj/with space/data.bin"
check "second project root restored" cmp -s "$OLD/Code/tool/data.bin" "$NEW/Code/tool/data.bin"
check "node_modules left out" [ ! -e "$NEW/proj/app/node_modules" ]
check "uncommitted git change kept" grep -q "app.txt" <<< "$(git -C "$NEW/proj/app" status --porcelain)"
check "Desktop restored" [ -f "$NEW/Desktop/notes.txt" ]
check "folder added later restored" [ -f "$NEW/Downloads/report.pdf" ]
check "software package restored" [ -f "$NEW/.mac-migration/new-mac-setup/setup.sh" ]
check "Documents not restored" [ ! -e "$NEW/Documents/synced.txt" ]
check "existing .zshrc moved aside" grep -rqs "fresh install" "$NEW/.mac-migration-restore"
check ".ssh is 700" [ "$(stat -f %Lp "$NEW/.ssh")" = 700 ]
check "private key is 600" [ "$(stat -f %Lp "$NEW/.ssh/id_ed25519")" = 600 ]
check "path rewritten in .zshrc" grep -qF "$NEW/.local/bin" "$NEW/.zshrc"
check "path rewritten in .ssh/config" grep -qF "$NEW/.ssh/id_ed25519" "$NEW/.ssh/config"
check "path rewritten in .claude.json" grep -qF "$NEW/proj/app" "$NEW/.claude.json"
check "path rewritten in a Claude skill" grep -qF "$NEW/proj/app" "$NEW/.claude/skills/demo/SKILL.md"
check "Claude memory folder renamed" [ -f "$NEW/.claude/projects/$NEW_SLUG/memory/MEMORY.md" ]
check "Claude project folder renamed" [ -d "$NEW/.claude/projects/$NEW_SLUG-proj-app" ]
check "path rewritten in Claude memory" grep -qF "$NEW/proj" "$NEW/.claude/projects/$NEW_SLUG/memory/MEMORY.md"
check "old path gone from configs" [ -z "$(grep -rlF "$OLD" "$NEW/.zshrc" "$NEW/.ssh/config" "$NEW/.claude.json" "$NEW/.claude/skills")" ]

check "Downloads merged, not replaced" [ -f "$NEW/Downloads/new-mac-file.txt" ]
check "archives folder inside Downloads untouched" [ -f "$ARCH/MANIFEST.txt" ]
check "restored file wins inside a merged folder" grep -q "report" "$NEW/Downloads/report.pdf"
check "replaced file kept aside" grep -rqs "new Mac version" "$NEW/.mac-migration-restore"

out=$(HOME="$NEW" MIG_PASS="$PASS" FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1)
check "second restore skips finished archives" grep -q "already restored" <<< "$out"

mkdir -p "$OLD/Music" "$OLD/Pictures/Photos Library.photoslibrary/database"
echo "song" > "$OLD/Music/song.txt"
echo "scan" > "$OLD/Pictures/scan.pdf"
echo "old library" > "$OLD/Pictures/Photos Library.photoslibrary/database/old.db"
mkdir -p "$NEW/Pictures/Photos Library.photoslibrary/database"
echo "new library" > "$NEW/Pictures/Photos Library.photoslibrary/database/new.db"
echo "new Mac picture" > "$NEW/Pictures/keep.jpg"
run_backup "$PASS" --add Music Pictures >/dev/null 2>&1
cp "$OLD/mac-migration-archives"/extra-*.tar.gz.enc "$OLD/mac-migration-archives/MANIFEST.txt" "$OLD/mac-migration-archives/plan.txt" "$ARCH/"
out=$(HOME="$NEW" MIG_PASS="$PASS" /bin/bash "$ARCH/restore.sh" 2>&1); rc=$?
check "restores a later archive while Claude Code runs" [ $rc -eq 0 -a -f "$NEW/Music/song.txt" ]
check "Pictures merged: new Mac file kept" [ -f "$NEW/Pictures/keep.jpg" -a -f "$NEW/Pictures/scan.pdf" ]
check "Photos library restored whole" [ -f "$NEW/Pictures/Photos Library.photoslibrary/database/old.db" ]
check_not "Photos library not mixed with the new one" [ -e "$NEW/Pictures/Photos Library.photoslibrary/database/new.db" ]
check "new Mac's Photos library kept aside" [ -n "$(find "$NEW/.mac-migration-restore" -path '*Photos Library.photoslibrary/database/new.db' 2>/dev/null)" ]
out=$(HOME="$NEW" /bin/bash "$ARCH/restore.sh" < /dev/null 2>&1); rc=$?
check "nothing new: exits cleanly" [ $rc -eq 0 ]
check "nothing new: no password asked" grep -q "Nothing new to restore" <<< "$out"

summary
