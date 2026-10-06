#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building AppAudioRouter in release mode..."
cd "$PROJECT_DIR"
swift build -c release --product AppAudioRouterApp

BIN_PATH="$PROJECT_DIR/.build/release/AppAudioRouterApp"
APP_BUNDLE="$PROJECT_DIR/AppAudioRouter.app"

echo "==> Creating macOS App Bundle at $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/AppAudioRouterApp"

cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AppAudioRouterApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.devai.AppAudioRouter</string>
    <key>CFBundleName</key>
    <string>AppAudioRouter</string>
    <key>CFBundleDisplayName</key>
    <string>AppAudioRouter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>AppAudioRouter requires microphone and audio routing permissions to manage application audio streams.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>AppAudioRouter requires audio capture permission to tap and redirect per-application audio.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

"$SCRIPT_DIR/create_app_icon.sh" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing app bundle with ad-hoc signature..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> App bundle created successfully: $APP_BUNDLE"
