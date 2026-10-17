#!/bin/bash
# Usage: ./make-app.sh [--install]   build "Mac Migrate.app" in build/ from app/main.js and the scripts
# --install puts it in ~/Applications (no administrator needed) and opens it.
# Built on this Mac, the app carries no quarantine flag, so Gatekeeper doesn't stop it. It is signed
# ad hoc: macOS ties privacy permissions to the build, so it is only rebuilt when something changed.
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SCRIPT_DIR/VERSION")"
BUILD="${MIG_BUILD_DIR:-$SCRIPT_DIR/build}"
APP="$BUILD/Mac Migrate.app"
INSTALLED="$HOME/Applications/Mac Migrate.app"
ENGINE_FILES=(backup.sh restore.sh make-setup.sh cleanup.sh make-app.sh VERSION LICENSE README.md config.example.sh lib app)

rm -rf "$APP"
mkdir -p "$BUILD"
/usr/bin/osacompile -l JavaScript -o "$APP" "$SCRIPT_DIR/app/main.js" || { echo "osacompile failed."; exit 1; }

# The scripts the app runs. -X leaves out extended attributes such as a download's quarantine flag.
E="$APP/Contents/Resources/engine"
mkdir -p "$E"
for f in "${ENGINE_FILES[@]}"; do [ -e "$SCRIPT_DIR/$f" ] && cp -RX "$SCRIPT_DIR/$f" "$E/"; done

P="$APP/Contents/Info.plist"
set_key() { plutil -replace "$1" -string "$2" "$P"; }
set_key CFBundleIdentifier io.github.nikolavas.mac-migrate
set_key CFBundleName "Mac Migrate"
set_key CFBundleShortVersionString "$VERSION"
set_key CFBundleVersion "$VERSION"
set_key LSMinimumSystemVersion 13.0
set_key LSApplicationCategoryType public.app-category.utilities
set_key NSHumanReadableCopyright "MIT License"
# Shown in the privacy prompts
set_key NSDesktopFolderUsageDescription "Mac Migrate backs up the folders you choose and restores them on your new Mac."
set_key NSDocumentsFolderUsageDescription "Mac Migrate backs up the folders you choose and restores them on your new Mac."
set_key NSDownloadsFolderUsageDescription "Mac Migrate backs up the folders you choose, and reads backups you downloaded."
set_key NSRemovableVolumesUsageDescription "Mac Migrate writes backups to the disk you choose, and reads them from it."
set_key NSNetworkVolumesUsageDescription "Mac Migrate writes backups to the network folder you choose, and reads them from it."
set_key NSFileProviderDomainUsageDescription "Mac Migrate puts backups in the cloud drive you choose, and reads them from it."

# Icon, drawn from an SF Symbol
ICONSET="$BUILD/icon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/app/icon.js" "$BUILD/icon.png" 1024 > /dev/null; then
  for px in 16 32 128 256 512; do
    sips -z $px $px "$BUILD/icon.png" --out "$ICONSET/icon_${px}x${px}.png" > /dev/null
    sips -z $((px * 2)) $((px * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${px}x${px}@2x.png" > /dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/applet.icns"; then
    # newer osacompile adds the default script icon as an asset catalog, which would win over applet.icns
    rm -f "$APP/Contents/Resources/Assets.car"
    plutil -remove CFBundleIconName "$P" 2> /dev/null
  else
    echo "    Couldn't build the icon, keeping the default one."
  fi
else
  echo "    Couldn't draw the icon, keeping the default one."
fi
rm -rf "$ICONSET"

/usr/bin/codesign --force --deep -s - "$APP" 2> /dev/null || { echo "Signing failed."; exit 1; }
/usr/bin/codesign --verify --deep "$APP" || { echo "The signature doesn't verify."; exit 1; }
echo "Built $APP ($VERSION)"

[ "$1" = --install ] || exit 0
# Same version and same scripts: keep the installed copy and the permissions macOS gave it
if [ -d "$INSTALLED" ] && [ "$(plutil -extract CFBundleShortVersionString raw "$INSTALLED/Contents/Info.plist" 2>/dev/null)" = "$VERSION" ] &&
  diff -rq "$E" "$INSTALLED/Contents/Resources/engine" > /dev/null 2>&1 &&
  cmp -s "$APP/Contents/Resources/Scripts/main.scpt" "$INSTALLED/Contents/Resources/Scripts/main.scpt"; then
  echo "Mac Migrate $VERSION is already in ~/Applications."
else
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED" || exit 1
  echo "Installed in ~/Applications."
fi
open "$INSTALLED"
