#!/bin/bash
# Shared by the tests: source it, then call summary at the end.
# shellcheck disable=SC2034  # used by the tests that source this file
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0

ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; fails=$((fails + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else fail "$msg"; fi; }
check_not() { local msg="$1"; shift; if "$@"; then fail "$msg"; else ok "$msg"; fi; }

summary() {
  echo
  if [ $fails -eq 0 ]; then echo "All checks passed."; else echo "$fails check(s) failed."; exit 1; fi
}
