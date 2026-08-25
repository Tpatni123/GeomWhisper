#!/bin/bash
# Build GeomWhisper.app and a ZIP from the GeomWhisper repository source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_DIR="${1:-$REPO_ROOT}"
DIST_DIR="${GEOMWHISPER_DIST_DIR:-$SCRIPT_DIR/dist}"
APP="$DIST_DIR/GeomWhisper.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
APP_SOURCE="$RESOURCES_DIR/app"
ZIP_PATH="$DIST_DIR/GeomWhisper-macOS-1.0.1.zip"

required_files="global.R server.R ui.R README.md LICENSE CITATION.cff www/speech.js www/styles.css skills/apa.md skills/nature.md images/geomwhisper-upload-workflow.png"
for relative_path in $required_files; do
    if [ ! -f "$SOURCE_DIR/$relative_path" ]; then
        echo "ERROR: missing required source file: $SOURCE_DIR/$relative_path" >&2
        exit 1
    fi
done
for build_file in Info.plist launcher icon.icns; do
    if [ ! -f "$SCRIPT_DIR/$build_file" ]; then
        echo "ERROR: missing Mac build file: $SCRIPT_DIR/$build_file" >&2
        exit 1
    fi
done

SOURCE_COMMIT="not-a-git-checkout"
SOURCE_REMOTE="unknown"
if git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    SOURCE_REMOTE="$(git -C "$SOURCE_DIR" remote get-url origin 2>/dev/null || echo unknown)"
fi

echo "==> Building GeomWhisper.app"
echo "    Source: $SOURCE_DIR"
echo "    Commit: $SOURCE_COMMIT"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP_SOURCE/www" "$APP_SOURCE/skills" "$APP_SOURCE/images"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$SCRIPT_DIR/launcher" "$MACOS_DIR/launcher"
cp "$SCRIPT_DIR/icon.icns" "$RESOURCES_DIR/icon.icns"
chmod 755 "$MACOS_DIR/launcher"

cp "$SOURCE_DIR/global.R" "$APP_SOURCE/global.R"
cp "$SOURCE_DIR/server.R" "$APP_SOURCE/server.R"
cp "$SOURCE_DIR/ui.R" "$APP_SOURCE/ui.R"
cp "$SOURCE_DIR/README.md" "$APP_SOURCE/README.md"
cp "$SOURCE_DIR/LICENSE" "$APP_SOURCE/LICENSE"
cp "$SOURCE_DIR/CITATION.cff" "$APP_SOURCE/CITATION.cff"
cp "$SOURCE_DIR/www/speech.js" "$APP_SOURCE/www/speech.js"
cp "$SOURCE_DIR/www/styles.css" "$APP_SOURCE/www/styles.css"
cp "$SOURCE_DIR/skills/apa.md" "$APP_SOURCE/skills/apa.md"
cp "$SOURCE_DIR/skills/nature.md" "$APP_SOURCE/skills/nature.md"
if [ -d "$SOURCE_DIR/images" ]; then
    ditto "$SOURCE_DIR/images" "$APP_SOURCE/images"
    find "$APP_SOURCE/images" -name '.DS_Store' -delete
fi

cat > "$APP_SOURCE/SOURCE_COMMIT.txt" <<EOF
Repository: $SOURCE_REMOTE
Commit: $SOURCE_COMMIT
Version: 1.0.1
EOF

plutil -lint "$CONTENTS/Info.plist" >/dev/null
xattr -cr "$APP" 2>/dev/null || true

# This verifies bundle integrity but is not a Developer ID signature and is not notarization.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_PATH"

echo "==> Built app: $APP"
echo "==> Built ZIP: $ZIP_PATH"
echo "    Signing: ad-hoc only (not notarized)"
