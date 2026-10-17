#!/bin/bash
# Builds Mac Migrate.app into a temporary folder and checks the bundle, the engine contract
# (through a fake engine) and that every window renders.
set -o pipefail

# shellcheck source=tests/support/helpers.sh
. "$(dirname "$0")/support/helpers.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
APP="$T/Mac Migrate.app"

echo "Build"
out=$(MIG_BUILD_DIR="$T" /bin/bash "$REPO/make-app.sh" 2>&1); rc=$?
check "make-app.sh exits 0" [ $rc -eq 0 ]
check "Info.plist is valid" plutil -lint -s "$APP/Contents/Info.plist"
check "bundle id set" [ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = io.github.nikolavas.mac-migrate ]
check "version from VERSION" [ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$(cat "$REPO/VERSION")" ]
check "privacy prompts explained" [ -n "$(plutil -extract NSDesktopFolderUsageDescription raw "$APP/Contents/Info.plist")" ]
check "signature verifies" codesign --verify --deep "$APP"
check "no quarantine flag" [ -z "$(xattr -r "$APP" 2>/dev/null | grep quarantine)" ]
check "own icon" [ -s "$APP/Contents/Resources/applet.icns" ] && [ ! -e "$APP/Contents/Resources/Assets.car" ]
for f in backup.sh restore.sh cleanup.sh make-setup.sh lib/common.sh lib/places.sh lib/cloud.js VERSION; do
  check "engine has $f" [ -f "$APP/Contents/Resources/engine/$f" ]
done

echo "Self-test"
out=$(osascript -l JavaScript "$REPO/app/main.js" --self-test "$REPO/tests/support" 2>&1); rc=$?
echo "$out" | grep -E '^  (ok|FAIL)' | sed 's/^  /  self-test: /' | grep FAIL
check "self-test passes (parsing, engine runs, Stop)" [ $rc -eq 0 ] && grep -q "All checks passed" <<< "$out"

echo "Windows"
out=$(osascript -l JavaScript "$REPO/app/main.js" --screenshots "$T/shots" "$T/icon.png" 2>&1); rc=$?
check "every window renders" [ $rc -eq 0 ] && [ "$(find "$T/shots" -name '*.png' | wc -l | tr -d ' ')" -ge 7 ]

summary
