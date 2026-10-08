#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native -c release --arch arm64
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chipbar-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ChipBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/arm64-apple-macosx/release/ChipBar "$APP/Contents/MacOS/ChipBar"
VERSION="$(python3 scripts/version.py show)"
python3 - "$APP" "$VERSION" <<'PYINFO'
import plistlib, sys
from pathlib import Path
app, version = sys.argv[1:]
metadata = {
    "CFBundleIdentifier": "local.chipbar.monitor",
    "CFBundleName": "ChipBar", "CFBundleDisplayName": "ChipBar",
    "CFBundleExecutable": "ChipBar", "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version, "CFBundleVersion": version,
    "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
    "NSHighResolutionCapable": True,
}
with (Path(app) / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(metadata, stream)
PYINFO

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
mkdir -p dist
ditto --norsrc --noextattr "$APP" "$PWD/dist/ChipBar.app"
# File Provider may attach Finder metadata to the destination bundle in Documents.
# Remove only metadata prohibited by code signing, on our generated bundle.
xattr -dr com.apple.FinderInfo "$PWD/dist/ChipBar.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$PWD/dist/ChipBar.app" 2>/dev/null || true
codesign --verify --strict "$PWD/dist/ChipBar.app"
printf 'Built: %s\n' "$PWD/dist/ChipBar.app"
