#!/bin/bash
# Usage: /bin/bash restore.sh --from FOLDER       restore the backup in FOLDER (a cloud folder, a disk, Downloads, ...)
#        /bin/bash restore.sh --plan --from FOLDER see what would be restored and what would be moved aside
#        /bin/bash restore.sh --verify [--deep]    check the backup without restoring it
# Without --from it looks next to itself. Options: --password-stdin, and --allow-unsigned to
# restore a backup made by mac-migrate 1, whose files can't be checked for changes.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

RUN_DIR="$HOME/.mac-migration-restore"
DONE="$RUN_DIR/restored.txt"
REPLACED="$RUN_DIR/replaced-$(date +%Y%m%d-%H%M%S)"
MARGIN_KB=$((1024 * 1024))
shopt -s nullglob

ACTION=restore; SRC="${SRC:-}"; DEEP=0; PASSWORD_STDIN=0; ALLOW_UNSIGNED="${MIG_ALLOW_UNSIGNED:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --from) [ -n "$2" ] || { echo "--from needs a folder"; exit 1; }; SRC="$2"; shift 2 ;;
    --plan) ACTION=plan; shift ;;
    --verify) ACTION=verify; shift ;;
    --deep) DEEP=1; shift ;;
    --password-stdin) PASSWORD_STDIN=1; shift ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --version) echo "mac-migrate $MM_VERSION"; exit 0 ;;
    -h | --help) sed -n "2,7p" "$0" | sed "s/^# \{0,1\}//"; exit 0 ;;
    *) echo "Unknown option: $1 (see restore.sh --help)"; exit 1 ;;
  esac
done
mm_env

# --- Finding the backup -----------------------------------------------------

# The folder with MANIFEST.txt: the one given, or the only backup below it
find_backup() {
  local start="$1" found
  [ -f "$start/MANIFEST.txt" ] && { echo "$start"; return; }
  found=$(find "$start" -maxdepth 3 -name MANIFEST.txt -not -path '*/mac-migrate/*' 2>/dev/null | sed 's#/MANIFEST.txt$##')
  [ -n "$found" ] || return 1
  if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "There are several backups in $start. Choose one with --from:" >&2
    printf '%s\n' "$found" | sed 's/^/  /' >&2
    return 2
  fi
  echo "$found"
}

[ -n "$SRC" ] || SRC="$SCRIPT_DIR"
[ -d "$SRC" ] || die 1 "$SRC doesn't exist."
SRC=$(cd "$SRC" && pwd)
SRC=$(find_backup "$SRC") || die 1 "No backup found in $SRC. Point --from at the folder with MANIFEST.txt."
FORMAT=$(manifest_format "$SRC/MANIFEST.txt")
mkdir -p "$RUN_DIR"

# archives.tsv: name<TAB>kb<TAB>item...   parts.tsv: archive<TAB>file<TAB>bytes<TAB>sha256 (sha256 may be -)
WORK=$(mktemp -d) || die 1 "Can't create a temporary folder."
if [ "$FORMAT" = 2 ]; then
  cp "$SRC/plan.txt" "$WORK/archives.tsv" 2>/dev/null || die 1 "plan.txt is missing from $SRC. Copy the whole backup folder."
  grep -vE '^#|  (plan\.txt|password-check\.enc)$' "$SRC/MANIFEST.txt" |
    awk '{f = $3; a = f; sub(/\.tar\.gz\.enc(\.[0-9]+)?$/, "", a); printf "%s\t%s\t%s\t%s\n", a, f, $2, $1}' > "$WORK/parts.tsv"
else
  # Format 1: every *.tar.gz.enc in the folder is an archive; plan.txt and MANIFEST.txt may be missing
  : > "$WORK/archives.tsv"; : > "$WORK/parts.tsv"
  for f in "$SRC"/*.tar.gz.enc; do
    name=$(basename "$f" .tar.gz.enc)
    line=$(awk -F'\t' -v n="$name" '$1 == n' "$SRC/plan.txt" 2>/dev/null | head -1)
    if [ -n "$line" ]; then echo "$line" >> "$WORK/archives.tsv"; else printf '%s\t%s\n' "$name" "$(($(file_size "$f") / 1024))" >> "$WORK/archives.tsv"; fi
    sha=$(awk -v n="$(basename "$f")" '$2 == n {print $1}' "$SRC/MANIFEST.txt" 2>/dev/null | tail -1)
    printf '%s\t%s\t%s\t%s\n' "$name" "$(basename "$f")" "$(file_size "$f")" "${sha:--}" >> "$WORK/parts.tsv"
  done
fi
trap 'rm -rf "$WORK"' EXIT

# Items come from plan.txt and are deleted on a retry, so they must stay inside the home folder
awk -F'\t' '{for (i = 3; i <= NF; i++) if ($i ~ /^\// || $i ~ /(^|\/)\.\.(\/|$)/ || $i == "") exit 1}' "$WORK/archives.tsv" ||
  die 1 "plan.txt in $SRC has an entry outside the home folder. Nothing was restored."

items_of() { awk -F'\t' -v n="$1" '$1 == n {for (i = 3; i <= NF; i++) print $i}' "$WORK/archives.tsv"; }
parts_rows() { awk -F'\t' -v n="$1" '$1 == n' "$WORK/parts.tsv"; }
restored() { grep -qx "$1.tar.gz.enc" "$DONE" 2>/dev/null; }

# A part where the manifest says, or a renamed copy anywhere below the folder
# (the Google Drive website renames duplicates to "x (1)"): same size, then same hash
locate_part() {  # file bytes sha256
  local f
  [ -f "$SRC/$1" ] && { echo "$SRC/$1"; return 0; }
  [ "$3" = - ] && return 1
  while IFS= read -r f; do
    [ "$(sha256 "$f")" = "$3" ] && { echo "$f"; return 0; }
  done < <(find "$SRC" -type f -size "$2"c 2>/dev/null)
  return 1
}

# Pending archives, and which of them have every part here
pending=(); missing=()
while IFS=$'\t' read -r name _; do
  restored "$name" && continue
  ok=1
  while IFS=$'\t' read -r _ file bytes sha; do locate_part "$file" "$bytes" "$sha" > /dev/null || ok=0; done < <(parts_rows "$name")
  [ -n "$(parts_rows "$name")" ] || ok=0
  if [ $ok = 1 ]; then pending+=("$name"); else missing+=("$name"); fi
done < "$WORK/archives.tsv"

# --- Checks -----------------------------------------------------------------

check_signature() {
  if [ "$FORMAT" = 2 ]; then
    pwcheck_ok "$SRC/password-check.enc" || die "$E_PASSWORD" "Wrong password."
    manifest_verify "$SRC/MANIFEST.txt" ||
      die 1 "MANIFEST.txt doesn't match the password: it was changed after the backup, or belongs to another backup. Nothing was restored."
    local f want
    for f in plan.txt password-check.enc; do
      want=$(awk -v n="$f" '$3 == n {print $1}' "$SRC/MANIFEST.txt")
      [ "$(sha256 "$SRC/$f")" = "$want" ] || die 1 "$f was changed after the backup. Nothing was restored."
    done
  else
    # decrypted gzip starts with 1f 8b
    local first magic
    first=$(locate_part "$(awk -F'\t' 'NR == 1 {print $2}' "$WORK/parts.tsv")" 0 -)
    magic=$(decrypt -in "$first" 2>/dev/null | head -c 2 | od -An -tx1 | tr -d ' \n')
    [ "$magic" = 1f8b ] || die "$E_PASSWORD" "Wrong password."
  fi
}

allow_unsigned() {
  [ "$FORMAT" = 2 ] && return 0
  [ "$ALLOW_UNSIGNED" = 1 ] && { warn "This backup was made by mac-migrate 1: its files can't be checked for changes."; return 0; }
  echo "This backup was made by mac-migrate 1. Its files can't be checked for changes made after the backup."
  if [ "$MIG_NONINTERACTIVE" != 1 ] && [ -t 0 ]; then
    local ans
    read -r -p "Restore it anyway? [y/N] " ans
    case "$ans" in y | Y | yes) return 0 ;; esac
  fi
  die 1 "Run again with --allow-unsigned to restore it anyway."
}

# Claude Code rewrites ~/.claude.json while it runs
touches_claude() {
  local n
  for n in "${pending[@]}"; do items_of "$n" | grep -qE '^\.claude(\.json)?(/|$)' && return 0; done
  return 1
}

# Folders are merged into the home folder: top-level folders like Downloads, and ~/.mac-migration,
# which holds this run's lock and log. Settings and project folders are swapped whole.
merge_item() {
  case "$1" in
    "$STATE_DIR_NAME") return 0 ;;
    */* | .*) return 1 ;;
  esac
  [ -d "$HOME/$1" ] && [ ! -L "$HOME/$1" ]
}

if [ "$ACTION" = plan ]; then
  printf 'source\t%s\nformat\t%s\n' "$SRC" "$FORMAT"
  [ "$FORMAT" = 2 ] && printf 'complete\t%s\n' "$(manifest_field "$SRC/MANIFEST.txt" complete)"
  while IFS=$'\t' read -r name kb _; do
    s=pending; restored "$name" && s="done"
    for m in "${missing[@]}"; do [ "$m" = "$name" ] && s=missing; done
    printf 'archive\t%s\t%s\t%s\n' "$name" "$s" "$kb"
    [ "$s" = pending ] || continue
    while IFS= read -r item; do
      [ -e "$HOME/$item" ] || [ -L "$HOME/$item" ] || continue
      if merge_item "$item"; then printf 'merge\t%s\n' "$item"; else printf 'aside\t%s\n' "$item"; fi
    done < <(items_of "$name")
  done < "$WORK/archives.tsv"
  printf 'free_kb\t%s\n' "$(free_kb "$HOME")"
  pgrep -xq claude && touches_claude && printf 'claude\trunning\n'
  exit 0
fi

if [ "$ACTION" = verify ]; then
  allow_unsigned
  read_password existing
  check_signature
  bad=0
  while IFS=$'\t' read -r name _; do
    while IFS=$'\t' read -r _ file bytes sha; do
      p=$(locate_part "$file" "$bytes" "$sha") || { echo "missing  $file"; bad=1; continue; }
      if [ "$(file_size "$p")" != "$bytes" ] && [ "$FORMAT" = 2 ]; then echo "wrong size  $file"; bad=1; continue; fi
      if [ "$DEEP" = 1 ] && [ "$sha" != - ] && [ "$(sha256 "$p")" != "$sha" ]; then echo "damaged  $file"; bad=1; fi
    done < <(parts_rows "$name")
    if [ "$DEEP" = 1 ] && [ $bad = 0 ]; then
      (while IFS=$'\t' read -r _ file bytes sha; do cat "$(locate_part "$file" "$bytes" "$sha")"; done < <(parts_rows "$name")) |
        decrypt | tar -tzf - > /dev/null 2>&1 || { echo "unreadable  $name"; bad=1; }
    fi
  done < "$WORK/archives.tsv"
  [ "$FORMAT" = 2 ] && [ "$(manifest_field "$SRC/MANIFEST.txt" complete)" != yes ] && echo "The backup wasn't finished: run the backup again on the old Mac."
  [ $bad = 0 ] && { echo "The backup in $SRC is complete and intact."; exit 0; }
  exit 1
fi

if [ ${#pending[@]} -eq 0 ]; then
  log "Nothing new to restore: all archives in $SRC are already restored."
  [ ${#missing[@]} -gt 0 ] && echo "    Not in the folder (yet): ${missing[*]}"
  exit 0
fi

claude_running=0
[ -z "$FORCE" ] && pgrep -xq claude && claude_running=1
if [ "$claude_running" = 1 ] && touches_claude; then
  die 1 "Close Claude Code first: this restore brings back ~/.claude and ~/.claude.json, which Claude Code rewrites while it runs."
fi

allow_unsigned
lock_acquire restore
trap 'rc=$?; rm -rf "$WORK" "$RUN_DIR"/staging-*; finish $rc' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start_log restore
stay_awake restore
read_password existing
check_signature

# --- Unpacking --------------------------------------------------------------

# Files and bundles (Photos library, Keynote file, app) replace the existing copy, which goes to $REPLACED.
# A file that is already the restored one (same size and date, from an interrupted run) is just replaced.
merge_into_home() {
  /usr/bin/perl -MFile::Find -MFile::Path=make_path -MFile::Basename -e '
    my ($stage, $home, $aside) = @ARGV;
    my ($n, $err) = (0, 0);
    my $park = sub { my $rel = shift; my $b = "$aside/$rel"; make_path(dirname($b)); rename("$home/$rel", $b) or $err++; $n++ };
    my $same = sub { my ($a, $b) = @_; my @x = lstat $a; my @y = lstat $b; -f _ && @x && @y && $x[7] == $y[7] && $x[9] == $y[9] };
    find({ no_chdir => 1, wanted => sub {
      my $rel = substr($File::Find::name, length($stage) + 1);
      return if $rel eq "";
      my $dst = "$home/$rel";
      if (-d $_ && !-l $_ && $rel =~ /\.(photoslibrary|photolibrary|imovielibrary|musiclibrary|tvlibrary|fcpbundle|logicx|band|key|numbers|pages|app|bundle|framework|plugin|rtfd|xcodeproj|xcworkspace|xcarchive|sparsebundle|scriv|dtbase2)$/i) {
        $park->($rel) if -e $dst || -l $dst;
        make_path(dirname($dst));
        rename($_, $dst) or do { warn "    could not place ~/$rel: $!\n"; $err++ };
        $File::Find::prune = 1;
        return;
      }
      if (-d $_ && !-l $_) {
        $park->($rel) if -l $dst || (-e $dst && !-d $dst);
        unless (-d $dst) { make_path($dst); chmod((stat $_)[2] & 07777, $dst) }
        return;
      }
      if (-e $dst || -l $dst) { if ($same->($_, $dst)) { unlink $dst } else { $park->($rel) } }
      rename($_, $dst) or do { warn "    could not place ~/$rel: $!\n"; $err++ };
    } }, $stage);
    print "    moved $n existing file(s) aside\n" if $n;
    exit($err ? 1 : 0);' "$1" "$HOME" "$REPLACED"
}

cloud_source=0
in_cloud_folder "$SRC" && cloud_source=1

# Start downloading an archive from the cloud while the previous one unpacks
prefetch() {
  [ "$cloud_source" = 1 ] || return 0
  local files=() file bytes sha
  while IFS=$'\t' read -r _ file bytes sha; do files+=("$(locate_part "$file" "$bytes" "$sha")"); done < <(parts_rows "$1")
  [ ${#files[@]} -gt 0 ] && cloud download "${files[@]}" > /dev/null 2>&1 &
}

total_kb=0
for n in "${pending[@]}"; do total_kb=$((total_kb + $(awk -F'\t' -v n="$n" '$1 == n {print $2}' "$WORK/archives.tsv"))); done
export M_TOTAL="$total_kb" M_BEFORE=0 M_PHASE=unpack M_STATUS="" M_COUNT=""
[ -n "$MIG_RUN" ] && M_STATUS="$MIG_RUN/status"

failed=0; no_space=()
log "Unpacking into $HOME"
prefetch "${pending[0]}"
for i in "${!pending[@]}"; do
  name="${pending[$i]}"
  kb=$(awk -F'\t' -v n="$name" '$1 == n {print $2}' "$WORK/archives.tsv")
  [ $((i + 1)) -lt ${#pending[@]} ] && prefetch "${pending[$((i + 1))]}"
  echo "    $name"

  files=(); bytes_total=0; bad=0
  while IFS=$'\t' read -r _ file bytes sha; do
    p=$(locate_part "$file" "$bytes" "$sha")
    [ "$cloud_source" = 1 ] && status download "$name" 0 0 0 -1 "Downloading $file"
    if [ "$sha" != - ] && [ "$(sha256 "$p")" != "$sha" ]; then
      echo "    $file: damaged or incomplete download. Download it again."; bad=1
    fi
    files+=("$p"); bytes_total=$((bytes_total + bytes))
  done < <(parts_rows "$name")
  if [ $bad = 1 ]; then failed=1; M_BEFORE=$((M_BEFORE + kb)); continue; fi

  if [ "$(free_kb "$HOME")" -lt $((kb + MARGIN_KB)) ]; then
    warn "Not enough space for $name: it needs $(gb $((kb + MARGIN_KB))), $(gb "$(free_kb "$HOME")") is free."
    no_space+=("$name"); failed=1; M_BEFORE=$((M_BEFORE + kb)); continue
  fi

  # Items this archive replaces are listed in a marker until it is unpacked. After an
  # interrupted run they hold a partial copy, and the originals are already aside.
  marker="$RUN_DIR/inprogress-$name"
  merge=0
  [ -z "$(items_of "$name")" ] && merge=1  # no plan entry: never extract over the home folder
  while IFS= read -r item; do
    case "$SRC/" in "$HOME/$item/"*) merge=1; continue ;; esac
    if [ -f "$marker" ] && grep -qxF -- "$item" "$marker"; then rm -rf "${HOME:?}/$item"; continue; fi
    if [ -e "$HOME/$item" ] || [ -L "$HOME/$item" ]; then
      if merge_item "$item"; then merge=1; continue; fi
      mkdir -p "$REPLACED/$(dirname "$item")" && mv "$HOME/$item" "$REPLACED/$item" && echo "    moved existing ~/$item aside"
    fi
    echo "$item" >> "$marker"
  done < <(items_of "$name")

  export M_CUR=$((bytes_total / 1024)) M_NAME="$name"
  if [ "$merge" = 1 ]; then
    stage="$RUN_DIR/staging-$name"
    rm -rf "$stage"; mkdir -p "$stage"
    cat "${files[@]}" | meter | decrypt | tar -xpzf - -C "$stage"
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ] && [ "${st[2]}" -eq 0 ] && [ "${st[3]}" -eq 0 ]; then merge_into_home "$stage" || st=(1 1 1 1); fi
    rm -rf "$stage"
  else
    cat "${files[@]}" | meter | decrypt | tar -xpzf - -C "$HOME"
    st=("${PIPESTATUS[@]}")
  fi
  M_BEFORE=$((M_BEFORE + kb))
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ] || [ "${st[3]}" -ne 0 ]; then
    echo "    $name: could not be unpacked fully. Run the restore again to retry it."; failed=1; continue
  fi
  echo "$name.tar.gz.enc" >> "$DONE"
  rm -f "$marker"
  # the archive is in the cloud: free the downloaded copy on this Mac
  [ "$cloud_source" = 1 ] && cloud evict "${files[@]}" > /dev/null 2>&1
done

if [ -d "$HOME/.ssh" ]; then
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
fi
[ -d "$HOME/.gnupg" ] && chmod -R go-rwx "$HOME/.gnupg"

# --- Old home path to new home path -----------------------------------------

# Rewrites old to new in text files. Only whole paths match: with /Users/nikola as the old home,
# /Users/nikola.vasilev stays as it is, so running this again changes nothing.
rewrite_paths() {  # old new file...
  /usr/bin/perl -e '
    my ($o, $n) = (shift, shift);
    my $re = qr/\Q$o\E(?=[\/"\x27\s:;,=)\]}>]|$)/m;
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next; binmode $fh; local $/; my $s = <$fh>; close $fh;
      next if !defined $s || index($s, "\0") >= 0;
      (my $t = $s) =~ s/$re/$n/g;
      next if $t eq $s;
      if (open($fh, "+<", $f)) { binmode $fh; truncate($fh, 0); print $fh $t; close $fh; print "updated\t$f\n" }
      else { print "failed\t$f\n" }
    }
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next; binmode $fh; local $/; my $s = <$fh>; close $fh;
      print "left\t$f\n" if defined $s && index($s, "\0") < 0 && $s =~ $re;
    }' "$@"
}

OLD_HOME="${OLD_HOME:-$(head -1 "$STATE_DIR/source-home.txt" 2>/dev/null)}"
if [ -n "$OLD_HOME" ] && [ "$OLD_HOME" != "$HOME" ]; then
  log "Changing $OLD_HOME to $HOME"
  # Claude Code names project dirs after the path, non-alphanumerics replaced by -
  p="$HOME/.claude/projects"
  old_slug=$(printf '%s' "$OLD_HOME" | sed 's/[^A-Za-z0-9]/-/g')
  new_slug=$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')
  [ "$claude_running" = 1 ] || for d in "$p/$old_slug" "$p/$old_slug"-*; do
    [ -d "$d" ] || continue
    rest="${d#"$p/$old_slug"}"
    # with /Users/nikola → /Users/nikola.vasilev the new folders start with the old name too
    case "$new_slug" in "$old_slug"*) case "$(basename "$d")" in "$new_slug" | "$new_slug"-*) continue ;; esac ;; esac
    dest="$p/$new_slug$rest"
    if [ -e "$dest" ]; then
      rsync -a --ignore-existing "$d/" "$dest/" && echo "    merged $(basename "$d") into $(basename "$dest") (old folder kept)"
    else
      mv "$d" "$dest" && echo "    renamed $(basename "$d")"
    fi
  done

  targets=()
  for t in .zshrc .zprofile .zshenv .zlogin .bashrc .bash_profile .profile .p10k.zsh .gitconfig .config/git \
           .npmrc .yarnrc .yarnrc.yml .tool-versions .ssh/config .aws/config .kube/config .docker/config.json \
           .m2/settings.xml .gradle/gradle.properties .config/nvim .config/ghostty .config/starship.toml \
           .claude.json .claude/skills .claude/commands .claude/agents .claude/hooks; do
    [ -e "$HOME/$t" ] && targets+=("$HOME/$t")
  done
  for t in "$HOME"/.claude/settings*.json "$HOME"/.claude/plugins/*.json "$HOME"/.claude/projects/*/memory; do targets+=("$t"); done
  while IFS= read -r root; do
    [ -n "$root" ] && for t in "$HOME/$root"/*/.claude; do targets+=("$t"); done
  done < <(cat "$STATE_DIR/project-roots.txt" 2>/dev/null)
  if [ "$claude_running" = 1 ]; then
    kept=(); for t in "${targets[@]}"; do case "$t" in "$HOME"/.claude*) ;; *) kept+=("$t") ;; esac; done
    targets=("${kept[@]}")
    grep -qsF "$OLD_HOME/" "$HOME/.claude.json" && echo "    ~/.claude.json still has old paths: close Claude Code and run this script again."
  fi
  if [ ${#targets[@]} -gt 0 ]; then
    files=(); while IFS= read -r f; do files+=("$f"); done < <(grep -rlIF "$OLD_HOME" "${targets[@]}" 2>/dev/null)
    if [ ${#files[@]} -gt 0 ]; then
      left=()
      while IFS=$'\t' read -r what f; do
        case "$what" in
          updated) echo "    updated ${f#"$HOME"/}" ;;
          failed) echo "    could not update ${f#"$HOME"/}" ;;
          left) left+=("$f") ;;
        esac
      done < <(rewrite_paths "$OLD_HOME" "$HOME" "${files[@]}")
      if [ ${#left[@]} -gt 0 ]; then echo "    Still contains the old path:"; printf '      %s\n' "${left[@]}"; fi
    fi
  fi
fi

log "Files restored."
[ ${#missing[@]} -gt 0 ] && warn "Not in $SRC (yet): ${missing[*]}. Run the restore again when they are there."
[ "$failed" -ne 0 ] && echo "    Some archives failed (see above). Fix them and run this script again."
echo
echo "Next steps:"
echo "  - Open a new Terminal window so your restored shell settings load."
if [ -f "$STATE_DIR/new-mac-setup/setup.sh" ]; then
  echo "  - Install your apps and tools (read its README.md first):  /bin/bash ~/.mac-migration/new-mac-setup/setup.sh"
fi
if [ -x /opt/homebrew/bin/brew ] && ! grep -qs '/opt/homebrew/bin/brew shellenv' "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; then
  echo "  - Your restored shell files don't load Homebrew from /opt/homebrew. Add this line to ~/.zprofile:"
  echo "      eval \"\$(/opt/homebrew/bin/brew shellenv)\""
fi
echo "  - Check ~/.mac-migration/inventory.md for repos and tools the setup script doesn't cover."
echo "  - Log in again to command-line tools that keep tokens in the Keychain: gh, gcloud, az, aws sso, and so on."
echo "  - Sign in to your browsers and IDEs and turn on sync."
echo "  - Reinstall project dependencies (npm install, uv sync, ...) when you open a project."
echo "  - Delete the archives from your cloud drive once everything works."
[ -d "$REPLACED" ] && echo "  - Files the restore moved aside are in $REPLACED"
event "done" "Restored ${#pending[@]} archive(s)"
if [ ${#no_space[@]} -gt 0 ]; then FAIL_REASON="Not enough space for: ${no_space[*]}"; exit "$E_SPACE"; fi
[ "$failed" -ne 0 ] && { FAIL_REASON="Some archives failed"; exit 1; }
exit 0
