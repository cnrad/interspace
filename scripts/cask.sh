#!/bin/bash
# Sets the version and the checksum in Casks/interspace.rb to those of build/Interspace.dmg.
# Run it after scripts/dmg.sh, and commit the change with the release.
set -euo pipefail

cd "$(dirname "$0")/.."

DMG="build/Interspace.dmg"
CASK="Casks/interspace.rb"

if [ ! -f "$DMG" ]; then
    echo "No $DMG. Run scripts/dmg.sh first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
SHA256="$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"

sed -i '' \
    -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
    "$CASK"

echo "$CASK is at $VERSION ($SHA256)."
