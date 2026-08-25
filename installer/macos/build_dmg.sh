#!/bin/bash
# Create a compressed DMG containing GeomWhisper.app and an Applications link.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="${GEOMWHISPER_DIST_DIR:-$SCRIPT_DIR/dist}"
APP="$DIST_DIR/GeomWhisper.app"
DMG="$DIST_DIR/GeomWhisper-macOS-1.0.1.dmg"
ZIP="$DIST_DIR/GeomWhisper-macOS-1.0.1.zip"
CHECKSUMS="$DIST_DIR/SHA256SUMS.txt"

if [ ! -d "$APP" ]; then
    echo "ERROR: $APP does not exist. Run installer/macos/build_app.sh first." >&2
    exit 1
fi
if [ ! -f "$ZIP" ]; then
    echo "ERROR: $ZIP does not exist. Run installer/macos/build_app.sh first." >&2
    exit 1
fi

STAGING="$(mktemp -d -t geomwhisper_dmg)"
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

ditto "$APP" "$STAGING/GeomWhisper.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "GeomWhisper 1.0.1" \
    -srcfolder "$STAGING" \
    -format UDZO \
    -ov \
    "$DMG"

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "$(basename "$CHECKSUMS")"
)

echo "==> Built DMG: $DMG"
echo "==> Built checksums: $CHECKSUMS"
echo "    Signing: embedded app is ad-hoc signed; DMG is not notarized"
