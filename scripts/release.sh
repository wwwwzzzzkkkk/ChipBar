#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
    printf 'Usage: ./scripts/release.sh patch|minor|major|X.Y.Z\n' >&2
    exit 1
fi
python3 scripts/version.py prepare "$1"
