#!/bin/bash
# Usage: bash /path/to/archives/restore.sh
set -o pipefail

SRC="${SRC:-$(cd "$(dirname "$0")" && pwd)}"
OPENSSL=/usr/bin/openssl
STATE_DIR="$HOME/.mac-migration"
RUN_DIR="$HOME/.mac-migration-restore"
DONE="$RUN_DIR/restored.txt"
REPLACED="$RUN_DIR/replaced-$(date +%Y%m%d-%H%M%S)"
shopt -s nullglob

log() { printf '\n==> %s\n' "$*"; }
decrypt() { "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:MIG_PASS "$@"; }

if [ -z "$FORCE" ] && pgrep -xq claude; then
  echo "Close Claude Code first. It rewrites ~/.claude.json while it runs."; exit 1
fi

files=("$SRC"/*.tar.gz.enc)
[ ${#files[@]} -eq 0 ] && { echo "No *.tar.gz.enc files in $SRC."; exit 1; }
mkdir -p "$RUN_DIR"

if [ -z "$MIG_PASS" ]; then read -rs -p "Archive password: " MIG_PASS; echo; fi
export MIG_PASS
# decrypted gzip starts with 1f 8b
magic=$(decrypt -in "${files[0]}" 2>/dev/null | head -c 2 | od -An -tx1 | tr -d ' \n')
[ "$magic" = 1f8b ] || { echo "Wrong password."; exit 1; }

log "Unpacking into $HOME"
failed=0
for f in "${files[@]}"; do
  name=$(basename "$f")
  if grep -qx "$name" "$DONE" 2>/dev/null; then echo "    $name: already restored"; continue; fi
  if [ -f "$SRC/MANIFEST.txt" ]; then
    want=$(awk -v n="$name" '$2 == n {print $1}' "$SRC/MANIFEST.txt" | tail -1)
    if [ -n "$want" ] && [ "$want" != "$(shasum -a 256 "$f" | cut -d' ' -f1)" ]; then
      echo "    $name: damaged or incomplete download. Download it again."; failed=1; continue
    fi
  fi
  if [ -f "$SRC/plan.txt" ]; then
    awk -F'\t' -v n="${name%.tar.gz.enc}" '$1 == n {for (i = 3; i <= NF; i++) print $i}' "$SRC/plan.txt" |
    while IFS= read -r item; do
      if [ -e "$HOME/$item" ] || [ -L "$HOME/$item" ]; then
        mkdir -p "$REPLACED/$(dirname "$item")" && mv "$HOME/$item" "$REPLACED/$item" && echo "    moved existing ~/$item aside"
      fi
    done
  fi
  echo "    $name"
  decrypt -in "$f" | tar -xpzf - -C "$HOME"
  st=("${PIPESTATUS[@]}")
  if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then echo "    $name: could not be unpacked fully."; failed=1; continue; fi
  echo "$name" >> "$DONE"
done

if [ -d "$HOME/.ssh" ]; then
  chmod 700 "$HOME/.ssh"
  find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} +
fi
[ -d "$HOME/.gnupg" ] && chmod -R go-rwx "$HOME/.gnupg"

OLD_HOME="${OLD_HOME:-$(head -1 "$STATE_DIR/source-home.txt" 2>/dev/null)}"
if [ -n "$OLD_HOME" ] && [ "$OLD_HOME" != "$HOME" ]; then
  log "Changing $OLD_HOME to $HOME"
  # Claude Code names project dirs after the path, non-alphanumerics replaced by -
  p="$HOME/.claude/projects"
  old_slug=$(printf '%s' "$OLD_HOME" | sed 's/[^A-Za-z0-9]/-/g')
  new_slug=$(printf '%s' "$HOME" | sed 's/[^A-Za-z0-9]/-/g')
  for d in "$p/$old_slug"*; do
    dest="$p/$new_slug${d#"$p/$old_slug"}"
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
  if [ ${#targets[@]} -gt 0 ]; then
    grep -rlIF "$OLD_HOME" "${targets[@]}" 2>/dev/null | while IFS= read -r f; do
      sed -i '' "s#$OLD_HOME#$HOME#g" "$f" && echo "    updated ${f#"$HOME"/}"
    done
    left=$(grep -rlIF "$OLD_HOME" "${targets[@]}" 2>/dev/null)
    [ -n "$left" ] && { echo "    Still contains the old path:"; echo "$left" | sed 's/^/      /'; }
  fi
fi

log "Files restored."
[ "$failed" -ne 0 ] && echo "    Some archives failed (see above). Fix them and run this script again."
echo
echo "Next steps:"
echo "  - Open a new Terminal window so your restored shell settings load."
if [ -f "$STATE_DIR/Brewfile" ]; then
  echo "  - Install Homebrew (https://brew.sh), then:  brew bundle --file=~/.mac-migration/Brewfile"
fi
if [ -x /opt/homebrew/bin/brew ] && ! grep -qs 'brew shellenv' "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; then
  echo "  - Your restored shell files don't load Homebrew. Add this line to ~/.zprofile:"
  echo "      eval \"\$(/opt/homebrew/bin/brew shellenv)\""
fi
echo "  - Reinstall runtimes and global tools (nvm, pyenv, npm -g, pipx, uv tools): see ~/.mac-migration/inventory.md"
echo "  - Log in again to command-line tools that keep tokens in the Keychain: gh, gcloud, az, aws sso, and so on."
echo "  - Sign in to your browsers and IDEs and turn on sync."
echo "  - Reinstall project dependencies (npm install, uv sync, ...) when you open a project."
echo "  - Delete the archives from your cloud drive once everything works."
[ -d "$REPLACED" ] && echo "  - Files the restore moved aside are in $REPLACED"
exit 0
