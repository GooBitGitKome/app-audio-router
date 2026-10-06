#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
STAGING_DIR="$DIST_DIR/AppAudioRouter"
ARCHIVE_PATH="$DIST_DIR/AppAudioRouter-macOS.zip"

"$SCRIPT_DIR/package_app.sh"

rm -rf "$STAGING_DIR" "$ARCHIVE_PATH"
mkdir -p "$STAGING_DIR"
ditto "$PROJECT_DIR/AppAudioRouter.app" "$STAGING_DIR/AppAudioRouter.app"
ditto "$PROJECT_DIR/BrowserExtension" "$STAGING_DIR/BrowserExtension"
cp "$PROJECT_DIR/docs/installation.md" "$STAGING_DIR/INSTALL-ja.md"

(
  cd "$DIST_DIR"
  ditto -c -k --sequesterRsrc --keepParent "AppAudioRouter" "AppAudioRouter-macOS.zip"
)

echo "==> Release archive created: $ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH"
