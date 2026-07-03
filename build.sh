#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="ClaudeSessions"
BUNDLE="build/$APP.app"
VERSION="$(tr -d ' \t\r\n' < VERSION 2>/dev/null || echo 1.0)"

echo "Compiling… (v$VERSION)"
mkdir -p build
swiftc -O ClaudeSessions.swift -o "build/$APP" -framework Cocoa

echo "Building .app bundle…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mv "build/$APP" "$BUNDLE/Contents/MacOS/$APP"

# bundle the state hook + updater so the installed app is self-contained
cp hook.sh "$BUNDLE/Contents/Resources/hook.sh"
chmod +x "$BUNDLE/Contents/Resources/hook.sh"
cp update.sh "$BUNDLE/Contents/Resources/update.sh"
chmod +x "$BUNDLE/Contents/Resources/update.sh"

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Sessions</string>
  <key>CFBundleDisplayName</key><string>Claude Sessions</string>
  <key>CFBundleIdentifier</key><string>com.christiancannata.claudesessions</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
EOF

# ad-hoc sign so macOS lets it run
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "Done: $BUNDLE"
