#!/bin/bash
# Usage: ./backup.sh             create the encrypted archives
#        DRY_RUN=1 ./backup.sh   show the plan only
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSSL=/usr/bin/openssl  # same LibreSSL build on every Mac
STATE_DIR_NAME=.mac-migration

# Defaults, overridable in config.sh
OUT="${OUT:-$HOME/mac-migration-archives}"
MAX_BATCH_GB=8
FREE_MARGIN_GB=5
SETTINGS_ITEMS=(
  .ssh .gnupg .aws .azure .kube .docker/config.json
  .zshrc .zprofile .zshenv .zlogin .zsh_history .bashrc .bash_profile .profile .bash_history .p10k.zsh
  .gitconfig .gitignore_global .gitmessage .config/git
  .npmrc .yarnrc .yarnrc.yml .netrc .pypirc .m2/settings.xml .gradle/gradle.properties .tool-versions .editorconfig
  .vimrc .config/nvim .tmux.conf .config/ghostty .config/starship.toml .wezterm.lua .config/kitty .config/alacritty
  .claude .claude.json
)
PERSONAL_ITEMS=(Documents Desktop)
PROJECT_ROOTS=(proj projects Projects code Code dev Developer src repos workspace git GitHub)
EXCLUDE_NAMES=(node_modules .venv venv .next .nuxt .terraform __pycache__ .pytest_cache .DS_Store)

CONFIG="${MIGRATE_CONFIG:-$SCRIPT_DIR/config.sh}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

MAX_BATCH_KB="${MAX_BATCH_KB:-$((MAX_BATCH_GB * 1024 * 1024))}"
FREE_MARGIN_KB=$((FREE_MARGIN_GB * 1024 * 1024))
DRY_RUN="${DRY_RUN:-0}"
STATE_DIR="$HOME/$STATE_DIR_NAME"

TAR_EXCLUDES=(); DU_EXCLUDES=(); PRUNE=()
for n in "${EXCLUDE_NAMES[@]}"; do
  TAR_EXCLUDES+=(--exclude "$n"); DU_EXCLUDES+=(-I "$n")
  [ ${#PRUNE[@]} -gt 0 ] && PRUNE+=(-o)
  PRUNE+=(-name "$n")
done
[ ${#PRUNE[@]} -eq 0 ] && PRUNE=(-false)

log() { printf '\n==> %s\n' "$*"; }
free_kb() { df -k "$OUT" | awk 'NR==2 {print $4}'; }
size_kb() { (cd "$HOME" && du -sk "${DU_EXCLUDES[@]}" "$@" 2>/dev/null) | awk '{s+=$1} END {print s+0}'; }
encrypt() { "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:MIG_PASS "$@"; }

cloud_only() {
  xattr "$HOME/$1" 2>/dev/null | grep -qx com.apple.icloud.desktop && return 0
  [ -n "$(find "$HOME/$1" -flags +dataless -print 2>/dev/null | head -1)" ]
}

# Pass-through that draws the progress bar on stderr
meter() {
  /usr/bin/perl -e '
    use strict; use Time::HiRes qw(time);
    binmode STDIN; binmode STDOUT; binmode STDERR, ":utf8";
    my ($total, $before, $cur, $name) = @ENV{qw(M_TOTAL M_BEFORE M_CUR M_NAME)};
    my ($n, $buf, $bytes, $t0, $last) = (0, "", 0, time, 0);
    sub draw {
      my $kb = $_[0] ? $cur : $bytes / 1024;
      $kb = $cur * 0.99 if $kb > $cur * 0.99 && !$_[0];
      my $all = $total > 0 ? ($before + $kb) / $total : 1; $all = 1 if $all > 1;
      my $fill = int($all * 30 + 0.5);
      my $secs = time - $t0;
      my $rate = $secs > 0 ? $bytes / $secs : 0;
      my $m = $rate > 0 ? int(($total - $before - $kb) * 1024 / $rate / 60 + 0.5) : 0; $m = 0 if $m < 0;
      my $speed = $secs < 3 ? "  --" : sprintf("%4d", $rate / 1048576);
      my $eta = $secs < 3 ? "--" : $m >= 60 ? sprintf("%dh%02dm", $m / 60, $m % 60) : "${m}m";
      my $pct = $cur > 0 ? $kb / $cur * 100 : 100; $pct = 100 if $pct > 100;
      printf STDERR "\r  [%s%s] %3d%%  %5.1f / %.1f GB  |  %s %3d%%  |  %s MB/s  |  ~%s left   ",
        "\x{2588}" x $fill, "\x{2591}" x (30 - $fill), $all * 100, ($before + $kb) / 1048576, $total / 1048576,
        $name, $pct, $speed, $eta;
    }
    while (($n = sysread(STDIN, $buf, 1 << 20)) > 0) {
      my $off = 0;
      while ($off < $n) { my $w = syswrite(STDOUT, $buf, $n - $off, $off); exit 1 unless defined $w; $off += $w; }
      $bytes += $n;
      if (time - $last >= 1) { draw(0); $last = time; }
    }
    draw(1); print STDERR "\n";
    exit(defined $n ? 0 : 1);
  '
}

# APFS is case-insensitive by default, so code and Code can be the same folder
existing_project_roots() {
  local i ino seen=" "
  for i in "${PROJECT_ROOTS[@]}"; do
    [ -d "$HOME/$i" ] || continue
    ino=$(stat -f %i "$HOME/$i")
    case "$seen" in *" $ino "*) continue ;; esac
    seen="$seen$ino "
    ls -A "$HOME" | grep -qxF -- "$i" || i=$(ls -A "$HOME" | grep -ixF -- "$i" | head -1)
    echo "$i"
  done
}

included_roots() {
  local i
  existing_project_roots
  for i in "${PERSONAL_ITEMS[@]}"; do [ -e "$HOME/$i" ] && ! cloud_only "$i" && echo "$i"; done
}

write_inventory() {
  local inv="$STATE_DIR/inventory.md" roots r rel dirty stash remote ahead noup inside
  roots=$(included_roots)
  : > "$STATE_DIR/.at-risk"; : > "$STATE_DIR/.outside"
  {
    echo "# Inventory of $(scutil --get ComputerName 2>/dev/null || hostname) ($(date '+%Y-%m-%d %H:%M'))"
    echo; echo "## Git repos"
    find "$HOME" -maxdepth 6 \( -path "$HOME/Library" -o -path "$HOME/.*" -o -path "$OUT" -o -name node_modules \) -prune \
      -o -type d -name .git -print 2>/dev/null | sed 's#/\.git$##' | sort | while IFS= read -r r; do
      rel="${r#"$HOME"/}"
      dirty=$(git -C "$r" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      stash=$(git -C "$r" stash list 2>/dev/null | wc -l | tr -d ' ')
      remote=$(git -C "$r" remote get-url origin 2>/dev/null || echo "none")
      ahead=$(git -C "$r" for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | grep ahead | tr '\n' ' ')
      noup=$(git -C "$r" for-each-ref --format='%(refname:short) %(upstream)' refs/heads | awk '$2=="" {print $1}' | tr '\n' ' ')
      inside=no
      while IFS= read -r i; do case "$rel/" in "$i"/*) inside=yes ;; esac; done <<< "$roots"
      echo "- $rel | remote: $remote | uncommitted: $dirty | stashes: $stash | unpushed: ${ahead:-none} | local-only branches: ${noup:-none} | in archives: $inside"
      if [ "$inside" = no ]; then
        echo "$rel" >> "$STATE_DIR/.outside"
      elif [ "$remote" = none ] || [ "$dirty" -gt 0 ] || [ "$stash" -gt 0 ] || [ -n "$ahead" ]; then
        echo "$rel" >> "$STATE_DIR/.at-risk"
      fi
    done
    echo; echo "## Apps"
    ls /Applications "$HOME/Applications" 2>/dev/null | grep '\.app$' | sed 's/\.app$//; s/^/- /' | sort -u
    if command -v code >/dev/null; then echo; echo "## VS Code extensions"; code --list-extensions 2>/dev/null | sed 's/^/- /'; fi
    if command -v npm >/dev/null; then echo; echo "## Global npm packages (node $(node -v 2>/dev/null))"; npm ls -g --depth=0 2>/dev/null | tail -n +2; fi
    if command -v pipx >/dev/null; then echo; echo "## pipx"; pipx list --short 2>/dev/null; fi
    if command -v uv >/dev/null; then echo; echo "## uv tools"; uv tool list 2>/dev/null; fi
    echo; echo "## Chrome profiles: turn on Sync in each one before you switch"
    ls "$HOME/Library/Application Support/Google/Chrome" 2>/dev/null | grep -E '^(Default|Profile )' | sed 's/^/- /'
  } > "$inv"
  echo "    Saved ~/$STATE_DIR_NAME/inventory.md"
  if [ -s "$STATE_DIR/.at-risk" ]; then
    echo "    Repos with work that is not on a remote yet (it is in the archives):"
    sed 's/^/      /' "$STATE_DIR/.at-risk"
  fi
  if [ -s "$STATE_DIR/.outside" ]; then
    echo "    Repos NOT in the archives (push them, or add their folder to PROJECT_ROOTS in config.sh):"
    sed 's/^/      /' "$STATE_DIR/.outside"
  fi
  rm -f "$STATE_DIR/.at-risk" "$STATE_DIR/.outside"
}

# plan.txt line: name<TAB>size_kb<TAB>item...
add_plan() { local name="$1"; shift; [ $# -eq 0 ] && return; printf '%s\t%s' "$name" "$(size_kb "$@")"; printf '\t%s' "$@"; echo; }
build_plan() {
  local items=() i u root kb batch=() batch_kb=0 n=1
  for i in "${SETTINGS_ITEMS[@]}" "$STATE_DIR_NAME"; do [ -e "$HOME/$i" ] && items+=("$i"); done
  add_plan settings "${items[@]}"
  items=()
  for i in "${PERSONAL_ITEMS[@]}"; do
    [ -e "$HOME/$i" ] || continue
    if cloud_only "$i"; then echo "    Skipping ~/$i: it is synced by iCloud or another cloud drive." >&2; continue; fi
    items+=("$i")
  done
  add_plan personal "${items[@]}"
  while IFS= read -r root; do
    while IFS= read -r u; do
      [ "$u" = .DS_Store ] && continue
      [ "$HOME/$root/$u" = "$OUT" ] && continue
      kb=$(size_kb "$root/$u")
      if [ ${#batch[@]} -gt 0 ] && [ $((batch_kb + kb)) -gt "$MAX_BATCH_KB" ]; then
        add_plan "$(printf 'projects-%02d' $n)" "${batch[@]}"; n=$((n + 1)); batch=(); batch_kb=0
      fi
      batch+=("$root/$u"); batch_kb=$((batch_kb + kb))
    done < <(ls -A "$HOME/$root")
  done < <(existing_project_roots)
  [ ${#batch[@]} -gt 0 ] && add_plan "$(printf 'projects-%02d' $n)" "${batch[@]}"
}

wait_for_upload() {
  local files=("$OUT"/*.tar.gz.enc)
  [ -e "${files[0]}" ] || return
  log "The disk is nearly full. Move these files to your cloud drive or external disk now:"
  printf '    %s\n' "${files[@]}"
  local ans
  until [ "$ans" = uploaded ]; do
    read -r -p "    Type 'uploaded' once every upload is complete (the files are then deleted here): " ans
  done
  rm -f "${files[@]}"
}

make_archive() {
  local name="$1" kb="$2"; shift 2
  local file="$OUT/$name.tar.gz.enc" errlog="$OUT/$name.errors.log" skip="$OUT/.sockets-$name"
  if grep -qx "$name" "$OUT/.done" 2>/dev/null; then echo "    $name: already done"; return; fi
  if [ "$(free_kb)" -lt $((kb + FREE_MARGIN_KB)) ]; then
    wait_for_upload
    if [ "$(free_kb)" -lt $((kb + FREE_MARGIN_KB)) ]; then
      echo "Not enough free space for $name ($((kb / 1024)) MB). Free up space and run the script again."; exit 1
    fi
  fi
  (cd "$HOME" && find "$@" \( "${PRUNE[@]}" \) -prune -o -type s -print 2>/dev/null) > "$skip"
  export M_CUR="$kb" M_NAME="$name"
  (cd "$HOME" && tar "${TAR_EXCLUDES[@]}" -X "$skip" -cf - "$@" 2>"$errlog") | meter | gzip -c | encrypt -out "$file.part"
  local st=("${PIPESTATUS[@]}")
  rm -f "$skip"
  if [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ] || [ "${st[3]}" -ne 0 ]; then
    echo "Packing failed for $name."; rm -f "$file.part"; exit 1
  fi
  if [ -s "$errlog" ]; then
    echo "    Note: tar skipped some files in $name (list in $errlog). Everything else is saved."
  else
    rm -f "$errlog"
  fi
  mv "$file.part" "$file"
  printf '%s  %s\n' "$(shasum -a 256 "$file" | cut -d' ' -f1)" "$name.tar.gz.enc" >> "$OUT/MANIFEST.txt"
  echo "$name" >> "$OUT/.done"
}

if [ "$DRY_RUN" = 1 ]; then
  log "Plan (nothing is created in a dry run):"
  build_plan | awk -F'\t' '{t += $2; printf "    %-12s %7d MB  ", $1, $2/1024; for (i = 3; i <= NF; i++) printf "%s ", $i; print ""} END {printf "    Total: %.1f GB before compression\n", t/1048576}'
  exit 0
fi

mkdir -p "$OUT" "$STATE_DIR"
trap 'rm -f "$OUT"/*.part' EXIT

if [ -z "$MIG_PASS" ]; then
  echo "Choose a password for the archives. Save it in your password manager: without it the archives can't be opened."
  read -rs -p "Password: " p1; echo
  read -rs -p "Repeat the password: " p2; echo
  if [ -z "$p1" ] || [ "$p1" != "$p2" ]; then echo "The passwords don't match."; exit 1; fi
  export MIG_PASS="$p1"
fi
if [ -f "$OUT/.pwcheck" ]; then
  encrypt -d -in "$OUT/.pwcheck" 2>/dev/null | grep -qx ok || { echo "That isn't the password used for the earlier archives."; exit 1; }
else
  echo ok | encrypt -out "$OUT/.pwcheck"
fi

if [ ! -f "$OUT/plan.txt" ]; then
  printf '%s\n' "$HOME" > "$STATE_DIR/source-home.txt"
  included_roots > "$STATE_DIR/project-roots.txt"
  log "Saving a list of repos, apps and tools"
  write_inventory
  if [ -z "$SKIP_BREW" ] && command -v brew >/dev/null; then
    log "Saving your Homebrew packages"
    brew bundle dump --file="$STATE_DIR/Brewfile" --force >/dev/null 2>&1 && echo "    Saved ~/$STATE_DIR_NAME/Brewfile"
  fi
  log "Measuring folders"
  build_plan > "$OUT/plan.txt"
fi

log "Creating archives in $OUT"
export M_TOTAL M_BEFORE=0
M_TOTAL=$(awk -F'\t' '{s += $2} END {print s + 0}' "$OUT/plan.txt")
while IFS=$'\t' read -r -a row -u 3; do
  make_archive "${row[@]}"
  M_BEFORE=$((M_BEFORE + row[1]))
done 3< "$OUT/plan.txt"
cp "$SCRIPT_DIR/restore.sh" "$OUT/"

log "Done. Copy everything in $OUT to your cloud drive or external disk:"
ls -1 "$OUT" | sed 's/^/    /'
echo "    Keep this Mac as it is until the new one works."
