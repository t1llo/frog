#!/bin/bash
# Pictures of every surface of Frog in light and dark, for a design review: `<surface>-<light|dark>.png` in the folder.
# Drawn without windows from isolated sample data (UIShotsTests); never touches this Mac's Frog data or settings.
#   scripts/ui-shots.sh <output-folder> [surface,prefix-,…]
# FROG_UI_SHOTS_SIZE=800x520 draws the window's pages at that size instead of the default window size.
set -euo pipefail
if [[ $# -lt 1 ]]; then
    echo "usage: $0 <output-folder> [surface,prefix-,…]" >&2
    exit 64
fi
mkdir -p "$1"
folder="$(cd "$1" && pwd)"
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export FROG_UI_SHOTS="$folder"
if [[ $# -ge 2 ]]; then export FROG_UI_SHOTS_ONLY="$2"; fi
swift test --filter 'FrogAppTests.UIShotsTests/testEverySurface'
count=$(find "$folder" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
echo "$count pictures in $folder"
