#!/bin/bash
# Builds Interspace and packages it as build/Interspace.app.
#
#   scripts/bundle.sh               for this Mac only
#   scripts/bundle.sh --universal   for Apple silicon and Intel, as a release needs
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_ARGS=(-c release)
if [ "${1:-}" = "--universal" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"

APP="build/Interspace.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Interspace" "$APP/Contents/MacOS/Interspace"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS ties the Accessibility and Screen Recording grants to the signature.
# With the local identity from scripts/setup-signing.sh the grants stay valid after a rebuild.
IDENTITY="interspace local signing"
KEYCHAIN="$HOME/Library/Keychains/interspace-signing.keychain-db"
SECRET_FILE="$HOME/.config/interspace/signing-keychain-password"

if [ -f "$KEYCHAIN" ] && [ -f "$SECRET_FILE" ]; then
    security unlock-keychain -p "$(cat "$SECRET_FILE")" "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --options runtime --identifier com.cnrad.interspace "$APP"
else
    echo "No local signing identity (run scripts/setup-signing.sh). Using an ad-hoc signature:"
    echo "each new build must be allowed again in System Settings."
    codesign --force --sign - --options runtime --identifier com.cnrad.interspace "$APP"
fi

echo "Built $APP"
