#!/bin/bash
# Backs up a fake home, restores it under another username and checks the result.
set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
OLD="$T/old/alice"
NEW="$T/new/alice.smith"
PASS=correct-horse
fails=0

ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg"; fi; }

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

run_backup() { HOME="$OLD" MIG_PASS="$1" MAX_BATCH_KB=4000 SKIP_BREW=1 /bin/bash "$REPO/backup.sh"; }

echo "Backup"
out=$(run_backup "$PASS" 2>&1); rc=$?
check "backup exits 0" [ $rc -eq 0 ]
check "no tar errors (sockets skipped)" [ -z "$(ls "$OLD/mac-migration-archives"/*.errors.log 2>/dev/null)" ]
check "settings archive created" [ -f "$OLD/mac-migration-archives/settings.tar.gz.enc" ]
check "projects split into several archives" [ "$(ls "$OLD/mac-migration-archives"/projects-*.tar.gz.enc | wc -l)" -ge 2 ]
check "iCloud-synced Documents skipped" grep -q "Skipping ~/Documents" <<< "$out"
check "progress bar reaches 100%" grep -q "100%" <<< "$(tr '\r' '\n' <<< "$out")"
check "repo with uncommitted work reported" grep -q "proj/app" <<< "$out"
check "case-only duplicate folder packed once" [ "$(grep -oi "code/tool" "$OLD/mac-migration-archives/plan.txt" | wc -l | tr -d " ")" = 1 ]
check "folder keeps its real name" grep -q "Code/tool" "$OLD/mac-migration-archives/plan.txt"

out=$(run_backup "$PASS" 2>&1)
check "second run skips finished archives" grep -q "already done" <<< "$out"
out=$(run_backup wrong 2>&1)
check "second run with another password refused" grep -q "isn't the password" <<< "$out"

ARCH="$T/download"
cp -R "$OLD/mac-migration-archives" "$ARCH"

echo "Restore"
out=$(HOME="$NEW" MIG_PASS=wrong FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1)
check "wrong password refused" grep -q "Wrong password" <<< "$out"
out=$(HOME="$NEW" MIG_PASS="$PASS" FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1); rc=$?
check "restore exits 0" [ $rc -eq 0 ]
check "project files identical" cmp -s "$OLD/proj/app/data.bin" "$NEW/proj/app/data.bin"
check "folder with a space restored" cmp -s "$OLD/proj/with space/data.bin" "$NEW/proj/with space/data.bin"
check "second project root restored" cmp -s "$OLD/Code/tool/data.bin" "$NEW/Code/tool/data.bin"
check "node_modules left out" [ ! -e "$NEW/proj/app/node_modules" ]
check "uncommitted git change kept" grep -q "app.txt" <<< "$(git -C "$NEW/proj/app" status --porcelain)"
check "Desktop restored" [ -f "$NEW/Desktop/notes.txt" ]
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

out=$(HOME="$NEW" MIG_PASS="$PASS" FORCE=1 /bin/bash "$ARCH/restore.sh" 2>&1)
check "second restore skips finished archives" grep -q "already restored" <<< "$out"

echo
if [ $fails -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) failed."; exit 1; fi
