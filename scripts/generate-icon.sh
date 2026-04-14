#!/usr/bin/env bash
# Regenerate the FenixKanban app icon by compositing the phoenix logo
# over the kanban backdrop SVG.
#
# Sources (edit in scripts/ directory):
#   - scripts/phoenix-source.png  (the Blue Fenix logo, transparent PNG)
#   - scripts/icon-backdrop.svg   (dark gradient with kanban columns)
#
# Output:
#   - FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts"
OUT="$REPO_ROOT/FenixKanban/Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v magick >/dev/null 2>&1; then
    echo "Error: ImageMagick 'magick' command not found. Install with: brew install imagemagick" >&2
    exit 1
fi

echo "Rendering backdrop from SVG..."
magick "$SCRIPTS/icon-backdrop.svg" -resize 1024x1024 "$TMP/backdrop.png"

echo "Scaling phoenix..."
magick "$SCRIPTS/phoenix-source.png" -filter Lanczos -resize 700x700 "$TMP/phoenix.png"

echo "Compositing final icon..."
magick "$TMP/backdrop.png" "$TMP/phoenix.png" \
    -gravity center -compose over -composite \
    "$OUT"

echo "Done: $OUT"
