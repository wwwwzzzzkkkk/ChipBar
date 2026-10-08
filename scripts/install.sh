#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/ChipBar.app"
DEST="$HOME/Applications/ChipBar.app"
if [[ ! -d "$APP" ]]; then ./scripts/build.sh; fi
if [[ -e "$DEST" ]]; then
    printf 'Already exists: %s\nQuit ChipBar and move the old copy aside before installing.\n' "$DEST" >&2
    exit 1
fi
mkdir -p "$HOME/Applications"
ditto --norsrc --noextattr "$APP" "$DEST"
codesign --verify --strict "$DEST"
open "$DEST"
printf 'Installed: %s\n' "$DEST"
