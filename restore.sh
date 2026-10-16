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

items_of() { awk -F'\t' -v n="$1" '$1 == n {for (i = 3; i <= NF; i++) print $i}' "$SRC/plan.txt" 2>/dev/null; }

# Moves existing files that the staged copy replaces into $REPLACED; folders are merged, not replaced.
merge_into_home() {
  /usr/bin/perl -MFile::Find -MFile::Path=make_path -MFile::Basename -e '
    my ($stage, $home, $aside) = @ARGV;
    my ($n, $err) = (0, 0);
    my $park = sub { my $rel = shift; my $b = "$aside/$rel"; make_path(dirname($b)); rename("$home/$rel", $b) or $err++; $n++ };
    find({ no_chdir => 1, wanted => sub {
      my $rel = substr($File::Find::name, length($stage) + 1);
      return if $rel eq "";
      my $dst = "$home/$rel";
      if (-d $_ && !-l $_) {
        $park->($rel) if -l $dst || (-e $dst && !-d $dst);
        make_path($dst) unless -d $dst;
        return;
      }
      $park->($rel) if -e $dst || -l $dst;
      rename($_, $dst) or do { warn "    could not place ~/$rel: $!\n"; $err++ };
    } }, $stage);
    print "    moved $n existing file(s) aside\n" if $n;
    exit($err ? 1 : 0);' "$1" "$HOME" "$REPLACED"
}

files=("$SRC"/*.tar.gz.enc)
[ ${#files[@]} -eq 0 ] && { echo "No *.tar.gz.enc files in $SRC."; exit 1; }
mkdir -p "$RUN_DIR"
pending=()
for f in "${files[@]}"; do grep -qx "$(basename "$f")" "$DONE" 2>/dev/null || pending+=("$f"); done

touches_claude() {
  local f n
  for f in "${pending[@]}"; do
    n="$(basename "$f" .tar.gz.enc)"
    if [ -f "$SRC/plan.txt" ]; then
      items_of "$n" | grep -qE '^\.claude(\.json)?(/|$)' && return 0
    elif [ "$n" = settings ]; then
      return 0
    fi
  done
  return 1
}
claude_running=0
[ -z "$FORCE" ] && pgrep -xq claude && claude_running=1
if [ "$claude_running" = 1 ] && touches_claude; then
  echo "Close Claude Code first: this restore brings back ~/.claude and ~/.claude.json, which Claude Code rewrites while it runs."
  exit 1
fi

failed=0
if [ ${#pending[@]} -eq 0 ]; then
  log "Nothing new to restore: all ${#files[@]} archives in this folder are already restored."
else
  if [ -z "$MIG_PASS" ]; then read -rs -p "Archive password: " MIG_PASS; echo; fi
  export MIG_PASS
  # decrypted gzip starts with 1f 8b
  magic=$(decrypt -in "${pending[0]}" 2>/dev/null | head -c 2 | od -An -tx1 | tr -d ' \n')
  [ "$magic" = 1f8b ] || { echo "Wrong password."; exit 1; }

  log "Unpacking into $HOME"
  for f in "${pending[@]}"; do
    name=$(basename "$f")
    if [ -f "$SRC/MANIFEST.txt" ]; then
      want=$(awk -v n="$name" '$2 == n {print $1}' "$SRC/MANIFEST.txt" | tail -1)
      if [ -n "$want" ] && [ "$want" != "$(shasum -a 256 "$f" | cut -d' ' -f1)" ]; then
        echo "    $name: damaged or incomplete download. Download it again."; failed=1; continue
      fi
    fi
    # Top-level folders like Downloads are merged; settings and project folders are swapped whole.
    merge=0
    while IFS= read -r item; do
      [ -e "$HOME/$item" ] || [ -L "$HOME/$item" ] || continue
      case "$SRC/" in "$HOME/$item/"*) merge=1; continue ;; esac
      case "$item" in
        */* | .*) ;;
        *) if [ -d "$HOME/$item" ] && [ ! -L "$HOME/$item" ]; then merge=1; continue; fi ;;
      esac
      mkdir -p "$REPLACED/$(dirname "$item")" && mv "$HOME/$item" "$REPLACED/$item" && echo "    moved existing ~/$item aside"
    done < <(items_of "${name%.tar.gz.enc}")
    echo "    $name"
    if [ "$merge" = 1 ]; then
      stage="$RUN_DIR/staging-${name%.tar.gz.enc}"
      rm -rf "$stage"; mkdir -p "$stage"
      decrypt -in "$f" | tar -xpzf - -C "$stage"
      st=("${PIPESTATUS[@]}")
      if [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ]; then merge_into_home "$stage" || st=(1 1); fi
      rm -rf "$stage"
    else
      decrypt -in "$f" | tar -xpzf - -C "$HOME"
      st=("${PIPESTATUS[@]}")
    fi
    if [ "${st[0]}" -ne 0 ] || [ "${st[1]}" -ne 0 ]; then echo "    $name: could not be unpacked fully."; failed=1; continue; fi
    echo "$name" >> "$DONE"
  done
fi

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
  [ "$claude_running" = 1 ] || for d in "$p/$old_slug"*; do
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
  if [ "$claude_running" = 1 ]; then
    kept=(); for t in "${targets[@]}"; do case "$t" in "$HOME"/.claude*) ;; *) kept+=("$t") ;; esac; done
    targets=("${kept[@]}")
    grep -qsF "$OLD_HOME" "$HOME/.claude.json" && echo "    ~/.claude.json still has old paths: close Claude Code and run this script again."
  fi
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
if [ -f "$STATE_DIR/new-mac-setup/setup.sh" ]; then
  echo "  - Install your apps and tools (read its README.md first):  bash ~/.mac-migration/new-mac-setup/setup.sh"
fi
if [ -x /opt/homebrew/bin/brew ] && ! grep -qs 'brew shellenv' "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile"; then
  echo "  - Your restored shell files don't load Homebrew. Add this line to ~/.zprofile:"
  echo "      eval \"\$(/opt/homebrew/bin/brew shellenv)\""
fi
echo "  - Check ~/.mac-migration/inventory.md for repos and tools the setup script doesn't cover."
echo "  - Log in again to command-line tools that keep tokens in the Keychain: gh, gcloud, az, aws sso, and so on."
echo "  - Sign in to your browsers and IDEs and turn on sync."
echo "  - Reinstall project dependencies (npm install, uv sync, ...) when you open a project."
echo "  - Delete the archives from your cloud drive once everything works."
[ -d "$REPLACED" ] && echo "  - Files the restore moved aside are in $REPLACED"
exit 0
