#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    printf 'Usage: ./scripts/icon.sh output-resource-directory\n' >&2
    exit 1
fi
ICON_DEST="$1"
ICON_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chipbar-icon.XXXXXX")"
trap 'rm -rf "$ICON_STAGE"' EXIT
ICONSET="$ICON_STAGE/AppIcon.iconset"
mkdir -p "$ICONSET" "$ICON_DEST"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICON_DEST/AppIcon.icns"
