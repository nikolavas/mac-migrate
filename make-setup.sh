#!/bin/bash
# Usage: ./make-setup.sh [output-dir]   writes Brewfile, setup.sh and README.md for the new Mac
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$HOME/.mac-migration/new-mac-setup}"
SETUP_SKIP_APPS=()
if [ -n "$MIGRATE_CONFIG" ]; then CONFIGS=("$MIGRATE_CONFIG"); else CONFIGS=("$SCRIPT_DIR/config.sh" "$HOME/.mac-migration/config.sh"); fi
for c in "${CONFIGS[@]}"; do
  # shellcheck source=/dev/null
  [ -f "$c" ] && . "$c"
done
APPS_PATH="${APPS_PATH:-/Applications:$HOME/Applications}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT_DIR"

have_brew() { [ -z "$SKIP_BREW" ] && command -v brew >/dev/null; }
quote_list() { sed 's/[\\"$`]/\\&/g; s/.*/"&"/' "$1" | tr '\n' ' '; }

: > "$TMP/dump"
printf 'none\tnone\tnone\t-\t-\n' > "$TMP/status.tsv"
if have_brew; then
  if ! brew bundle dump --file="$TMP/dump" --force >/dev/null 2>&1; then
    echo "    Warning: brew bundle dump failed, so the Brewfile lacks your Homebrew formulae and casks."
    warned=1
  fi
  brew info --json=v2 --installed 2>/dev/null | /usr/bin/perl -CO -MJSON::PP -0777 -ne '
    my $j = eval { decode_json($_) } or exit 0;
    for my $k (["brew", "formulae", "name"], ["cask", "casks", "token"]) {
      for my $p (@{ $j->{$k->[1]} || [] }) {
        next unless $p->{deprecated} || $p->{disabled};
        my $why = $p->{disable_reason} // $p->{deprecation_reason} // "-";
        my $repl = $p->{deprecation_replacement_cask} // $p->{deprecation_replacement_formula} // "-";
        print join("\t", $k->[0], $p->{$k->[2]}, $p->{disabled} ? "disabled" : "deprecated", $why, $repl), "\n";
      }
    }' >> "$TMP/status.tsv"
fi

idx="${CASK_INDEX:-$TMP/cask.json}"
if [ -z "$CASK_INDEX" ]; then
  curl -fsSL --retry 3 --max-time 120 https://formulae.brew.sh/api/cask.json -o "$idx" 2>/dev/null || : > "$idx"
fi
# casks.tsv: kind(app|bid)<TAB>key<TAB>token<TAB>deprecated<TAB>disabled<TAB>replacement
/usr/bin/perl -CO -MJSON::PP -0777 -ne '
  my $j = eval { decode_json($_) } or exit 0;
  for my $c (@$j) {
    my $repl = $c->{deprecation_replacement_cask} // "-";
    my @meta = ($c->{token}, $c->{deprecated} ? 1 : 0, $c->{disabled} ? 1 : 0, $repl);
    for my $a (@{ $c->{artifacts} || [] }) {
      next unless ref $a eq "HASH";
      for my $x (@{ $a->{app} || [] }) {
        my $n = ref $x eq "HASH" ? $x->{target} : $x;
        next unless defined $n;
        $n =~ s{.*/}{};
        print join("\t", "app", $n, @meta), "\n";
      }
      for my $u (@{ $a->{uninstall} || [] }) {
        next unless ref $u eq "HASH" && defined $u->{quit};
        print join("\t", "bid", $_, @meta), "\n" for ref $u->{quit} ? @{ $u->{quit} } : ($u->{quit});
      }
    }
  }' "$idx" > "$TMP/casks.tsv"
if [ ! -s "$TMP/casks.tsv" ]; then
  echo "    Warning: couldn't load the Homebrew cask list (offline?), so apps are listed to install by hand."
  warned=1
fi

# Prefers stable casks (no @) that aren't disabled; prints token<TAB>deprecated<TAB>disabled<TAB>replacement
lookup() {
  awk -F'\t' -v k="$1" -v v="$2" '$1 == k && $2 == v {print (index($3, "@") ? 1 : 0) $5 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "$TMP/casks.tsv" |
    sort | head -1 | cut -f2-
}

: > "$TMP/cask.add"; : > "$TMP/mas.add"; : > "$TMP/manual.txt"; : > "$TMP/notes.txt"; : > "$TMP/company.txt"; : > "$TMP/toolbox.txt"
skip_list="$(printf '%s\n' "${SETUP_SKIP_APPS[@]}")"
IFS=: read -r -a app_dirs <<< "$APPS_PATH"
toolbox=0
for dir in "${app_dirs[@]}"; do [ -d "$dir/JetBrains Toolbox.app" ] && toolbox=1; done
jetbrains_ides='^(intellij-idea|intellij-idea-ce|pycharm|pycharm-ce|webstorm|goland|clion|datagrip|dataspell|phpstorm|rubymine|rustrover|rider|aqua|writerside|fleet)(@.*)?$'
for dir in "${app_dirs[@]}"; do
  for app in "$dir"/*.app; do
    [ -d "$app" ] || continue
    name="$(basename "$app" .app)"
    if printf '%s\n' "$skip_list" | grep -qxF -- "$name"; then echo "$name" >> "$TMP/company.txt"; continue; fi
    [ "$(defaults read "$app/Contents/Info" LSBackgroundOnly 2>/dev/null)" = 1 ] && continue
    bid="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    if [ -d "$app/Contents/_MASReceipt" ]; then
      id="$(mdls -raw -name kMDItemAppStoreAdamID "$app" 2>/dev/null)"
      case "$id" in
        '' | *[!0-9]*) echo "$name (App Store)" >> "$TMP/manual.txt" ;;
        *) grep -q "id: $id\$" "$TMP/dump" || printf 'mas "%s", id: %s\n' "$name" "$id" >> "$TMP/mas.add" ;;
      esac
      continue
    fi
    case "$bid" in com.apple.* | com.google.drivefs.shortcuts.*) continue ;; esac
    pick="$(lookup app "$name.app")"
    [ -z "$pick" ] && [ -n "$bid" ] && pick="$(lookup bid "$bid")"
    [ -z "$pick" ] && pick="$(lookup app "$(printf '%s' "$name" | sed -E 's/[- ]?v?[0-9]+(\.[0-9]+)*$//').app")"
    if [ -z "$pick" ]; then echo "$name" >> "$TMP/manual.txt"; continue; fi
    IFS=$'\t' read -r token dep dis repl <<< "$pick"
    if [ "$toolbox" = 1 ] && printf '%s' "$token" | grep -qE "$jetbrains_ides"; then echo "$name" >> "$TMP/toolbox.txt"; continue; fi
    if [ "$repl" != - ] && { [ "$dep" = 1 ] || [ "$dis" = 1 ]; }; then
      echo "$name: the $token cask is discontinued, replaced by $repl" >> "$TMP/notes.txt"
      token="$repl"; dep=0; dis=0
    fi
    if [ "$dis" = 1 ]; then echo "$name (its Homebrew cask $token is disabled)" >> "$TMP/manual.txt"; continue; fi
    grep -q "^cask \"$token\"" "$TMP/dump" "$TMP/cask.add" && continue
    [ "$dep" = 1 ] && echo "# $name: deprecated in Homebrew, may stop installing" >> "$TMP/cask.add"
    echo "cask \"$token\"" >> "$TMP/cask.add"
  done
done

{
  echo "# Generated by mac-migrate on $(date '+%Y-%m-%d') from $(scutil --get ComputerName 2>/dev/null || hostname)"
  echo "# Install everything with: bash setup.sh"
  echo
  awk -F'\t' '
    NR == FNR { st[$1 " " $2] = $3; why[$1 " " $2] = $4; rep[$1 " " $2] = $5; next }
    /^npm "/ { next }
    {
      key = ""
      if (match($0, /^(brew|cask) "[^"]+"/)) { k = substr($0, 1, 4); n = $0; sub(/^(brew|cask) "/, "", n); sub(/".*/, "", n); key = k " " n }
      if (key in st) {
        r = (why[key] != "-") ? " (" why[key] ")" : ""
        if (st[key] == "disabled") { print "# disabled in Homebrew" r; print "# " $0; next }
        if (rep[key] != "-") { print "# " n " is deprecated, replaced by " rep[key]; print "# " $0; print k " \"" rep[key] "\""; next }
        print "# deprecated in Homebrew" r ", may stop installing"
      }
      print
    }' "$TMP/status.tsv" "$TMP/dump"
  if [ -s "$TMP/cask.add" ]; then echo; echo "# Apps found in $(echo "$APPS_PATH" | sed 's/:/ and /g')"; cat "$TMP/cask.add"; fi
  if [ -s "$TMP/mas.add" ]; then
    echo; echo "# Mac App Store: sign in to the App Store app first"
    grep -q '^brew "mas"' "$TMP/dump" || echo 'brew "mas"'
    cat "$TMP/mas.add"
  fi
} > "$OUT_DIR/Brewfile"

node_major=""
if { [ -s "$HOME/.nvm/nvm.sh" ] || grep -q '^brew "nvm"' "$TMP/dump"; } && command -v node >/dev/null; then
  node_major="$(node -v | sed 's/^v//; s/\..*//')"
fi
: > "$TMP/npm"; : > "$TMP/uv"; : > "$TMP/pipx"
command -v npm >/dev/null && npm ls -g --depth=0 --json 2>/dev/null | /usr/bin/perl -CO -MJSON::PP -0777 -ne '
  my $j = eval { decode_json($_) } or exit 0;
  print "$_\n" for grep { $_ ne "npm" && $_ ne "corepack" } sort keys %{ $j->{dependencies} || {} }' > "$TMP/npm"
command -v uv >/dev/null && uv tool list 2>/dev/null | awk '/^[^- ]/ {print $1}' > "$TMP/uv"
command -v pipx >/dev/null && pipx list --short 2>/dev/null | awk '{print $1}' > "$TMP/pipx"
claude_native=0
[ -x "$HOME/.local/bin/claude" ] && ! grep -q '^cask "claude-code' "$OUT_DIR/Brewfile" && claude_native=1

{
  echo '#!/bin/bash'
  echo '# Usage: bash setup.sh   (safe to run again)'
  echo 'set -o pipefail'
  echo "NODE_MAJOR=\"$node_major\""
  echo "NPM_GLOBALS=($(quote_list "$TMP/npm"))"
  echo "UV_TOOLS=($(quote_list "$TMP/uv"))"
  echo "PIPX_TOOLS=($(quote_list "$TMP/pipx"))"
  echo "CLAUDE_NATIVE=$claude_native"
  echo "MANUAL=($(quote_list "$TMP/manual.txt"))"
  echo "TOOLBOX=($(quote_list "$TMP/toolbox.txt"))"
  echo "COMPANY=($(quote_list "$TMP/company.txt"))"
  cat <<'EOF'
DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

if ! xcode-select -p >/dev/null 2>&1; then
  step "Installing the Xcode Command Line Tools. Finish the dialog, then run this script again."
  xcode-select --install
  exit 0
fi

BREW=/opt/homebrew/bin/brew
[ "$(uname -m)" = arm64 ] || BREW=/usr/local/bin/brew
if [ ! -x "$BREW" ]; then
  step "Installing Homebrew. It asks for an administrator password."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
fi
eval "$("$BREW" shellenv)"
grep -qs 'brew shellenv' "$HOME/.zprofile" || echo "eval \"\$($BREW shellenv)\"" >> "$HOME/.zprofile"

step "Installing command-line tools, apps, App Store apps and editor extensions"
echo "    App Store apps need you signed in to the App Store app. If they fail, sign in and run this again."
brew bundle --file="$DIR/Brewfile" || echo "    Some items failed (see above). Fix them and run this script again."

if [ -n "$NODE_MAJOR" ]; then
  step "Node.js $NODE_MAJOR with nvm"
  brew list nvm >/dev/null 2>&1 || brew install nvm
  export NVM_DIR="$HOME/.nvm"
  mkdir -p "$NVM_DIR"
  # shellcheck source=/dev/null
  . "$(brew --prefix nvm)/nvm.sh"
  nvm install "$NODE_MAJOR" && nvm alias default "$NODE_MAJOR"
fi
if [ ${#NPM_GLOBALS[@]} -gt 0 ] && command -v npm >/dev/null; then
  step "Global npm packages"
  npm install -g "${NPM_GLOBALS[@]}"
fi
if [ ${#UV_TOOLS[@]} -gt 0 ] && command -v uv >/dev/null; then
  step "uv tools"
  for t in "${UV_TOOLS[@]}"; do uv tool install "$t"; done
fi
if [ ${#PIPX_TOOLS[@]} -gt 0 ] && command -v pipx >/dev/null; then
  step "pipx tools"
  for t in "${PIPX_TOOLS[@]}"; do pipx install "$t"; done
fi
if [ "$CLAUDE_NATIVE" = 1 ]; then
  step "Claude Code"
  if [ -x "$HOME/.local/bin/claude" ]; then echo "    already installed"; else curl -fsSL https://claude.ai/install.sh | bash; fi
fi

step "Done."
if [ ${#COMPANY[@]} -gt 0 ]; then
  echo "From your company's self-service portal:"
  printf '  - %s\n' "${COMPANY[@]}"
fi
if [ ${#TOOLBOX[@]} -gt 0 ]; then
  echo "Through JetBrains Toolbox:"
  printf '  - %s\n' "${TOOLBOX[@]}"
fi
if [ ${#MANUAL[@]} -gt 0 ]; then
  echo "Yourself, from the vendor's website (no Homebrew cask found):"
  printf '  - %s\n' "${MANUAL[@]}"
fi
echo "Then sign in to your apps and turn on sync in your browsers and editors."
EOF
} > "$OUT_DIR/setup.sh"
chmod +x "$OUT_DIR/setup.sh"

count() { grep -c "^$1 " "$OUT_DIR/Brewfile" | tr -d ' '; }
{
  echo "# New Mac setup"
  echo
  echo "Generated by mac-migrate on $(date '+%Y-%m-%d') from the apps and tools on $(scutil --get ComputerName 2>/dev/null || hostname)."
  echo
  echo "Run \`bash setup.sh\` on the new Mac. Homebrew needs an administrator password once, and App Store apps need you signed in to the App Store app. The script is safe to run again."
  echo
  echo "Before you run it, open the Brewfile and remove anything you don't want, such as apps your company installs for you."
  echo
  echo "## What it installs"
  echo
  echo "- $(count brew) command-line tools, $(count cask) apps, $(count mas) App Store apps, $(count vscode) VS Code extensions (see Brewfile)"
  [ -n "$node_major" ] && echo "- Node.js $node_major with nvm"
  [ -s "$TMP/npm" ] && echo "- Global npm packages: $(tr '\n' ' ' < "$TMP/npm")"
  [ -s "$TMP/uv" ] && echo "- uv tools: $(tr '\n' ' ' < "$TMP/uv")"
  [ -s "$TMP/pipx" ] && echo "- pipx tools: $(tr '\n' ' ' < "$TMP/pipx")"
  [ "$claude_native" = 1 ] && echo "- Claude Code (native installer)"
  if [ -s "$TMP/company.txt" ]; then
    echo; echo "## From your company's self-service portal"; echo
    echo "Left out of the Brewfile because SETUP_SKIP_APPS in config.sh lists them:"
    echo; sed 's/^/- /' "$TMP/company.txt"
  fi
  if [ -s "$TMP/toolbox.txt" ]; then
    echo; echo "## Through JetBrains Toolbox"; echo
    sed 's/^/- /' "$TMP/toolbox.txt"
  fi
  if [ -s "$TMP/manual.txt" ]; then
    echo; echo "## Install yourself"; echo
    echo "No Homebrew cask was found for these. Get them from the vendor's website, or from your company's self-service portal:"
    echo; sed 's/^/- /' "$TMP/manual.txt"
  fi
  if [ -s "$TMP/notes.txt" ]; then echo; echo "## Notes"; echo; sed 's/^/- /' "$TMP/notes.txt"; fi
} > "$OUT_DIR/README.md"

echo "    Saved $OUT_DIR (Brewfile, setup.sh, README.md)"
[ -z "$warned" ]
