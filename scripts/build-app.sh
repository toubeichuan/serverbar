#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release \
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." \
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/ServerBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ServerBar" "$APP/Contents/MacOS/ServerBar"
# Drop debugger symbol records containing local object/module paths before signing.
xcrun strip -S "$APP/Contents/MacOS/ServerBar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ServerBar</string>
<key>CFBundleDisplayName</key><string>ServerBar</string>
<key>CFBundleIdentifier</key><string>local.gpumonitor.mac</string>
<key>CFBundleExecutable</key><string>ServerBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>8</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>ServerBar</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Synced Documents folders can attach Finder metadata to new bundles.
# Remove only signing-incompatible metadata from this generated build artifact.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
