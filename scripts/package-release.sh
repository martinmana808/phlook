#!/bin/bash
# Builds a UNIVERSAL (Apple Silicon + Intel), ad-hoc-signed, zipped Phlook.app
# ready to attach to a GitHub Release. Unlike scripts/bundle-app.sh (fast, host-
# arch only, for local dev), this produces the artifact a stranger downloads:
#   • universal2 binary   → runs on both arm64 and x86_64 Macs
#   • ad-hoc code signature → app is internally consistent so Gatekeeper's only
#                             gripe is "unidentified developer" (bypassable),
#                             not "damaged" (a broken/altered bundle)
#   • ditto zip           → preserves the bundle exactly (resource forks, symlinks)
#
# NOT notarized (needs a paid Apple Developer ID). First-launch instructions for
# the downloader live on the landing page and the GitHub Release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "building universal release (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Phlook"
file "$BIN"

APP="Phlook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Phlook"
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

echo "ad-hoc signing…"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p dist
rm -f dist/Phlook.zip
echo "zipping (ditto)…"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Phlook.zip

echo "built ./$APP  →  ./dist/Phlook.zip"
ls -lh dist/Phlook.zip
