#!/bin/bash
# Builds Burst.app and installs it to /Applications.
# Usage: ./build.sh                build + install + launch
#        ./build.sh --no-install   build into ./dist only
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Burst"
DIST="dist"
BUNDLE="$DIST/$APP_NAME.app"
# Signing identity: $BURST_SIGN_IDENTITY (a codesigning identity name or hash),
# else the first line of a local, git-ignored .sign-identity file, else none.
# With none, the app is signed ad-hoc. That runs fine, but an ad-hoc signature
# changes every build, so macOS may ask for Accessibility and Screen Recording
# again after each rebuild. A stable identity keeps those permissions granted.
IDENTITY="${BURST_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f .sign-identity ]; then
  IDENTITY="$(head -n 1 .sign-identity | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi

echo "▸ Compiling (release)…"
swift build -c release --disable-sandbox

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "✗ Binary not found at $BIN"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
[ -f "Resources/AppIcon.icns" ] && cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▸ Signing…"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF -- "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE"
else
  echo "  (no usable signing identity: signing ad-hoc, so macOS may ask for permissions again after each rebuild)"
  codesign --force --sign - --timestamp=none "$BUNDLE"
fi

if [ "${1:-}" = "--no-install" ]; then
  echo "✓ Built $BUNDLE"
  exit 0
fi

echo "▸ Installing to /Applications…"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.4
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUNDLE" "/Applications/$APP_NAME.app"

echo "▸ Launching…"
open "/Applications/$APP_NAME.app"

echo "✓ Burst is in your menu bar. Hold ⌃⌥ anywhere to grab."
