#!/bin/bash
# Shared by backup.sh, restore.sh and cleanup.sh. Expects SCRIPT_DIR.
# shellcheck disable=SC2034  # constants are used by the scripts that source this file

MM_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo dev)"
OPENSSL=/usr/bin/openssl  # same LibreSSL build on every Mac; Homebrew's openssl may come first in PATH
KDF_ITER=200000
STATE_DIR_NAME=.mac-migration
STATE_DIR="$HOME/$STATE_DIR_NAME"
PWCHECK_TEXT="mac-migrate password check"

# Exit codes the app turns into dialogs
E_PASSWORD=10 E_UPLOAD=11 E_PERMISSION=12 E_LOCKED=13 E_SPACE=14 E_STALLED=15

# An app started from Finder gets launchd's short PATH and no LANG. Look where Terminal would.
mm_env() {
  local d nvm
  [ -n "$LANG" ] || export LANG=en_US.UTF-8
  # shellcheck disable=SC2012  # version folders have plain names
  nvm=$(ls -d "$HOME"/.nvm/versions/node/v*/bin 2>/dev/null | sort -V | tail -1)
  for d in /usr/local/bin /opt/homebrew/sbin /opt/homebrew/bin "$nvm" "$HOME/.local/bin"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
  done
  export PATH
}

# --- Output -----------------------------------------------------------------
# MIG_RUN is a folder the app watches: `status` is a one-line snapshot, `events.tsv` the history.

log() { printf '\n==> %s\n' "$*"; event step "$*"; }
warn() { printf '    %s\n' "$*"; event warn "$*"; }
event() { [ -n "$MIG_RUN" ] && printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$MIG_RUN/events.tsv"; return 0; }
# status phase item done_kb total_kb rate_kb_s eta_s message
status() {
  [ -n "$MIG_RUN" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" > "$MIG_RUN/status.tmp" && mv -f "$MIG_RUN/status.tmp" "$MIG_RUN/status"
}
die() { local code="$1"; shift; FAIL_REASON="$*"; printf '%s\n' "$*" >&2; exit "$code"; }

# Logs go to ~/.mac-migration/logs. In Terminal the output also stays on screen, and the
# progress bar goes to the screen only (fd 4).
start_log() {
  local name="$1" dir="$STATE_DIR/logs"
  shift
  mkdir -p "$dir" || return 0
  LOG_FILE="$dir/$name-$(date +%Y%m%d-%H%M%S).log"
  # shellcheck disable=SC2012  # log names are ours
  ls -t "$dir/$name"-*.log 2>/dev/null | tail -n +10 | while IFS= read -r f; do rm -f "$f"; done
  exec 4>&2
  if [ "$MIG_NONINTERACTIVE" = 1 ]; then
    exec >> "$LOG_FILE" 2>&1
  else
    exec > >(tee -a "$LOG_FILE") 2>&1
  fi
  event log "$LOG_FILE"
  echo "mac-migrate $MM_VERSION, $(date '+%Y-%m-%d %H:%M'), $name $*"
}

# The app reads the outcome from events.tsv, also when it attached to a run it didn't start
finish() {
  local code="$1"
  [ -n "$MIG_RUN" ] && printf 'result\t%s\t%s\n' "$code" "${FAIL_REASON:-}" >> "$MIG_RUN/events.tsv"
  lock_release
}

# --- One run at a time ------------------------------------------------------

lock_acquire() {
  local d="$STATE_DIR/lock" pid
  mkdir -p "$STATE_DIR"
  if ! mkdir "$d" 2>/dev/null; then
    pid=$(cat "$d/pid" 2>/dev/null)
    # a pid can be reused after a restart, so the start time has to match too
    if [ -n "$pid" ] && [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" = "$(cat "$d/start" 2>/dev/null)" ]; then
      die "$E_LOCKED" "Another mac-migrate run is active ($(cat "$d/what" 2>/dev/null), process $pid). Wait for it to finish, or stop it first."
    fi
    rm -rf "$d"; mkdir "$d" || die 1 "Can't create $d"
  fi
  echo $$ > "$d/pid"
  ps -o lstart= -p $$ > "$d/start"
  echo "$1" > "$d/what"
  [ -n "$MIG_RUN" ] && echo "$MIG_RUN" > "$d/run"
  LOCKED=1
}
lock_release() { [ "$LOCKED" = 1 ] && rm -rf "$STATE_DIR/lock"; LOCKED=0; }

# Keep the Mac awake while this process runs. -s only holds on mains power.
stay_awake() {
  /usr/bin/caffeinate -ims -w $$ 2>/dev/null &
  if /usr/bin/pmset -g batt 2>/dev/null | grep -q "Battery Power"; then
    warn "This Mac runs on battery. Plug it in and keep the lid open, or it may sleep and pause the $1."
  fi
}

# --- Password and encryption ------------------------------------------------
# The password stays in an unexported variable and reaches openssl through fd 3, so it never
# shows up in a process list or in the environment of child processes.

read_password() {  # new|existing
  if [ -n "$MIG_PASS" ]; then
    PW="$MIG_PASS"; unset MIG_PASS
  elif [ "$PASSWORD_STDIN" = 1 ]; then
    IFS= read -r PW
  elif [ "$MIG_NONINTERACTIVE" = 1 ]; then
    die 1 "No password given."
  elif [ "$1" = new ]; then
    echo "Choose a password for the archives. Save it in your password manager: without it the archives can't be opened."
    local p2
    IFS= read -rs -p "Password: " PW; echo
    IFS= read -rs -p "Repeat the password: " p2; echo
    [ -n "$PW" ] && [ "$PW" = "$p2" ] || die "$E_PASSWORD" "The passwords don't match."
  else
    IFS= read -rs -p "Archive password: " PW; echo
  fi
  [ -n "$PW" ] || die "$E_PASSWORD" "The password is empty."
}

# Same parameters as format 1, with the digest made explicit
encrypt() { "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter "$KDF_ITER" -md sha256 -salt -pass fd:3 "$@" 3< <(printf '%s' "$PW"); }
decrypt() { "$OPENSSL" enc -d -aes-256-cbc -pbkdf2 -iter "$KDF_ITER" -md sha256 -pass fd:3 "$@" 3< <(printf '%s' "$PW"); }

make_pwcheck() { echo "$PWCHECK_TEXT" | encrypt -out "$1"; }
pwcheck_ok() { [ "$(decrypt -in "$1" 2>/dev/null)" = "$PWCHECK_TEXT" ]; }

# HMAC-SHA256 of a file with a key derived from the password (PBKDF2 through openssl -P).
# The key reaches perl through a pipe, never the command line.
hmac_file() {  # file salt iter
  "$OPENSSL" enc -aes-256-cbc -pbkdf2 -iter "$3" -md sha256 -S "$2" -P -pass fd:3 3< <(printf '%s' "$PW") |
    sed -n 's/^key=//p' |
    /usr/bin/perl -MDigest::SHA=hmac_sha256_hex -e '
      my $k = <STDIN>; chomp $k; die "no key\n" unless $k;
      open my $f, "<", $ARGV[0] or die "$ARGV[0]: $!\n"; binmode $f; local $/;
      print hmac_sha256_hex(<$f>, pack("H*", $k)), "\n"' "$1"
}

# --- Manifest ---------------------------------------------------------------
# Format 2:
#   # mac-migrate format 2 backup=<id> version=<v> complete=<yes|no>
#   <sha256>  <bytes>  <file>          one line per archive part, plan.txt and password-check.enc
#   # hmac-sha256 iter=<n> salt=<hex> <hex>   over every line above
# Format 1 has "<sha256>  <file>" lines only and no signature.

manifest_format() { head -1 "$1" 2>/dev/null | grep -q '^# mac-migrate format 2 ' && echo 2 || echo 1; }
manifest_field() { head -1 "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# Checks the signature with the password in PW
manifest_verify() {
  local m="$1" sig iter salt want body
  sig=$(tail -1 "$m")
  case "$sig" in "# hmac-sha256 "*) ;; *) return 1 ;; esac
  iter=$(printf '%s' "$sig" | tr ' ' '\n' | sed -n 's/^iter=//p')
  salt=$(printf '%s' "$sig" | tr ' ' '\n' | sed -n 's/^salt=//p')
  want=${sig##* }
  case "$iter$salt" in *[!0-9a-fA-F]* | '') return 1 ;; esac
  body=$(mktemp) || return 1
  sed '$d' "$m" > "$body"
  [ "$(hmac_file "$body" "$salt" "$iter")" = "$want" ]
  local rc=$?
  rm -f "$body"
  return $rc
}

file_size() { stat -f %z "$1"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# KB as MB or GB, for messages
gb() { awk -v k="$1" 'BEGIN {if (k < 1048576) printf "%d MB", k / 1024 + 0.5; else printf "%.1f GB", k / 1048576}'; }

# Free space in KB on the volume holding a path
free_kb() { df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# Cloud state of files, see lib/cloud.js. MIG_CLOUD_HELPER replaces it in tests.
cloud() {
  if [ -n "$MIG_CLOUD_HELPER" ]; then "$MIG_CLOUD_HELPER" "$@"; else /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/lib/cloud.js" "$@"; fi
}

# Paths synced by a cloud provider: deleting a file there deletes it in the cloud too
in_cloud_folder() {
  case "$1/" in
    "$HOME/Library/CloudStorage/"* | "$HOME/Library/Mobile Documents/"*) return 0 ;;
  esac
  return 1
}

# Pass-through that draws the progress bar on the screen (fd 4) and keeps the app's status file current
meter() {
  /usr/bin/perl -e '
    use strict; use Time::HiRes qw(time);
    binmode STDIN; binmode STDOUT;
    my ($total, $before, $cur, $name, $statusf, $countf, $phase) = @ENV{qw(M_TOTAL M_BEFORE M_CUR M_NAME M_STATUS M_COUNT M_PHASE)};
    $phase ||= "pack";
    my $tty; my $bar = open($tty, ">&=", 4) && -t $tty;
    binmode $tty, ":utf8" if $bar;
    my ($n, $buf, $bytes, $t0, $last) = (0, "", 0, time, 0);
    sub draw {
      my $kb = $_[0] ? $cur : $bytes / 1024;
      $kb = $cur * 0.99 if $kb > $cur * 0.99 && !$_[0];
      my $all = $total > 0 ? ($before + $kb) / $total : 1; $all = 1 if $all > 1;
      my $secs = time - $t0;
      my $rate = $secs > 0 ? $bytes / $secs : 0;
      my $left = $rate > 0 ? int(($total - $before - $kb) * 1024 / $rate + 0.5) : -1; $left = 0 if $rate > 0 && $left < 0;
      if ($bar) {
        my $fill = int($all * 30 + 0.5);
        my $m = int($left / 60 + 0.5);
        my $speed = $secs < 3 ? "  --" : sprintf("%4d", $rate / 1048576);
        my $eta = $secs < 3 ? "--" : $m >= 60 ? sprintf("%dh%02dm", $m / 60, $m % 60) : "${m}m";
        my $pct = $cur > 0 ? $kb / $cur * 100 : 100; $pct = 100 if $pct > 100;
        printf $tty "\r  [%s%s] %3d%%  %5.1f / %.1f GB  |  %s %3d%%  |  %s MB/s  |  ~%s left   ",
          "\x{2588}" x $fill, "\x{2591}" x (30 - $fill), $all * 100, ($before + $kb) / 1048576, $total / 1048576,
          $name, $pct, $speed, $eta;
      }
      if ($statusf && open(my $s, ">", "$statusf.tmp")) {
        printf $s "%s\t%s\t%d\t%d\t%d\t%d\t\n", $phase, $name, $before + $kb, $total, $rate / 1024, $secs < 3 ? -1 : $left;
        close $s; rename "$statusf.tmp", $statusf;
      }
    }
    while (($n = sysread(STDIN, $buf, 1 << 20)) > 0) {
      my $off = 0;
      while ($off < $n) { my $w = syswrite(STDOUT, $buf, $n - $off, $off); exit 1 unless defined $w; $off += $w; }
      $bytes += $n;
      if (time - $last >= 1) { draw(0); $last = time; }
    }
    draw(1); print $tty "\n" if $bar;
    if ($countf && open(my $c, ">", $countf)) { print $c "$bytes\n"; close $c }
    exit(defined $n ? 0 : 1);
  '
}
