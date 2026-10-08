#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native -c release --arch arm64
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chipbar-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ChipBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/arm64-apple-macosx/release/ChipBar "$APP/Contents/MacOS/ChipBar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.chipbar.monitor</string>
<key>CFBundleName</key><string>ChipBar</string>
<key>CFBundleDisplayName</key><string>ChipBar</string>
<key>CFBundleExecutable</key><string>ChipBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
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
