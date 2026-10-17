#!/bin/bash
# Usage: ./cleanup.sh                         show what can be freed and choose what to clean
#        ./cleanup.sh --list                  the same as TSV: id, label, size_kb, tier, default, note
#        ./cleanup.sh --clean ID... [--dry-run]  clean those items without asking (IDs from --list)
# Offers caches and build output that tools recreate by themselves, nothing else. Tiers:
#   safe       rebuilt automatically, preselected
#   download   downloaded again when needed: big, and slow to get back
#   projects   dependency folders in your projects: reinstall with npm install, uv sync, ...
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

PROJECT_ROOTS=(proj projects Projects code Code dev Developer src repos workspace git GitHub)
CLEANUP_KEEP=()
if [ -n "$MIGRATE_CONFIG" ]; then CONFIGS=("$MIGRATE_CONFIG"); else CONFIGS=("$SCRIPT_DIR/config.sh" "$STATE_DIR/config.sh"); fi
for c in "${CONFIGS[@]}"; do
  # shellcheck source=/dev/null
  [ -f "$c" ] && . "$c"
done

ACTION=ask; DRY=0; IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) ACTION=list; shift ;;
    --clean) ACTION=clean; shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do IDS+=("$1"); shift; done ;;
    --dry-run) DRY=1; shift ;;
    --version) echo "mac-migrate $MM_VERSION"; exit 0 ;;
    -h | --help) sed -n "2,8p" "$0" | sed "s/^# \{0,1\}//"; exit 0 ;;
    *) echo "Unknown option: $1 (see ./cleanup.sh --help)"; exit 1 ;;
  esac
done
mm_env
L="$HOME/Library"

# id<TAB>tier<TAB>label<TAB>apps that must be closed or -<TAB>tool for the official command or -<TAB>path...
# Apps are exact process names, or f:pattern for a match on the whole command line.
catalog() {
  local ide='idea pycharm webstorm goland rider clion datagrip phpstorm rubymine rustrover studio'
  printf '%s\n' \
    "homebrew	safe	Homebrew downloads	-	brew	$L/Caches/Homebrew" \
    "npm	safe	npm cache	-	npm	$HOME/.npm/_cacache" \
    "pnpm	safe	pnpm store, unused packages	-	pnpm	$L/pnpm/store	$HOME/.pnpm-store	$HOME/.local/share/pnpm/store" \
    "yarn	safe	Yarn cache	-	-	$L/Caches/Yarn	$HOME/.yarn/berry/cache" \
    "pip	safe	pip cache	-	-	$L/Caches/pip" \
    "uv	safe	uv cache	-	uv	$HOME/.cache/uv" \
    "go-build	safe	Go build cache	-	go	$L/Caches/go-build" \
    "node-gyp	safe	node-gyp headers	-	-	$L/Caches/node-gyp" \
    "cocoapods	safe	CocoaPods cache	-	-	$L/Caches/CocoaPods" \
    "xcode-derived	safe	Xcode build data (DerivedData)	Xcode	-	$L/Developer/Xcode/DerivedData" \
    "jetbrains	safe	JetBrains IDE caches	$ide	-	$L/Caches/JetBrains" \
    "logs	safe	Log files	-	-	$L/Logs" \
    "xcode-devicesupport	download	Xcode device support files	Xcode	-	$L/Developer/Xcode/iOS DeviceSupport	$L/Developer/Xcode/watchOS DeviceSupport	$L/Developer/Xcode/tvOS DeviceSupport" \
    "gradle	download	Gradle dependency cache	f:GradleDaemon	-	$HOME/.gradle/caches" \
    "maven	download	Maven repository	-	-	$HOME/.m2/repository" \
    "go-mod	download	Go module cache	-	go	$HOME/go/pkg/mod" \
    "cargo	download	Cargo registry cache	-	-	$HOME/.cargo/registry/cache	$HOME/.cargo/registry/src" \
    "huggingface	download	Hugging Face models and datasets	-	-	$HOME/.cache/huggingface" \
    "test-browsers	download	Browsers for Playwright and Puppeteer	-	-	$L/Caches/ms-playwright	$HOME/.cache/puppeteer"
}

# Other apps' caches in ~/Library/Caches: not Apple's, not those listed above, not running apps'
other_app_caches() {
  local d n running
  running=$(lsappinfo list 2>/dev/null | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p')
  for d in "$L/Caches"/*/; do
    d=${d%/}; n=$(basename "$d")
    case "$n" in com.apple.* | Homebrew | Yarn | pip | go-build | node-gyp | CocoaPods | JetBrains | ms-playwright | pnpm) continue ;; esac
    printf '%s\n' "$running" | grep -qixF -- "$n" && continue
    printf '%s\n' "$d"
  done
}

# Dependency folders the backup leaves out anyway, found next to the file that proves what they are
project_dirs() {  # node|python|build
  local root d parent
  while IFS= read -r root; do
    [ -d "$HOME/$root" ] || continue
    find "$HOME/$root" \( -name node_modules -o -name .venv -o -name venv -o -name .next -o -name .nuxt -o -name .terraform \) \
      -type d -prune -print 2>/dev/null | while IFS= read -r d; do
      parent=$(dirname "$d")
      case "$1:$(basename "$d")" in
        node:node_modules) [ -f "$parent/package.json" ] && echo "$d" ;;
        python:.venv | python:venv) [ -f "$d/pyvenv.cfg" ] && echo "$d" ;;
        build:.next | build:.nuxt) [ -f "$parent/package.json" ] && echo "$d" ;;
        build:.terraform) [ -n "$(find "$parent" -maxdepth 1 -name '*.tf' -print -quit)" ] && echo "$d" ;;
      esac
    done
  done < <(printf '%s\n' "${PROJECT_ROOTS[@]}")
}

# Paths of one item, one per line, that exist
item_paths() {
  case "$1" in
    app-caches) other_app_caches ;;
    projects-node) project_dirs node ;;
    projects-python) project_dirs python ;;
    projects-build) project_dirs build ;;
    *) catalog | awk -F'\t' -v id="$1" '$1 == id {for (i = 6; i <= NF; i++) print $i}' | while IFS= read -r p; do [ -e "$p" ] && echo "$p"; done ;;
  esac
}

# Only real folders and files inside the home folder, not reached through a symlink, not kept in config
safe_path() {
  local p="$1" dir real k
  [ -e "$p" ] && [ ! -L "$p" ] || return 1
  dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || return 1
  real="$dir/$(basename "$p")"
  case "$real" in "$(cd "$HOME" && pwd -P)"/?*) ;; *) return 1 ;; esac
  for k in "${CLEANUP_KEEP[@]}"; do case "$p/" in "$HOME/$k/"*) return 1 ;; esac; done
  return 0
}

size_of() {  # paths on stdin
  local p s kb=0
  while IFS= read -r p; do
    safe_path "$p" || continue
    s=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
    kb=$((kb + ${s:-0}))
  done
  echo "$kb"
}

running() {
  local n
  case "$1" in
    - | "") return 1 ;;
    f:*) pgrep -f "${1#f:}" > /dev/null 2>&1 ;;
    *) for n in $1; do pgrep -xq "$n" && return 0; done; return 1 ;;
  esac
}
# What to tell the user to quit
app_name() {
  case "$1" in
    f:GradleDaemon) echo "the Gradle daemon (./gradlew --stop)" ;;
    idea*) echo "your JetBrains IDEs" ;;
    *) echo "$1" ;;
  esac
}

# TSV: id, label, size_kb, tier, default (1 = preselected), note
list_items() {
  local id tier label guard tool kb note n
  while IFS=$'\t' read -r id tier label guard tool _; do
    kb=$(item_paths "$id" | size_of)
    [ "$kb" -gt 0 ] || continue
    note=""
    running "$guard" && note="Quit $(app_name "$guard") first"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$kb" "$tier" "$( [ "$tier" = safe ] && [ -z "$note" ] && echo 1 || echo 0)" "$note"
  done < <(catalog)
  kb=$(item_paths app-caches | size_of)
  [ "$kb" -gt 0 ] && printf 'app-caches\tOther apps'"'"' caches (quit them first)\t%s\tdownload\t0\t\n' "$kb"
  for id in node python build; do
    n=$(project_dirs "$id" | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] || continue
    kb=$(project_dirs "$id" | size_of)
    case "$id" in
      node) label="node_modules in $n project(s)"; note="Reinstall with npm install when you open a project" ;;
      python) label="Python virtual environments in $n project(s)"; note="Recreate with uv sync or pip install" ;;
      build) label="Build output (.next, .nuxt, .terraform) in $n project(s)"; note="Rebuilt by the next build" ;;
    esac
    printf 'projects-%s\t%s\t%s\tprojects\t0\t%s\n' "$id" "$label" "$kb" "$note"
  done
}

clean_item() {
  local id="$1" tier label guard tool p
  IFS=$'\t' read -r _ tier label guard tool _ < <(catalog | awk -F'\t' -v id="$id" '$1 == id')
  case "$id" in
    app-caches) label="Other apps' caches" ;;
    projects-*) label="$id" ;;
    *) [ -n "$label" ] || { warn "Unknown item: $id"; return 1; } ;;
  esac
  if running "${guard:--}"; then warn "Skipped $label: quit $(app_name "$guard") first."; return 0; fi
  status clean "$id" 0 0 0 -1 "Cleaning $label"
  echo "    $label"
  # the tool's own command, when it exists, knows what is safe to drop
  if [ "$DRY" = 0 ] && [ -n "$tool" ] && [ "$tool" != - ] && command -v "$tool" > /dev/null; then
    case "$id" in
      homebrew) brew cleanup --prune=all -s > /dev/null 2>&1 && return 0 ;;
      npm) npm cache clean --force > /dev/null 2>&1 && return 0 ;;
      pnpm) pnpm store prune > /dev/null 2>&1 && return 0 ;;
      uv) uv cache clean > /dev/null 2>&1 && return 0 ;;
      go-build) go clean -cache > /dev/null 2>&1 && return 0 ;;
      go-mod) go clean -modcache > /dev/null 2>&1 && return 0 ;;
    esac
  fi
  while IFS= read -r p; do
    safe_path "$p" || { echo "      kept $p (outside the home folder, a symlink, or in CLEANUP_KEEP)"; continue; }
    if [ "$DRY" = 1 ]; then echo "      would delete $p"; continue; fi
    chmod -R u+w "$p" 2>/dev/null  # Go makes its module cache read-only
    if rm -rf "$p"; then echo "      deleted $p"; else warn "Couldn't delete all of $p"; fi
  done < <(item_paths "$id")
}

run_clean() {
  local before after id
  before=$(free_kb "$HOME")
  for id in "$@"; do clean_item "$id"; done
  after=$(free_kb "$HOME")
  if [ "$DRY" = 1 ]; then
    log "Dry run: nothing was deleted."
  else
    log "Freed $(gb $((after > before ? after - before : 0))). $(gb "$after") is free now."
    echo "    Empty the Trash in Finder to free what is in it, too."
    event "done" "Freed $(gb $((after > before ? after - before : 0)))"
  fi
}

case "$ACTION" in
  list) list_items; exit 0 ;;
  clean)
    [ ${#IDS[@]} -gt 0 ] || { echo "--clean needs item IDs (see --list)"; exit 1; }
    lock_acquire cleanup
    trap 'finish $?' EXIT
    start_log cleanup
    run_clean "${IDS[@]}"
    exit 0 ;;
esac

# Interactive: number the items, preselect the safe ones
echo "Measuring caches..."
rows=(); while IFS= read -r r; do rows+=("$r"); done < <(list_items)
[ ${#rows[@]} -gt 0 ] || { echo "Nothing to clean."; exit 0; }
chosen=()
for t in safe download projects; do
  case "$t" in
    safe) echo; echo "Rebuilt automatically:" ;;
    download) echo; echo "Downloaded again when needed (big, slow to get back):" ;;
    projects) echo; echo "In your projects (the backup leaves these out anyway):" ;;
  esac
  for i in "${!rows[@]}"; do
    IFS=$'\t' read -r id label kb tier def note <<< "${rows[$i]}"
    [ "$tier" = "$t" ] || continue
    mark=" "; [ "$def" = 1 ] && { mark="*"; chosen+=("$id"); }
    printf '  %s %2d. %-48s %10s%s\n' "$mark" $((i + 1)) "$label" "$(gb "$kb")" "${note:+  ($note)}"
  done
done
echo
read -r -p "Clean the items marked *? Press Enter, or type other numbers (e.g. 1 3 7), or n to stop: " ans
case "$ans" in
  n | N | no) echo "Nothing cleaned."; exit 0 ;;
  "") ;;
  *)
    chosen=()
    for n in $ans; do
      case "$n" in *[!0-9]*) echo "Not a number: $n"; exit 1 ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le ${#rows[@]} ] || { echo "No item $n"; exit 1; }
      chosen+=("$(cut -f1 <<< "${rows[$((n - 1))]}")")
    done ;;
esac
[ ${#chosen[@]} -gt 0 ] || { echo "Nothing selected."; exit 0; }
lock_acquire cleanup
trap 'finish $?' EXIT
start_log cleanup
run_clean "${chosen[@]}"
