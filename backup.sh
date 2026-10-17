#!/bin/bash
# Usage: ./backup.sh [--to FOLDER]           pack settings, projects and folders into encrypted archives
#        ./backup.sh --add Downloads ...      add folders to a backup, also after it finished
#        ./backup.sh --redo NAME              pack one archive again
#        ./backup.sh --plan [--to FOLDER]     show what goes into which archive, create nothing
#        ./backup.sh --status [--to FOLDER]   show the backup in a folder
#        ./backup.sh --list-places            cloud folders and disks the backup can go to
#        ./backup.sh --list-sources           folders that can go into the backup, with their size
# --to takes a cloud folder (Google Drive, iCloud Drive, OneDrive, Dropbox), a disk or any folder.
# Without it the archives go to ~/mac-migration-archives and you copy them yourself.
# --password-stdin reads the password from standard input. --uploaded says the archives in
# ~/mac-migration-archives were copied elsewhere, so they can be deleted to make room.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/places.sh
. "$SCRIPT_DIR/lib/places.sh"

# Defaults, overridable in config.sh
OUT="${OUT:-$HOME/mac-migration-archives}"
DEST="${MIG_DEST:-}"
MAX_BATCH_GB=8
FREE_MARGIN_GB=5
PART_MB="${PART_MB:-}"
VERIFY_ARCHIVES=1
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

# config.sh next to the scripts (older setups), then ~/.mac-migration/config.sh
if [ -n "$MIGRATE_CONFIG" ]; then CONFIGS=("$MIGRATE_CONFIG"); else CONFIGS=("$SCRIPT_DIR/config.sh" "$STATE_DIR/config.sh"); fi
for c in "${CONFIGS[@]}"; do
  # shellcheck source=/dev/null
  [ -f "$c" ] && . "$c"
done
# Choices made in the app, one item per line
if [ -n "${MIG_PERSONAL_ITEMS+x}" ]; then
  PERSONAL_ITEMS=(); while IFS= read -r i; do [ -n "$i" ] && PERSONAL_ITEMS+=("$i"); done <<< "$MIG_PERSONAL_ITEMS"
fi
if [ -n "${MIG_PROJECT_ROOTS+x}" ]; then
  PROJECT_ROOTS=(); while IFS= read -r i; do [ -n "$i" ] && PROJECT_ROOTS+=("$i"); done <<< "$MIG_PROJECT_ROOTS"
fi

MAX_BATCH_KB="${MAX_BATCH_KB:-$((MAX_BATCH_GB * 1024 * 1024))}"
FREE_MARGIN_KB=$((FREE_MARGIN_GB * 1024 * 1024))
STALL_SECS="${MIG_STALL_SECONDS:-600}"
SIZES="$STATE_DIR/run/sizes.tsv"

ACTION=run
[ "$DRY_RUN" = 1 ] && ACTION=plan
ADD_ITEMS=(); REDO=""; PASSWORD_STDIN=0; UPLOADED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --add)
      shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        i="${1%/}"; i="${i#"$HOME"/}"
        case "$i" in /*) echo "--add takes folders inside your home folder: $1"; exit 1 ;; esac
        ADD_ITEMS+=("$i"); shift
      done ;;
    --to) [ -n "$2" ] || { echo "--to needs a folder"; exit 1; }; DEST="$2"; shift 2 ;;
    --redo) [ -n "$2" ] || { echo "--redo needs an archive name"; exit 1; }; REDO="$2"; shift 2 ;;
    --plan) ACTION=plan; shift ;;
    --status) ACTION=status; shift ;;
    --list-places) ACTION=places; shift ;;
    --list-sources) ACTION=sources; shift ;;
    --password-stdin) PASSWORD_STDIN=1; shift ;;
    --uploaded) UPLOADED=1; shift ;;
    --version) echo "mac-migrate $MM_VERSION"; exit 0 ;;
    -h | --help) sed -n "2,11p" "$0" | sed "s/^# \{0,1\}//"; exit 0 ;;
    *) echo "Unknown option: $1 (see ./backup.sh --help)"; exit 1 ;;
  esac
done
mm_env

# --- What goes in -----------------------------------------------------------

# Paths of the backup itself and of mac-migrate's working files, never packed
SELF_PATHS=("$STATE_DIR_NAME/lock" "$STATE_DIR_NAME/logs" "$STATE_DIR_NAME/run" .mac-migration-staging)

# Names in EXCLUDE_NAMES are left out of project and personal archives. Settings items are
# listed one by one, so a name that is part of a listed item doesn't apply there
# (.gradle would drop .gradle/gradle.properties).
build_excludes() {  # settings|other
  local n i p skip
  TAR_EXCLUDES=(); DU_EXCLUDES=(); PRUNE=()
  for n in "${EXCLUDE_NAMES[@]}"; do
    if [ "$1" = settings ]; then
      skip=0
      for i in "${SETTINGS_ITEMS[@]}"; do case "/$i/" in */"$n"/*) skip=1 ;; esac; done
      [ $skip = 1 ] && continue
    fi
    TAR_EXCLUDES+=(--exclude "$n"); DU_EXCLUDES+=(-I "$n")
    [ ${#PRUNE[@]} -gt 0 ] && PRUNE+=(-o)
    PRUNE+=(-name "$n")
  done
  [ ${#PRUNE[@]} -eq 0 ] && PRUNE=(-false)
  for p in "${SELF_PATHS[@]}"; do TAR_EXCLUDES+=(--exclude "$(printf '%s' "$p" | sed 's/[][*?\\]/\\&/g')"); done
}
build_excludes other

size_kb() { (cd "$HOME" && du -sk "${DU_EXCLUDES[@]}" "$@" 2>/dev/null) | awk '{s+=$1} END {print s+0}'; }

# Sizes measured by --list-sources in the last hour, so the app's preview and the plan agree
cached_kb() {
  local kb=""
  [ -n "$(find "$SIZES" -mmin -60 2>/dev/null)" ] && kb=$(awk -F'\t' -v i="$1" '$1 == i {print $2; exit}' "$SIZES")
  if [ -n "$kb" ]; then echo "$kb"; else size_kb "$1"; fi
}

cloud_only() {
  xattr "$HOME/$1" 2>/dev/null | grep -qx com.apple.icloud.desktop && return 0
  [ -n "$(find "$HOME/$1" -flags +dataless -print 2>/dev/null | head -1)" ]
}

# APFS is case-insensitive by default, so code and Code can be the same folder
existing_project_roots() {
  local i ino seen=" "
  for i in "${PROJECT_ROOTS[@]}"; do
    [ -d "$HOME/$i" ] || continue
    ino=$(stat -f %i "$HOME/$i")
    case "$seen" in *" $ino "*) continue ;; esac
    seen="$seen$ino "
    # shellcheck disable=SC2010  # the folder's real spelling, as ls shows it
    ls -A "$HOME" | grep -qxF -- "$i" || i=$(ls -A "$HOME" | grep -ixF -- "$i" | head -1)
    echo "$i"
  done
}

included_roots() {
  local i
  existing_project_roots
  for i in "${PERSONAL_ITEMS[@]}"; do [ -e "$HOME/$i" ] && ! cloud_only "$i" && echo "$i"; done
}

# Reading Desktop, Documents and Downloads needs the user's consent. Without it tar would
# pack nearly nothing and the backup would look fine, so ask macOS now and stop if it says no.
check_access() {
  local i denied=() who="${TERM_PROGRAM:-Terminal}"
  [ "$who" = Apple_Terminal ] && who=Terminal
  [ "$MIG_NONINTERACTIVE" = 1 ] && who="Mac Migrate"
  for i in "$@"; do
    [ -e "$HOME/$i" ] || continue
    # shellcheck disable=SC2088  # ~ is for display
    case "$(ls "$HOME/$i" 2>&1 >/dev/null)" in *"Operation not permitted"*) denied+=("~/$i") ;; esac
  done
  [ ${#denied[@]} -eq 0 ] && return 0
  die "$E_PERMISSION" "macOS doesn't let $who read ${denied[*]}. Allow it in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), then start the backup again."
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
    # shellcheck disable=SC2010
    ls /Applications "$HOME/Applications" 2>/dev/null | grep '\.app$' | sed 's/\.app$//; s/^/- /' | sort -u
    if command -v code >/dev/null; then echo; echo "## VS Code extensions"; code --list-extensions 2>/dev/null | sed 's/^/- /'; fi
    if command -v npm >/dev/null; then echo; echo "## Global npm packages (node $(node -v 2>/dev/null))"; npm ls -g --depth=0 2>/dev/null | tail -n +2; fi
    if command -v pipx >/dev/null; then echo; echo "## pipx"; pipx list --short 2>/dev/null; fi
    if command -v uv >/dev/null; then echo; echo "## uv tools"; uv tool list 2>/dev/null; fi
    echo; echo "## Chrome profiles: turn on Sync in each one before you switch"
    # shellcheck disable=SC2010
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
    event warn "$(wc -l < "$STATE_DIR/.outside" | tr -d ' ') git repos are outside the backup, see ~/$STATE_DIR_NAME/inventory.md"
  fi
  rm -f "$STATE_DIR/.at-risk" "$STATE_DIR/.outside"
}

# --- Plan -------------------------------------------------------------------
# plan.txt line: name<TAB>size_kb<TAB>item...

add_plan() {
  local name="$1"; shift
  [ $# -eq 0 ] && return
  if [ "$name" = settings ]; then build_excludes settings; else build_excludes other; fi
  printf '%s\t%s' "$name" "$(size_kb "$@")"; printf '\t%s' "$@"; echo
  build_excludes other
}

# Fills archives up to MAX_BATCH_KB: prefix-01, prefix-02, ... A single personal archive keeps the name "personal".
batch_items() {
  local prefix="$1" i kb line="" line_kb=0 lines=() n name
  shift
  for i in "$@"; do
    kb=$(cached_kb "$i")
    if [ -n "$line" ] && [ $((line_kb + kb)) -gt "$MAX_BATCH_KB" ]; then
      lines+=("$line_kb$line"); line=""; line_kb=0
    fi
    line="$line	$i"; line_kb=$((line_kb + kb))
  done
  [ -n "$line" ] && lines+=("$line_kb$line")
  for n in "${!lines[@]}"; do
    if [ "$prefix" = personal ] && [ ${#lines[@]} -eq 1 ]; then name=personal; else name=$(printf '%s-%02d' "$prefix" $((n + 1))); fi
    printf '%s\t%s\n' "$name" "${lines[$n]}"
  done
}

is_self() { local p; for p in "$OUT" "$PUBLISH" "$HOME/.mac-migration-staging"; do [ -n "$p" ] && [ "$HOME/$1" = "$p" ] && return 0; done; return 1; }

build_plan() {
  local items=() i u root
  for i in "${SETTINGS_ITEMS[@]}" "$STATE_DIR_NAME"; do [ -e "$HOME/$i" ] && items+=("$i"); done
  add_plan settings "${items[@]}"
  items=()
  for i in "${PERSONAL_ITEMS[@]}"; do
    [ -e "$HOME/$i" ] || continue
    if cloud_only "$i"; then echo "    Skipping ~/$i: it is synced by iCloud or another cloud drive." >&2; continue; fi
    is_self "$i" || items+=("$i")
  done
  [ ${#items[@]} -gt 0 ] && batch_items personal "${items[@]}"
  items=()
  while IFS= read -r root; do
    while IFS= read -r u; do
      [ "$u" = .DS_Store ] && continue
      is_self "$root/$u" || items+=("$root/$u")
    done < <(ls -A "$HOME/$root")
  done < <(existing_project_roots)
  [ ${#items[@]} -gt 0 ] && batch_items projects "${items[@]}"
}

add_extras() {
  local plan="$1" i name clash
  for i in "${ADD_ITEMS[@]}"; do
    if [ ! -e "$HOME/$i" ]; then echo "    ~/$i doesn't exist, skipped." >&2; continue; fi
    # the folder is inside a planned item, or contains one
    clash=$(awk -F'\t' -v i="$i" '{for (k = 3; k <= NF; k++) if (i == $k || index(i "/", $k "/") == 1 || index($k "/", i "/") == 1) {print $k; exit}}' "$plan")
    if [ -n "$clash" ]; then
      if [ "$clash" = "$i" ] || [ "${i#"$clash"/}" != "$i" ]; then echo "    ~/$i is already in the backup." >&2
      else echo "    ~/$i contains ~/$clash, which is already in the backup. Add its other folders one by one." >&2; fi
      continue
    fi
    if cloud_only "$i"; then echo "    Skipping ~/$i: it is synced by iCloud or another cloud drive." >&2; continue; fi
    name="extra-$(printf '%s' "$i" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    while cut -f1 "$plan" | grep -qx "$name"; do name="$name-2"; done
    add_plan "$name" "$i" >> "$plan"
    echo "    Added ~/$i as $name" >&2
  done
}

print_plan() {
  awk -F'\t' '{t += $2; printf "    %-14s %7d MB  ", $1, $2/1024; for (i = 3; i <= NF; i++) printf "%s ", $i; print ""} END {printf "    Total: %.1f GB before compression\n", t/1048576}' "$1"
}

# --- Where it goes ----------------------------------------------------------
# local:  ~/mac-migration-archives (or OUT), copied elsewhere by the user
# folder: straight into a folder on a disk or anywhere else
# cloud:  packed in ~/.mac-migration-staging, then moved into the cloud folder; once uploaded
#         the local copy is freed, so the backup fits on a nearly full disk

provider_name() {
  case "$1" in
    "$HOME/Library/CloudStorage/GoogleDrive-"*) echo "Google Drive" ;;
    "$HOME/Library/CloudStorage/OneDrive"*) echo "OneDrive" ;;
    "$HOME/Library/CloudStorage/Dropbox"*) echo "Dropbox" ;;
    "$HOME/Library/CloudStorage/Box"*) echo "Box" ;;
    "$HOME/Library/Mobile Documents/"*) echo "iCloud Drive" ;;
    *) echo "the cloud drive" ;;
  esac
}

resolve_destination() {  # [existing]
  PUBLISH=""
  if [ -z "$DEST" ]; then
    MODE=local
    case "$OUT" in /*) ;; *) OUT="$HOME/$OUT" ;; esac
    if in_cloud_folder "$OUT"; then
      die 1 "OUT is inside a cloud folder. Use --to \"$(dirname "$OUT")\" instead: then each archive is uploaded and freed on this Mac before the next one."
    fi
    BACKUP_DIR="$OUT"
    return
  fi
  [ -d "$DEST" ] || die 1 "$DEST doesn't exist."
  DEST=$(cd "$DEST" && pwd)
  BACKUP_DIR=$(backup_dir_in "$DEST" "$1")
  [ -n "$BACKUP_DIR" ] || return 1
  if in_cloud_folder "$BACKUP_DIR"; then
    MODE=cloud; PUBLISH="$BACKUP_DIR"; PROVIDER=$(provider_name "$PUBLISH")
    # one staging folder per destination: two backups of this Mac on the same day share a name
    OUT="$HOME/.mac-migration-staging/$(basename "$BACKUP_DIR")-$(printf '%s' "$BACKUP_DIR" | shasum | cut -c1-8)"
  else
    MODE=folder; OUT="$BACKUP_DIR"
  fi
  if [ -z "$PART_MB" ]; then PART_MB=$(part_limit_mb "$DEST"); fi
}

# Files of one archive, in order, from .parts.tsv (file<TAB>bytes<TAB>sha256)
parts_of() { awk -F'\t' -v n="$1" '{f = $1; sub(/\.tar\.gz\.enc(\.[0-9]+)?$/, "", f); if (f == n) print $1}' "$OUT/.parts.tsv" 2>/dev/null; }
# Done when its parts are listed and, on a disk or in a cloud folder, still there.
# In ~/mac-migration-archives the user may have deleted them after uploading.
archive_done() {
  local f files
  files=$(parts_of "$1")
  [ -n "$files" ] || return 1
  [ "$MODE" = local ] && return 0
  while IFS= read -r f; do [ -e "$BACKUP_DIR/$f" ] || return 1; done <<< "$files"
}

# Drops an archive from .parts.tsv and deletes its files, to pack it again
forget_archive() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$OUT/$f"; [ "$MODE" = cloud ] && rm -f "$PUBLISH/$f"
  done < <(parts_of "$1")
  [ -f "$OUT/.parts.tsv" ] || return 0
  awk -F'\t' -v n="$1" '{f = $1; sub(/\.tar\.gz\.enc(\.[0-9]+)?$/, "", f); if (f != n) print}' "$OUT/.parts.tsv" > "$OUT/.parts.tsv.tmp"
  mv -f "$OUT/.parts.tsv.tmp" "$OUT/.parts.tsv"
}

manifest_write() {  # complete: yes|no
  local tmp="$OUT/MANIFEST.txt.tmp" salt f
  {
    printf '# mac-migrate format 2 backup=%s version=%s complete=%s\n' "$BACKUP_ID" "$MM_VERSION" "$1"
    [ -f "$OUT/.parts.tsv" ] && awk -F'\t' '{printf "%s  %s  %s\n", $3, $2, $1}' "$OUT/.parts.tsv"
    for f in plan.txt password-check.enc; do printf '%s  %s  %s\n' "$(sha256 "$OUT/$f")" "$(file_size "$OUT/$f")" "$f"; done
  } > "$tmp"
  salt=$("$OPENSSL" rand -hex 8)
  printf '# hmac-sha256 iter=%s salt=%s %s\n' "$KDF_ITER" "$salt" "$(hmac_file "$tmp" "$salt" "$KDF_ITER")" >> "$tmp"
  mv -f "$tmp" "$OUT/MANIFEST.txt"
  publish_meta
}

TOOL_FILES=(backup.sh restore.sh make-setup.sh cleanup.sh make-app.sh VERSION LICENSE README.md config.example.sh lib app)

# The tool goes next to the archives, so the new Mac can restore without anything else.
# restore.sh at the top runs it.
copy_tool() {
  local dir="$1" f
  mkdir -p "$dir/mac-migrate"
  for f in "${TOOL_FILES[@]}"; do [ -e "$SCRIPT_DIR/$f" ] && cp -RX "$SCRIPT_DIR/$f" "$dir/mac-migrate/"; done
  cat > "$dir/restore.sh" <<'EOF'
#!/bin/bash
# Restores the backup in this folder: /bin/bash restore.sh   (more in mac-migrate/README.md)
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$DIR/mac-migrate/restore.sh" ]; then echo "The mac-migrate folder next to restore.sh is missing. Copy the whole backup folder."; exit 1; fi
exec /bin/bash "$DIR/mac-migrate/restore.sh" --from "$DIR" "$@"
EOF
  chmod +x "$dir/restore.sh"
  [ -d "$STATE_DIR/new-mac-setup" ] && cp -RX "$STATE_DIR/new-mac-setup" "$dir/"
}

# Small files the restore needs, copied to the cloud folder after every change
publish_meta() {
  [ "$MODE" = cloud ] || return 0
  cp -X "$OUT/plan.txt" "$OUT/password-check.enc" "$OUT/MANIFEST.txt" "$PUBLISH/"
}

# --- Making room ------------------------------------------------------------

# Waits until every file has uploaded. Stops with E_STALLED when nothing uploads for STALL_SECS.
wait_uploaded() {
  local idle=0 step=5 pending moving err left_kb p cl up uping
  [ "$STALL_SECS" -lt 60 ] && step=1
  while :; do
    pending=0; moving=0; err=""; left_kb=0
    while IFS=$'\t' read -r p cl up uping _ e; do
      if [ "$cl" != 1 ] || [ "$up" = 1 ]; then continue; fi
      pending=$((pending + 1)); left_kb=$((left_kb + $(file_size "$p") / 1024))
      [ "$uping" = 1 ] && moving=1
      [ -n "$e" ] && [ "$e" != - ] && err="$e"
    done < <(cloud status "$@")
    [ $pending -eq 0 ] && return 0
    if [ $moving = 1 ]; then idle=0; else idle=$((idle + step)); fi
    status upload "" 0 "$left_kb" 0 -1 "Waiting for $PROVIDER to upload $pending file(s), $(gb "$left_kb") left"
    if [ $idle -ge "$STALL_SECS" ]; then
      die "$E_STALLED" "Nothing has uploaded to $PROVIDER for $((STALL_SECS / 60)) minutes${err:+ ($err)}. Check that $PROVIDER is running, signed in, online, not paused and has room for the backup, then start the backup again. It continues where it stopped."
    fi
    sleep "$step"
  done
}

# Cloud mode: frees uploaded archives on this Mac until there is room for the next one
make_room() {  # need_kb
  local need="$1" f p
  while IFS=$'\t' read -r f _ _; do
    [ "$(free_kb "$OUT")" -ge "$need" ] && return 0
    p="$PUBLISH/$f"
    [ -f "$p" ] || continue
    [ "$(cloud status "$p" | cut -f5)" = 1 ] || continue  # already freed
    echo "    Waiting for $PROVIDER to upload $f, then freeing it on this Mac"
    wait_uploaded "$p"
    cloud evict "$p" >/dev/null
    sleep 1
    if [ "$(cloud status "$p" | cut -f5)" = 1 ]; then
      die "$E_SPACE" "$PROVIDER keeps $f on this Mac after uploading it, so the backup can't make room for the next archive. In Google Drive, choose streaming instead of mirroring. For iCloud Drive, turn on Optimize Mac Storage. Or free up $(gb "$need"), or choose an external disk."
    fi
  done < "$OUT/.parts.tsv"
  [ "$(free_kb "$OUT")" -ge "$need" ]
}

# Local mode: the user copies the finished archives elsewhere, then they are deleted here
wait_for_upload() {
  local files=() f ans
  for f in "$OUT"/*.tar.gz.enc "$OUT"/*.tar.gz.enc.[0-9][0-9][0-9]; do [ -f "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || return 0
  if [ "$UPLOADED" != 1 ]; then
    if [ "$MIG_NONINTERACTIVE" = 1 ]; then
      for f in "${files[@]}"; do event file "$f"; done
      die "$E_UPLOAD" "The disk is nearly full. Copy the finished archives to your cloud drive or disk, then continue: they are deleted here to make room."
    fi
    log "The disk is nearly full. Move these files to your cloud drive or external disk now:"
    printf '    %s\n' "${files[@]}"
    until [ "$ans" = uploaded ]; do
      read -r -p "    Type 'uploaded' once every upload is complete (the files are then deleted here): " ans ||
        die "$E_UPLOAD" "Stopped while waiting for the upload. Run the backup again with --uploaded once the files are copied."
    done
  fi
  rm -f "${files[@]}"
  UPLOADED=0
  echo "    Deleted the uploaded archives here."
}

ensure_space() {  # name kb
  local need=$(($2 + FREE_MARGIN_KB))
  [ "$(free_kb "$OUT")" -ge "$need" ] && return 0
  case "$MODE" in
    cloud) make_room "$need" && return 0 ;;
    local) wait_for_upload; [ "$(free_kb "$OUT")" -ge "$need" ] && return 0 ;;
  esac
  warn "Skipped $1: it needs $(gb "$need") free, and only $(gb "$(free_kb "$OUT")") is free where it is packed."
  SKIPPED+=("$1")
  return 1
}

# --- Packing ----------------------------------------------------------------

# Writes the encrypted stream as base.001.part, base.002.part, ... of at most max bytes each
# (0: one part), hashing in the same pass. The list gets tmp<TAB>final<TAB>bytes<TAB>sha256:
# a single part is called base, several are base.001, base.002, ...
write_parts() {  # base max_bytes list
  /usr/bin/perl -MDigest::SHA -e '
    use strict;
    my ($base, $max, $list) = @ARGV;
    my (@parts, $fh, $sha, $size);
    sub open_part {
      my $p = sprintf("%s.%03d.part", $base, @parts + 1);
      open($fh, ">", $p) or die "$p: $!\n"; binmode $fh;
      $sha = Digest::SHA->new(256); $size = 0; push @parts, [$p];
    }
    sub close_part { close($fh) or die "$parts[-1][0]: $!\n"; push @{$parts[-1]}, $size, $sha->hexdigest; }
    open_part();
    my ($r, $buf);
    while ($r = sysread(STDIN, $buf, 1 << 20)) {
      my $off = 0;
      while ($off < $r) {
        if ($max && $size >= $max) { close_part(); open_part(); }
        my $take = $r - $off; $take = $max - $size if $max && $take > $max - $size;
        my $chunk = substr($buf, $off, $take);
        print $fh $chunk or die "$parts[-1][0]: $!\n";
        $sha->add($chunk); $size += $take; $off += $take;
      }
    }
    die "read: $!\n" unless defined $r;
    close_part();
    open(my $l, ">", $list) or die "$list: $!\n";
    for my $i (0 .. $#parts) {
      my $final = @parts == 1 ? $base : sprintf("%s.%03d", $base, $i + 1);
      print $l join("\t", $parts[$i][0], $final, $parts[$i][1], $parts[$i][2]), "\n";
    }
    close $l or die "$list: $!\n";' "$@"
}

make_archive() {
  local name="$1" kb="$2"; shift 2
  local base="$OUT/$name.tar.gz.enc" errlog="$OUT/$name.errors.log" skip="$OUT/.sockets-$name"
  local list="$OUT/.list-$name" count="$OUT/.count-$name" i tmp final size sha
  if archive_done "$name"; then echo "    $name: already done"; return 0; fi
  forget_archive "$name"  # listed, but its files are gone
  ensure_space "$name" "$kb" || return 0
  if [ "$name" = settings ]; then build_excludes settings; else build_excludes other; fi
  (cd "$HOME" && find "$@" \( "${PRUNE[@]}" \) -prune -o -type s -print 2>/dev/null) > "$skip"
  export M_CUR="$kb" M_NAME="$name" M_COUNT="$count"
  (cd "$HOME" && tar "${TAR_EXCLUDES[@]}" -X "$skip" -cf - "$@" 2>"$errlog") | meter | gzip -c | encrypt | write_parts "$base" "$((${PART_MB:-0} * 1048576))" "$list"
  local st=("${PIPESTATUS[@]}")
  rm -f "$skip"
  build_excludes other
  if [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ] || [ "${st[3]}" -ne 0 ] || [ "${st[4]}" -ne 0 ]; then
    die 1 "Packing failed for $name."
  fi
  if [ "${st[0]}" -ne 0 ]; then
    for i in "$@"; do
      if grep -qF "tar: $i: " "$errlog" && grep -q "Operation not permitted" "$errlog"; then
        die "$E_PERMISSION" "macOS didn't let tar read ~/$i. Allow access in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), then start the backup again."
      fi
    done
    [ -s "$errlog" ] || die 1 "tar failed for $name without saying why."
  fi
  # a run that packs almost nothing of a sizeable plan is broken, whatever the exit codes say
  if [ "$kb" -gt 1024 ] && [ "$(cat "$count" 2>/dev/null || echo 0)" -lt $((kb * 1024 / 100)) ]; then
    die 1 "Packing $name read far less data than planned. See $errlog."
  fi
  rm -f "$count"
  if [ "$VERIFY_ARCHIVES" = 1 ]; then
    status verify "$name" 0 "$kb" 0 -1 ""
    (while IFS=$'\t' read -r tmp _ _ _; do cat "$tmp"; done < "$list") | decrypt | tar -tzf - > /dev/null 2>&1
    local vs=("${PIPESTATUS[@]}")
    if [ "${vs[0]}" -ne 0 ] || [ "${vs[1]}" -ne 0 ] || [ "${vs[2]}" -ne 0 ]; then die 1 "The new archive $name doesn't read back. Check the disk and start the backup again."; fi
  fi
  : > "$list.done"
  while IFS=$'\t' read -r tmp final size sha; do
    mv -f "$tmp" "$final" || die 1 "Can't rename $tmp."
    printf '%s\t%s\t%s\n' "$(basename "$final")" "$size" "$sha" >> "$list.done"
  done < "$list"
  if [ "$MODE" = cloud ]; then
    while IFS=$'\t' read -r f _ _; do mv -f "$OUT/$f" "$PUBLISH/$f" || die 1 "Can't move $f into $PROVIDER."; done < "$list.done"
  fi
  cat "$list.done" >> "$OUT/.parts.tsv"
  rm -f "$list" "$list.done"
  if [ -s "$errlog" ]; then
    warn "tar skipped some files in $name (list in $errlog). Everything else is saved."
    TAR_WARNINGS+=("$errlog")
  else
    rm -f "$errlog"
  fi
  manifest_write no
}

# restore.sh in the backup folder as a shell word, with ~ for the home folder (same on the new Mac for cloud folders)
restore_command() {
  # shellcheck disable=SC2088  # ~ stays literal: the new Mac expands it
  case "$BACKUP_DIR" in
    "$HOME"/*) printf "~/%q/restore.sh" "${BACKUP_DIR#"$HOME"/}" ;;
    *) printf "%q/restore.sh" "$BACKUP_DIR" ;;
  esac
}

# --- Main -------------------------------------------------------------------

case "$ACTION" in
  places) list_places; exit 0 ;;
  sources)
    mkdir -p "$STATE_DIR/run"; : > "$SIZES.tmp"
    build_excludes settings
    items=(); for i in "${SETTINGS_ITEMS[@]}"; do [ -e "$HOME/$i" ] && items+=("$i"); done
    printf 'settings\tsettings\t%s\t1\tKeys, shell, git and editor settings, Claude Code. Always included.\n' "$(size_kb "${items[@]}")"
    build_excludes other
    while IFS= read -r root; do
      sum=0
      while IFS= read -r u; do
        [ "$u" = .DS_Store ] && continue
        kb=$(size_kb "$root/$u"); sum=$((sum + kb)); printf '%s\t%s\n' "$root/$u" "$kb" >> "$SIZES.tmp"
      done < <(ls -A "$HOME/$root")
      printf 'projects\t%s\t%s\t1\tEvery folder in it, with uncommitted work\n' "$root" "$sum"
    done < <(existing_project_roots)
    shown=" $(existing_project_roots | tr '\n' ' ') "
    for d in "$HOME"/*/; do
      i=$(basename "$d")
      case "$shown" in *" $i "*) continue ;; esac
      case "$i" in Library | Applications | Public | mac-migration-*) continue ;; esac
      is_self "$i" && continue
      on=0; for p in "${PERSONAL_ITEMS[@]}"; do [ "$p" = "$i" ] && on=1; done
      if cloud_only "$i"; then
        printf 'folder\t%s\t0\t0\tSynced by iCloud or another cloud drive, so it is left out\n' "$i"
        continue
      fi
      kb=$(size_kb "$i"); printf '%s\t%s\n' "$i" "$kb" >> "$SIZES.tmp"
      printf 'folder\t%s\t%s\t%s\t\n' "$i" "$kb" "$on"
    done
    mv -f "$SIZES.tmp" "$SIZES"
    exit 0 ;;
esac

# --add, --redo and --status work on the backup that is already there
find_mode=""
{ [ "$ACTION" = status ] || [ ${#ADD_ITEMS[@]} -gt 0 ] || [ -n "$REDO" ]; } && find_mode=existing
if ! resolve_destination "$find_mode"; then
  [ "$ACTION" = status ] && { echo "none"; exit 0; }
  die 1 "There is no backup of this Mac in $DEST yet."
fi

if [ "$ACTION" = status ]; then
  m="$BACKUP_DIR/MANIFEST.txt"
  [ -f "$m" ] || m="$OUT/MANIFEST.txt"
  plan="$OUT/plan.txt"; [ -f "$plan" ] || plan="$BACKUP_DIR/plan.txt"
  if [ ! -f "$plan" ]; then echo "none"; exit 0; fi
  printf 'folder\t%s\nmode\t%s\nformat\t%s\n' "$BACKUP_DIR" "$MODE" "$(manifest_format "$m")"
  [ -f "$m" ] && printf 'backup\t%s\nversion\t%s\ncomplete\t%s\n' "$(manifest_field "$m" backup)" "$(manifest_field "$m" version)" "$(manifest_field "$m" complete)"
  while IFS=$'\t' read -r name kb _; do
    if grep -qE "  $name\.tar\.gz\.enc(\.[0-9]{3})?$" "$m" 2>/dev/null; then s="done"; else s=pending; fi
    printf 'archive\t%s\t%s\t%s\n' "$name" "$s" "$kb"
  done < "$plan"
  exit 0
fi

if [ "$ACTION" = plan ]; then
  log "Plan (nothing is created in a dry run):"
  plan_tmp="$(mktemp)"
  if [ -f "$OUT/plan.txt" ]; then cp "$OUT/plan.txt" "$plan_tmp"; else build_plan > "$plan_tmp"; fi
  add_extras "$plan_tmp"
  print_plan "$plan_tmp"
  [ -n "$PART_MB" ] && echo "    Archives are split into parts of $PART_MB MB."
  echo "    Goes to: $BACKUP_DIR"
  rm -f "$plan_tmp"
  exit 0
fi

lock_acquire backup
trap 'rc=$?; rm -f "$OUT"/*.part "$OUT"/.list-* "$OUT"/.count-* "$OUT"/.sockets-* 2>/dev/null; finish $rc' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start_log backup
stay_awake backup
mkdir -p "$OUT" "$STATE_DIR" || die 1 "Can't create $OUT."
[ "$MODE" = cloud ] && { mkdir -p "$PUBLISH" || die 1 "Can't create $PUBLISH."; }
echo "Backup folder: $BACKUP_DIR"

if [ -f "$OUT/.done" ] || { [ -f "$OUT/MANIFEST.txt" ] && [ "$(manifest_format "$OUT/MANIFEST.txt")" = 1 ]; }; then
  die 1 "$OUT has a backup made by an older mac-migrate. Finish or extend it with that version, or start a new backup in another folder."
fi
# The staging folder of a cloud backup was deleted: continue from what the cloud folder has
if [ "$MODE" = cloud ] && [ ! -f "$OUT/plan.txt" ] && [ -f "$PUBLISH/plan.txt" ]; then
  cp -X "$PUBLISH/plan.txt" "$PUBLISH/password-check.enc" "$PUBLISH/MANIFEST.txt" "$OUT/" || die 1 "Can't read the backup in $PUBLISH."
  RESUMED=1
fi

if [ -f "$OUT/password-check.enc" ]; then
  read_password existing
  pwcheck_ok "$OUT/password-check.enc" || die "$E_PASSWORD" "That isn't the password used for the earlier archives."
else
  read_password new
  make_pwcheck "$OUT/password-check.enc" || die 1 "Can't write to $OUT."
fi
if [ "$RESUMED" = 1 ]; then
  manifest_verify "$OUT/MANIFEST.txt" || die 1 "MANIFEST.txt in $PUBLISH doesn't match the password."
  grep -vE '^#|  (plan\.txt|password-check\.enc)$' "$OUT/MANIFEST.txt" | awk '{printf "%s\t%s\t%s\n", $3, $2, $1}' > "$OUT/.parts.tsv"
  manifest_field "$OUT/MANIFEST.txt" backup > "$OUT/.backup-id"
fi
[ -s "$OUT/.backup-id" ] || uuidgen > "$OUT/.backup-id"
BACKUP_ID=$(cat "$OUT/.backup-id")

copy_tool "${PUBLISH:-$OUT}"

if [ ! -f "$OUT/plan.txt" ]; then
  check_access "${PERSONAL_ITEMS[@]}" "${PROJECT_ROOTS[@]}" "${ADD_ITEMS[@]}"
  printf '%s\n' "$HOME" > "$STATE_DIR/source-home.txt"
  included_roots > "$STATE_DIR/project-roots.txt"
  log "Saving a list of repos, apps and tools"
  write_inventory
  log "Building the software package for the new Mac"
  /bin/bash "$SCRIPT_DIR/make-setup.sh" "$STATE_DIR/new-mac-setup" || warn "The software package is incomplete (see above). The backup continues."
  copy_tool "${PUBLISH:-$OUT}"
  log "Measuring folders"
  status measure "" 0 0 0 -1 "Measuring folders"
  build_plan > "$OUT/plan.txt.tmp" && mv "$OUT/plan.txt.tmp" "$OUT/plan.txt"
else
  # project folders created since the plan was made aren't in it
  new=()
  while IFS= read -r root; do
    while IFS= read -r u; do
      [ "$u" = .DS_Store ] && continue
      is_self "$root/$u" && continue
      awk -F'\t' -v i="$root/$u" '{for (k = 3; k <= NF; k++) if ($k == i) f = 1} END {exit !f}' "$OUT/plan.txt" || new+=("$root/$u")
    done < <(ls -A "$HOME/$root")
  done < <(existing_project_roots)
  if [ ${#new[@]} -gt 0 ]; then
    warn "Folders created since this backup started aren't in it: ${new[*]}. Add them with: ./backup.sh --add ${new[*]}"
  fi
fi
if [ ${#ADD_ITEMS[@]} -gt 0 ]; then
  check_access "${ADD_ITEMS[@]}"
  add_extras "$OUT/plan.txt"
fi

if [ -n "$REDO" ]; then
  cut -f1 "$OUT/plan.txt" | grep -qx -- "$REDO" || die 1 "There is no archive called $REDO (see plan.txt)."
  forget_archive "$REDO"
fi
manifest_write no

export M_TOTAL M_BEFORE=0 M_STATUS=""
[ -n "$MIG_RUN" ] && M_STATUS="$MIG_RUN/status"
M_TOTAL=$(awk -F'\t' '{s += $2} END {print s + 0}' "$OUT/plan.txt")
if [ "$MODE" = cloud ] && [ "$M_TOTAL" -gt $((700 * 1024 * 1024)) ]; then
  warn "This backup is $(gb "$M_TOTAL") before compression. $PROVIDER may limit uploads per day (Google Drive: 750 GB), so uploading can take more than a day."
fi
[ -n "$PART_MB" ] && echo "    Archives are split into parts of $PART_MB MB."

log "Creating archives in $BACKUP_DIR"
SKIPPED=(); TAR_WARNINGS=()
while IFS=$'\t' read -r -a row -u 3; do
  make_archive "${row[@]}"
  M_BEFORE=$((M_BEFORE + row[1]))
done 3< "$OUT/plan.txt"

complete=yes
while IFS=$'\t' read -r name _; do archive_done "$name" || complete=no; done < "$OUT/plan.txt"
manifest_write "$complete"
copy_tool "${PUBLISH:-$OUT}"

if [ "$MODE" = cloud ]; then
  log "Waiting for $PROVIDER to finish uploading"
  files=(); while IFS= read -r f; do files+=("$f"); done < <(find "$PUBLISH" -type f ! -name '.*')
  wait_uploaded "${files[@]}"
  echo "    Everything is uploaded."
fi

total_kb=$(awk -F'\t' '{s += $2} END {print int(s / 1024)}' "$OUT/.parts.tsv")
parts=$(wc -l < "$OUT/.parts.tsv" | tr -d ' ')
where=$BACKUP_DIR
# shellcheck disable=SC2088  # ~ is for display
case "$where" in "$HOME"/*) where="~/${where#"$HOME"/}" ;; esac
if [ ${#SKIPPED[@]} -gt 0 ]; then
  log "Done, but ${#SKIPPED[@]} archive(s) didn't fit: ${SKIPPED[*]}"
  echo "    Free up space (./cleanup.sh) or choose another destination, then run the backup again: it packs only what's missing."
else
  log "Done: $parts file(s), $(gb "$total_kb") in $where"
fi
[ ${#TAR_WARNINGS[@]} -gt 0 ] && echo "    Some files couldn't be read: ${TAR_WARNINGS[*]}"
case "$MODE" in
  local) echo "    Copy everything in that folder to your cloud drive or external disk." ;;
  folder) echo "    Eject the disk before you unplug it." ;;
esac
echo "    On the new Mac, new-mac-setup/setup.sh installs your apps and tools, also before the restore."
if [ "$MODE" = cloud ]; then
  echo "    To restore, sign in to $PROVIDER on the new Mac and run in Terminal:"
else
  echo "    To restore, put the folder on the new Mac and run its restore.sh in Terminal, for example:"
fi
echo "      /bin/bash $(restore_command)"
echo "    Keep this Mac as it is until the new one works."
event folder "$BACKUP_DIR"
event mode "$MODE"
[ -n "$PROVIDER" ] && event provider "$PROVIDER"
event restore "/bin/bash $(restore_command)"
status "done" "" "$M_TOTAL" "$M_TOTAL" 0 0 "$parts file(s), $(gb "$total_kb") in $where"
event "done" "$parts file(s), $(gb "$total_kb") in $where"
[ ${#SKIPPED[@]} -gt 0 ] && FAIL_REASON="Archives that didn't fit: ${SKIPPED[*]}" && exit "$E_SPACE"
exit 0
