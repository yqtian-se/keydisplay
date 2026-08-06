#!/bin/bash
# Build KeyDisplay.app from main.swift
set -euo pipefail
cd "$(dirname "$0")"

APP=KeyDisplay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/KeyDisplay"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>KeyDisplay</string>
    <key>CFBundleIdentifier</key><string>local.yqtian.keydisplay</string>
    <key>CFBundleName</key><string>KeyDisplay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with the self-signed "KeyDisplay Dev" cert so the app's identity — and its
# Input Monitoring permission — survives rebuilds. Falls back to ad-hoc if missing.
codesign --force --sign "KeyDisplay Dev" "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo "Built $APP"
