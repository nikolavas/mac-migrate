#!/bin/bash
# Free up space on a fake home: only chosen items go, and nothing outside them.
set -o pipefail

# shellcheck source=tests/support/helpers.sh
. "$(dirname "$0")/support/helpers.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H="$T/home/judy"
L="$H/Library"

mkdir -p "$L/Caches/pip/http" "$L/Developer/Xcode/DerivedData/App-abc" "$H/.m2/repository/org" "$L/Caches/com.example.app" \
  "$L/Caches/com.apple.Safari" "$H/proj/web/node_modules/react" "$H/proj/notjs/node_modules/x" "$H/proj/py/.venv" \
  "$H/proj/fakevenv/.venv" "$T/outside/precious" "$H/.cache"
head -c 300000 /dev/urandom > "$L/Caches/pip/http/blob"
head -c 300000 /dev/urandom > "$L/Developer/Xcode/DerivedData/App-abc/build.o"
head -c 300000 /dev/urandom > "$H/.m2/repository/org/lib.jar"
head -c 100000 /dev/urandom > "$L/Caches/com.example.app/cache.db"
echo keep > "$L/Caches/com.apple.Safari/x"
echo '{}' > "$H/proj/web/package.json"; head -c 100000 /dev/urandom > "$H/proj/web/node_modules/react/index.js"
head -c 100000 /dev/urandom > "$H/proj/notjs/node_modules/x/data"
echo "home = /usr/bin" > "$H/proj/py/.venv/pyvenv.cfg"; echo src > "$H/proj/py/main.py"
echo "not a venv" > "$H/proj/fakevenv/.venv/notes.txt"
echo "precious" > "$T/outside/precious/file"
ln -s "$T/outside/precious" "$H/.cache/huggingface"

clean() { HOME="$H" MIGRATE_CONFIG="$T/config.sh" /bin/bash "$REPO/cleanup.sh" "$@"; }
: > "$T/config.sh"

echo "Listing"
list=$(clean --list)
check "pip cache listed as safe and preselected" grep -q "^pip	pip cache	[0-9]*	safe	1	" <<< "$list"
check "Xcode build data listed" grep -q "^xcode-derived	" <<< "$list"
check "Maven listed, not preselected" grep -q "^maven	.*	download	0	" <<< "$list"
check "other app caches listed" grep -q "^app-caches	" <<< "$list"
check "node_modules found in 1 project" grep -q "^projects-node	node_modules in 1 project(s)	" <<< "$list"
check "virtual environment found in 1 project" grep -q "^projects-python	Python virtual environments in 1 project(s)	" <<< "$list"
check_not "a symlink to elsewhere is not offered" grep -q "^huggingface	" <<< "$list"

echo "Dry run"
out=$(clean --clean pip maven --dry-run 2>&1)
check "dry run says what it would delete" grep -q "would delete .*/Library/Caches/pip" <<< "$out"
check "dry run deletes nothing" [ -f "$L/Caches/pip/http/blob" ] && [ -f "$H/.m2/repository/org/lib.jar" ]

echo "Cleaning"
out=$(clean --clean pip xcode-derived app-caches projects-node projects-python huggingface 2>&1); rc=$?
check "exits 0" [ $rc -eq 0 ]
check "pip cache gone" [ ! -e "$L/Caches/pip" ]
check "Xcode build data gone" [ ! -e "$L/Developer/Xcode/DerivedData" ]
check "other app caches gone" [ ! -e "$L/Caches/com.example.app" ]
check "Apple's caches kept" [ -f "$L/Caches/com.apple.Safari/x" ]
check "Maven kept (not chosen)" [ -f "$H/.m2/repository/org/lib.jar" ]
check "node_modules next to package.json gone" [ ! -e "$H/proj/web/node_modules" ]
check "node_modules without package.json kept" [ -f "$H/proj/notjs/node_modules/x/data" ]
check "real virtual environment gone, sources kept" [ ! -e "$H/proj/py/.venv" ] && [ -f "$H/proj/py/main.py" ]
check "folder named .venv without pyvenv.cfg kept" [ -f "$H/proj/fakevenv/.venv/notes.txt" ]
check "the target of a symlink is never deleted" [ -f "$T/outside/precious/file" ]
check "reports what it freed" grep -q "^==> Freed" <<< "$out"

echo "CLEANUP_KEEP"
mkdir -p "$L/Caches/pip/http"; echo x > "$L/Caches/pip/http/blob"
echo 'CLEANUP_KEEP=(Library/Caches/pip)' > "$T/config.sh"
clean --clean pip > /dev/null 2>&1
check "kept folder survives" [ -f "$L/Caches/pip/http/blob" ]

summary
