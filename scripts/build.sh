#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native -c release --arch arm64
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chipbar-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/ChipBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X .build/arm64-apple-macosx/release/ChipBar "$APP/Contents/MacOS/ChipBar"
./scripts/icon.sh "$APP/Contents/Resources"
cp -X Assets/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
VERSION="$(python3 scripts/version.py show)"
python3 - "$APP" "$VERSION" <<'PYINFO'
import plistlib, sys
from pathlib import Path
app, version = sys.argv[1:]
metadata = {
    "CFBundleIdentifier": "local.chipbar.monitor",
    "CFBundleName": "ChipBar", "CFBundleDisplayName": "ChipBar",
    "CFBundleExecutable": "ChipBar", "CFBundlePackageType": "APPL",
    "CFBundleIconFile": "AppIcon.icns",
    "CFBundleShortVersionString": version, "CFBundleVersion": version,
    "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSLocalNetworkUsageDescription": "在局域网发现并加密查看已授权 Mac 的只读性能监控数据。",
    "NSBonjourServices": ["_chipbar-mon._tcp"],
    "CFBundleURLTypes": [{
        "CFBundleURLName": "local.chipbar.monitor.url",
        "CFBundleURLSchemes": ["chipbar"]
    }],
}
with (Path(app) / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(metadata, stream)
PYINFO

# Build WidgetKit as an actual Xcode app-extension target, never a bare
# swiftc executable hand-wrapped as .appex. The latter can compile and sign
# successfully while chronod rejects or exits during widget registration.
# The real target embeds extension runtime metadata and XPC launch semantics.
WIDGET_PRODUCTS="$STAGE/widget-products"
xcodebuild \
  -project WidgetExtension/ChipBarWidgets.xcodeproj \
  -target ChipBarWidgets \
  -configuration Release \
  -sdk macosx \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  SYMROOT="$WIDGET_PRODUCTS" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$VERSION" MARKETING_VERSION="$VERSION" \
  build
BUILT_WIDGET="$WIDGET_PRODUCTS/Release/ChipBarWidgets.appex"
test -x "$BUILT_WIDGET/Contents/MacOS/ChipBarWidgets" || {
  echo "ERROR: Xcode did not create ChipBarWidgets.appex" >&2
  exit 1
}
mkdir -p "$APP/Contents/PlugIns"
ditto --norsrc --noextattr "$BUILT_WIDGET" "$APP/Contents/PlugIns/ChipBarWidgets.appex"
WIDGET="$APP/Contents/PlugIns/ChipBarWidgets.appex"
# The CI release is ad-hoc signed and therefore cannot assert a provisioned
# App Group. A developer/team-signed distribution may opt in by setting BOTH
# CHIPBAR_CODESIGN_IDENTITY and CHIPBAR_APP_GROUP_ID; the app and extension
# then receive the same entitlement. Never embed a fake App Group entitlement
# into the ad-hoc release and cause WidgetKit's chronod to reject it.
SIGN_IDENTITY="${CHIPBAR_CODESIGN_IDENTITY:--}"
APP_GROUP="${CHIPBAR_APP_GROUP_ID:-}"
if [[ -n "$APP_GROUP" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "ERROR: App Group requires a genuine Apple Team code signing identity" >&2
  exit 1
fi
python3 - "$STAGE" "$APP_GROUP" <<'PYWIDGET'
import plistlib
import sys
from pathlib import Path
stage, app_group = sys.argv[1:]
widget = {"com.apple.security.app-sandbox": True}
host = {}
if app_group:
    widget["com.apple.security.application-groups"] = [app_group]
    host["com.apple.security.application-groups"] = [app_group]
with (Path(stage) / "widget.entitlements").open("wb") as stream:
    plistlib.dump(widget, stream)
if host:
    with (Path(stage) / "host.entitlements").open("wb") as stream:
        plistlib.dump(host, stream)
PYWIDGET

codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$STAGE/widget.entitlements" "$WIDGET"
if [[ -n "$APP_GROUP" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$STAGE/host.entitlements" "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p dist
ditto --norsrc --noextattr "$APP" "$PWD/dist/ChipBar.app"
# File Provider may attach Finder metadata to the destination bundle in Documents.
# Remove only metadata prohibited by code signing, on our generated bundle.
xattr -dr com.apple.FinderInfo "$PWD/dist/ChipBar.app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$PWD/dist/ChipBar.app" 2>/dev/null || true
codesign --verify --deep --strict "$PWD/dist/ChipBar.app"
printf 'Built: %s\n' "$PWD/dist/ChipBar.app"
