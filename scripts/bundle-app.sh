#!/bin/bash
# Builds a proper double-clickable Phlook.app bundle from the SPM executable.
# A real .app launches like a normal macOS app (Dock icon, correct Space
# behavior, foregrounds properly) — unlike `swift run`, which opens a stray
# window that gets lost behind a full-screen terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
echo "building ($CONFIG)…"
swift build -c "$CONFIG"

APP="Phlook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Phlook" "$APP/Contents/MacOS/Phlook"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Phlook</string>
  <key>CFBundleDisplayName</key><string>PHLOOK</string>
  <key>CFBundleIdentifier</key><string>com.martinmana.phlook</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>Phlook</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
echo "built ./$APP  —  launch with:  open ./$APP"
