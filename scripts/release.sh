#!/usr/bin/env bash
# Builds Grab in Release configuration, packages it as a DMG under build/,
# signs the DMG for Sparkle (EdDSA), and updates the appcast.xml feed this
# repo hosts for in-app auto-updates. Ad-hoc signed only (see project.yml:
# CODE_SIGN_IDENTITY "-") -- there's no paid Apple Developer ID involved, so
# the DMG is not notarized. End users will still hit Gatekeeper's
# "unidentified developer" block on every install/update; see README.md for
# the exact steps to get past it. That's expected and unrelated to the
# Sparkle signing this script does below -- EdDSA signing is what lets a
# *running* Grab verify a downloaded update file actually came from this
# project's private key before installing it over itself; it doesn't touch
# Gatekeeper/notarization at all, and skipping it isn't an option (Sparkle
# refuses to install an unsigned or wrongly-signed update).
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Release"
SCHEME="Grab"
PROJECT="Grab.xcodeproj"
REPO="Tz4i/grab"
# Pinned so every release signs with a known-working tool version rather
# than whatever happens to be latest on the day; bump deliberately (and
# clear .sparkle-tools/ or just let the version-mismatch below force a
# re-download) if a newer Sparkle release is worth picking up.
SPARKLE_TOOLS_VERSION="2.9.4"
SPARKLE_TOOLS_DIR="$(pwd)/.sparkle-tools/$SPARKLE_TOOLS_VERSION"

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

echo "==> Preparing Sparkle signing tools (sign_update)"
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
  echo "    Downloading Sparkle $SPARKLE_TOOLS_VERSION command-line tools..."
  rm -rf "$SPARKLE_TOOLS_DIR"
  mkdir -p "$SPARKLE_TOOLS_DIR"
  tmp_tarball="$(mktemp -t sparkle-tools).tar.xz"
  curl -sL -o "$tmp_tarball" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_TOOLS_VERSION}/Sparkle-${SPARKLE_TOOLS_VERSION}.tar.xz"
  tar -xf "$tmp_tarball" -C "$SPARKLE_TOOLS_DIR" bin/sign_update bin/generate_keys
  rm -f "$tmp_tarball"
  # Downloaded via curl, so Gatekeeper-quarantined -- strip that so
  # sign_update actually runs. Explicitly /usr/bin/xattr: this repo's own
  # notes (CLAUDE.md) record a pip-installed xattr shadowing the system one
  # on at least one dev machine, which silently doesn't support -r.
  /usr/bin/xattr -rc "$SPARKLE_TOOLS_DIR"
fi
sign_update="$SPARKLE_TOOLS_DIR/bin/sign_update"

echo "==> Signing $dmg_path for Sparkle (EdDSA)"
# Reads the private key from this Mac's login Keychain automatically (the
# account generate_keys stored it under, "ed25519") -- nothing to pass in,
# nothing on disk to protect. If this fails with a Keychain-access prompt
# or error, the signing key was never generated on this machine; see
# CLAUDE.md's "Auto-updates (Sparkle)" section for how to generate one.
sign_output="$("$sign_update" "$dmg_path")"
echo "    $sign_output"
ed_signature="$(echo "$sign_output" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
dmg_length="$(echo "$sign_output" | sed -E 's/.*length="([^"]+)".*/\1/')"
if [ -z "$ed_signature" ] || [ -z "$dmg_length" ]; then
  echo "error: couldn't parse sign_update output: $sign_output" >&2
  exit 1
fi

echo "==> Updating appcast.xml"
download_url="https://github.com/$REPO/releases/download/v$version/Grab-$version.dmg"
min_system_version=$(grep 'LSMinimumSystemVersion:' project.yml | head -1 | sed -E 's/.*LSMinimumSystemVersion: *"([^"]+)".*/\1/')
pub_date="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

python3 "$(dirname "$0")/update_appcast.py" \
  --appcast appcast.xml \
  --version "$version" \
  --url "$download_url" \
  --signature "$ed_signature" \
  --length "$dmg_length" \
  --min-system-version "${min_system_version:-14.0}" \
  --pub-date "$pub_date"

echo "==> Committing and pushing appcast.xml"
git add appcast.xml
if git diff --cached --quiet -- appcast.xml; then
  echo "    appcast.xml already reflects v$version, nothing to commit."
else
  git commit -m "Update appcast for v$version"
  git push
fi

echo "==> Done: $dmg_path"
echo ""
echo "appcast.xml now points at a release asset ($download_url) that"
echo "doesn't exist yet -- the feed will 404 for that URL until the GitHub"
echo "release is actually created. Don't leave a gap here; finish the"
echo "release now:"
echo ""
echo "    git tag v$version && git push origin v$version"
echo "    gh release create v$version \"$dmg_path\" --title \"Grab v$version\" --notes \"...\""
