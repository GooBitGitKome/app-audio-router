#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$PROJECT_DIR/Assets/AppIcon.png"
OUTPUT="${1:?Usage: create_app_icon.sh <output.icns>}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/app-audio-router-icon.XXXXXX")"
ICONSET="$TMP_ROOT/AppIcon.iconset"

trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -s format png -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "$OUTPUT" "$ICONSET"
echo "==> App icon created: $OUTPUT"
