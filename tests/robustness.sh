#!/bin/bash
# Failure paths and the newer features: old backups, tampering, prefix usernames, locks, Stop,
# split archives, cloud folders (through a stub) and the commands the app uses.
set -o pipefail

# shellcheck source=tests/support/helpers.sh
. "$(dirname "$0")/support/helpers.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=horse-battery
mkdir -p "$T/apps"
: > "$T/config.sh"

# backup HOME [args...], restore HOME [args...]
backup() {
  local home="$1"; shift
  HOME="$home" MIG_PASS="${PW-$PASS}" SKIP_BREW=1 APPS_PATH="$T/apps" CASK_INDEX="$REPO/tests/fixtures/cask.json" \
    MIGRATE_CONFIG="${CONFIG:-$T/config.sh}" /bin/bash "$REPO/backup.sh" "$@"
}
restore() {
  local home="$1"; shift
  HOME="$home" MIG_PASS="${PW-$PASS}" FORCE=1 /bin/bash "$REPO/restore.sh" "$@" < /dev/null
}
newhome() { rm -rf "$1"; mkdir -p "$1"; echo "fresh install" > "$1/.zshrc"; }
proc_args() { ps -A -ww -o args= 2>/dev/null; }

echo "Backups made by mac-migrate 1"
F1="$REPO/tests/fixtures/format1"
N="$T/f1/bob"; newhome "$N"
out=$(restore "$N" --from "$F1" 2>&1); rc=$?
check "refused without --allow-unsigned" [ $rc -ne 0 ]
check "says why" grep -q "allow-unsigned" <<< "$out"
check_not "nothing restored" [ -e "$N/Desktop/notes.txt" ]
out=$(PW=wrong restore "$N" --from "$F1" --allow-unsigned 2>&1); rc=$?
check "wrong password: exit 10" [ $rc -eq 10 ]
out=$(PW=format1-pass restore "$N" --from "$F1" --allow-unsigned 2>&1); rc=$?
check "restores with --allow-unsigned" [ $rc -eq 0 ]
check "files from every archive" [ -f "$N/Desktop/notes.txt" ] && [ -f "$N/proj/app/app.txt" ] && [ -f "$N/Downloads/report.pdf" ]
check "path rewritten from the old home" grep -qF "$N/.local/bin" "$N/.zshrc"
check "private key is 600" [ "$(stat -f %Lp "$N/.ssh/id_ed25519")" = 600 ]

echo "Archive without a plan entry"
mkdir -p "$T/noplan"; cp "$F1"/*.enc "$F1/MANIFEST.txt" "$T/noplan/"
N="$T/np/carol"; newhome "$N"; mkdir -p "$N/Downloads"; echo "mine" > "$N/Downloads/report.pdf"
out=$(PW=format1-pass restore "$N" --from "$T/noplan" --allow-unsigned 2>&1); rc=$?
check "restores" [ $rc -eq 0 ]
check "restored file in place" grep -q report "$N/Downloads/report.pdf"
check "existing file moved aside, not overwritten" grep -rqs "^mine$" "$N/.mac-migration-restore"

echo "Old home is a prefix of the new one"
O="$T/p/nikola"; N="$T/p/nikola.vasilev"
mkdir -p "$O/proj/site" "$O/.claude/projects"
echo "export PATH=$O/.local/bin:\$PATH" > "$O/.zshrc"
echo "{\"projects\":{\"$O/proj/site\":{}}}" > "$O/.claude.json"
SLUG=$(printf '%s' "$O" | sed 's/[^A-Za-z0-9]/-/g'); NSLUG=$(printf '%s' "$N" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$O/.claude/projects/$SLUG-proj-site"; echo x > "$O/proj/site/index.html"
backup "$O" > /dev/null 2>&1
newhome "$N"
restore "$N" --from "$O/mac-migration-archives" > /dev/null 2>&1
mkdir -p "$O/Music"; echo song > "$O/Music/a.txt"
backup "$O" --add Music > /dev/null 2>&1
restore "$N" --from "$O/mac-migration-archives" > /dev/null 2>&1
check "second restore ran" [ -f "$N/Music/a.txt" ]
check "path rewritten once" grep -qx "export PATH=$N/.local/bin:\$PATH" "$N/.zshrc"
check_not "no doubled name" grep -q "vasilev.vasilev" "$N/.zshrc" "$N/.claude.json"
check "Claude folder renamed once" [ -d "$N/.claude/projects/$NSLUG-proj-site" ]
check_not "no doubled Claude folder" [ -n "$(find "$N/.claude/projects" -maxdepth 1 -name '*-vasilev-vasilev*')" ]

echo "Tampering and damage"
H="$T/t/dave"; mkdir -p "$H/proj/x"; head -c 200000 /dev/urandom > "$H/proj/x/data.bin"
backup "$H" > /dev/null 2>&1
A="$H/mac-migration-archives"
cp -R "$A" "$T/tampered"
# flip the first hex digit of the first checksum, whatever it is
/usr/bin/perl -pi -e 's/^(.)/$1 eq "0" ? "1" : "0"/e if $. == 2' "$T/tampered/MANIFEST.txt"
N="$T/t/new"; newhome "$N"
out=$(restore "$N" --from "$T/tampered" 2>&1); rc=$?
check "changed manifest refused" [ $rc -eq 1 ] && grep -q "doesn't match the password" <<< "$out"
N="$T/t/new2"; newhome "$N"
out=$(PW=nope restore "$N" --from "$A" 2>&1); rc=$?
check "wrong password: exit 10, not tampering" [ $rc -eq 10 ] && grep -q "Wrong password" <<< "$out"
out=$(restore "$N" --from "$A" --verify 2>&1); rc=$?
check "--verify passes" [ $rc -eq 0 ] && grep -q "complete and intact" <<< "$out"
out=$(restore "$N" --from "$A" --verify --deep 2>&1); rc=$?
check "--verify --deep passes" [ $rc -eq 0 ]
cp -R "$A" "$T/damaged"
printf 'X' | dd of="$T/damaged/projects-01.tar.gz.enc" bs=1 seek=5000 conv=notrunc 2>/dev/null
out=$(restore "$N" --from "$T/damaged" --verify --deep 2>&1); rc=$?
check "--verify --deep finds a damaged part" [ $rc -eq 1 ] && grep -q "damaged  projects-01" <<< "$out"
N="$T/t/new3"; newhome "$N"
out=$(restore "$N" --from "$T/damaged" 2>&1); rc=$?
check "restore refuses the damaged archive" [ $rc -ne 0 ] && grep -q "damaged or incomplete" <<< "$out"
check_not "damaged archive not unpacked" [ -e "$N/proj/x/data.bin" ]

echo "Split archives"
H="$T/s/erin"; mkdir -p "$H/proj/big"; head -c 2500000 /dev/urandom > "$H/proj/big/data.bin"
out=$(PART_MB=1 backup "$H" 2>&1); rc=$?
check "backup with 1 MB parts" [ $rc -eq 0 ]
check "archive split into numbered parts" [ -f "$H/mac-migration-archives/projects-01.tar.gz.enc.003" ]
check "every part in the manifest" [ "$(grep -c 'projects-01.tar.gz.enc.00' "$H/mac-migration-archives/MANIFEST.txt")" -ge 3 ]
N="$T/s/new"; newhome "$N"
restore "$N" --from "$H/mac-migration-archives" > /dev/null 2>&1
check "split archive restores identical" cmp -s "$H/proj/big/data.bin" "$N/proj/big/data.bin"
mkdir -p "$T/renamed"; cp "$H/mac-migration-archives"/{MANIFEST.txt,plan.txt,password-check.enc} "$T/renamed/"
for f in "$H/mac-migration-archives"/*.tar.gz.enc*; do cp "$f" "$T/renamed/$(basename "$f") (1)"; done
N="$T/s/new2"; newhome "$N"
restore "$N" --from "$T/renamed" > /dev/null 2>&1
check "parts renamed by a web download are found by hash" cmp -s "$H/proj/big/data.bin" "$N/proj/big/data.bin"

echo "Unreadable files, relative OUT, settings excludes"
H="$T/u/fay"; mkdir -p "$H/proj/app" "$H/.gradle"; echo ok > "$H/proj/app/a.txt"; echo no > "$H/proj/app/locked.txt"; chmod 000 "$H/proj/app/locked.txt"
echo "org.gradle.jvmargs=-Xmx2g" > "$H/.gradle/gradle.properties"
printf 'OUT=rel-archives\nEXCLUDE_NAMES+=(.gradle)\n' > "$T/rel.sh"
out=$(CONFIG="$T/rel.sh" backup "$H" 2>&1); rc=$?
chmod 600 "$H/proj/app/locked.txt"
check "an unreadable file doesn't stop the backup" [ $rc -eq 0 ]
check "it is reported" grep -q "tar skipped some files" <<< "$out"
check "relative OUT lands in the home folder" [ -f "$H/rel-archives/projects-01.tar.gz.enc" ]
N="$T/u/new"; newhome "$N"
restore "$N" --from "$H/rel-archives" > /dev/null 2>&1
check "the rest is restored" [ -f "$N/proj/app/a.txt" ]
check "a settings item survives an exclude of its folder" [ -f "$N/.gradle/gradle.properties" ]

echo "Runs from a folder full of files"
H="$T/w/ivy"; mkdir -p "$H/proj/a" "$T/w/cwd"; echo a > "$H/proj/a/a.txt"
for i in $(seq 1 15); do echo "$i" > "$T/w/cwd/file$i.txt"; done
(cd "$T/w/cwd" && backup "$H" > /dev/null 2>&1)
N="$T/w/new"; newhome "$N"
(cd "$T/w/cwd" && restore "$N" --from "$H/mac-migration-archives" > /dev/null 2>&1)
check "no file in the current folder is touched" [ "$(find "$T/w/cwd" -type f | wc -l | tr -d " ")" = 15 ]
check_not "the current folder never lands in PATH" grep -q "PATH=\.:" "$N"/.mac-migration/logs/*.log

echo "Lock, password on stdin, Stop and resume"
H="$T/l/gus"; mkdir -p "$H/proj/a" "$H/.mac-migration/lock"
head -c 60000000 /dev/urandom > "$H/proj/a/big.bin"
sleep 60 & SLEEPER=$!
echo $SLEEPER > "$H/.mac-migration/lock/pid"; ps -o lstart= -p $SLEEPER > "$H/.mac-migration/lock/start"
out=$(backup "$H" 2>&1); rc=$?
check "a live lock stops a second run (exit 13)" [ $rc -eq 13 ] && grep -q "Another mac-migrate run" <<< "$out"
kill $SLEEPER 2>/dev/null; wait $SLEEPER 2>/dev/null
mkdir -p "$T/l/run"
printf '%s\n' "$PASS" | HOME="$H" MIG_RUN="$T/l/run" SKIP_BREW=1 APPS_PATH="$T/apps" CASK_INDEX="$REPO/tests/fixtures/cask.json" \
  MIGRATE_CONFIG="$T/config.sh" MIG_NONINTERACTIVE=1 /usr/bin/perl -e 'setpgrp(0,0); exec @ARGV' /bin/bash "$REPO/backup.sh" --password-stdin &
BG=$!
seen=0; leaked=0
for _ in $(seq 1 40); do
  sleep 0.25
  # the bracket keeps this grep from matching its own command line
  proc_args | grep -q "${PASS%?}[${PASS: -1}]" && leaked=1
  if awk -F'\t' '$1 == "pack" && $2 ~ /^projects/' "$T/l/run/status" 2>/dev/null | grep -q .; then seen=1; break; fi
done
check "a stale lock doesn't block" [ $seen = 1 ]
check "password not in any command line" [ $leaked = 0 ]
kill -TERM -- -$BG 2>/dev/null; wait $BG 2>/dev/null
check "Stop leaves no partial files" [ -z "$(ls "$H/mac-migration-archives"/*.part 2>/dev/null)" ]
check "Stop releases the lock" [ ! -d "$H/.mac-migration/lock" ]
check "Stop is recorded for the app" grep -q "^result	143" "$T/l/run/events.tsv"
out=$(backup "$H" 2>&1); rc=$?
check "the next run finishes" [ $rc -eq 0 ] && grep -q "settings: already done" <<< "$out"

echo "Cloud folder (stub)"
H="$T/c/hana"; mkdir -p "$H/proj/a" "$H/proj/b"
head -c 300000 /dev/urandom > "$H/proj/a/data.bin"; head -c 300000 /dev/urandom > "$H/proj/b/data.bin"
DRIVE="$H/Library/CloudStorage/GoogleDrive-hana@example.com/My Drive"; mkdir -p "$DRIVE"
cat > "$T/cloudstub" <<'EOF'
#!/bin/bash
cmd=$1; shift
for p in "$@"; do
  case "$cmd" in
    status)
      loc=1; grep -qxF "$p" "$STUB_DIR/evicted" 2>/dev/null && loc=0
      if [ -n "$STUB_STALL" ]; then printf '%s\t1\t0\t0\t%s\t-\n' "$p" "$loc"; else printf '%s\t1\t1\t0\t%s\t-\n' "$p" "$loc"; fi ;;
    evict) echo "$p" >> "$STUB_DIR/evicted"; printf '%s\tok\n' "$p" ;;
    download) printf '%s\tok\n' "$p" ;;
  esac
done
EOF
chmod +x "$T/cloudstub"; export STUB_DIR="$T/c"; : > "$T/c/evicted"
places=$(HOME="$H" /bin/bash "$REPO/backup.sh" --list-places)
check "--list-places finds Google Drive" grep -q "^gdrive:hana@example.com	cloud	Google Drive (hana@example.com)	$DRIVE	" <<< "$places"
sources=$(backup "$H" --list-sources)
check "--list-sources measures project folders" grep -q "^projects	proj	[0-9]*	1	" <<< "$sources"
out=$(MAX_BATCH_KB=300 MIG_CLOUD_HELPER="$T/cloudstub" backup "$H" --to "$DRIVE" 2>&1); rc=$?
B=$(find "$DRIVE" -maxdepth 1 -name 'mac-migration-*' | head -1)
check "cloud backup exits 0" [ $rc -eq 0 ]
check "archives moved into the Drive folder" [ -f "$B/projects-02.tar.gz.enc" ] && [ -f "$B/MANIFEST.txt" ] && [ -f "$B/restore.sh" ]
check "nothing left in local staging" [ -z "$(ls "$H/.mac-migration-staging"/*/*.tar.gz.enc 2>/dev/null)" ]
check "waits until everything is uploaded" grep -q "Everything is uploaded" <<< "$out"
status=$(backup "$H" --status --to "$DRIVE")
check "--status finds the backup" grep -q "^complete	yes" <<< "$status" && grep -q "^archive	projects-02	done" <<< "$status"
N="$T/c/new"; newhome "$N"
restore "$N" --from "$DRIVE" > /dev/null 2>&1
check "restore finds the backup below the Drive folder" cmp -s "$H/proj/b/data.bin" "$N/proj/b/data.bin"
printf 'FREE_MARGIN_GB=999999\n' > "$T/huge.sh"
mkdir -p "$H/Library/CloudStorage/Dropbox"
out=$(CONFIG="$T/huge.sh" MIG_CLOUD_HELPER="$T/cloudstub" backup "$H" --to "$H/Library/CloudStorage/Dropbox" 2>&1); rc=$?
check "no room: archives skipped, exit 14" [ $rc -eq 14 ] && grep -q "didn.t fit" <<< "$out"
mkdir -p "$H/Library/CloudStorage/OneDrive-Acme"
out=$(STUB_STALL=1 MIG_STALL_SECONDS=2 MIG_CLOUD_HELPER="$T/cloudstub" backup "$H" --to "$H/Library/CloudStorage/OneDrive-Acme" 2>&1); rc=$?
check "upload that never moves: exit 15" [ $rc -eq 15 ] && grep -q "Nothing has uploaded to OneDrive" <<< "$out"

summary
