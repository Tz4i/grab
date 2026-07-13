#!/usr/bin/env bash
# Builds Grab in Release configuration and packages it as a DMG under
# build/. Ad-hoc signed only (see project.yml: CODE_SIGN_IDENTITY "-") --
# there's no paid Apple Developer ID involved, so the DMG is not notarized.
# End users will hit Gatekeeper's "unidentified developer" block on first
# launch; see README.md for the exact steps to get past it.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Release"
SCHEME="Grab"
PROJECT="Grab.xcodeproj"

# Command Line Tools alone can't build this SwiftUI/macOS target -- a full
# Xcode install is required. Respect an explicit DEVELOPER_DIR if the
# caller set one; otherwise find whatever Xcode.app is registered with
# Spotlight. (Don't hardcode a path: on this machine the Xcode-beta
# install has already moved once, from ~/Downloads to an external volume.)
if [ -z "${DEVELOPER_DIR:-}" ]; then
  xcode_app=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)
  if [ -z "$xcode_app" ]; then
    echo "error: no full Xcode install found (Command Line Tools alone can't build this target)." >&2
    echo "Set DEVELOPER_DIR explicitly, or install Xcode." >&2
    exit 1
  fi
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
fi
echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"

version=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*MARKETING_VERSION: *"([^"]+)".*/\1/')
if [ -z "$version" ]; then
  echo "error: couldn't read MARKETING_VERSION from project.yml" >&2
  exit 1
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> Building Grab.app v$version ($CONFIGURATION)"
build_dir="$(pwd)/build"
rm -rf "$build_dir"
mkdir -p "$build_dir"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  build

app_path="$build_dir/DerivedData/Build/Products/$CONFIGURATION/Grab.app"
if [ ! -d "$app_path" ]; then
  echo "error: build did not produce $app_path" >&2
  exit 1
fi

echo "==> Packaging DMG"
staging="$build_dir/dmg-staging"
rm -rf "$staging"
mkdir -p "$staging"
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"

dmg_path="$build_dir/Grab-$version.dmg"
rm -f "$dmg_path"
hdiutil create -volname "Grab" -srcfolder "$staging" -ov -format UDZO "$dmg_path" >/dev/null

echo "==> Done: $dmg_path"
