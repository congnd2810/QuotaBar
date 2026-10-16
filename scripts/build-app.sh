#!/bin/sh
# Builds a release binary and wraps it in build/QuotaBar.app (menu bar only, ad-hoc signed).
set -eu

cd "$(dirname "$0")/.."
swift build -c release

APP=build/QuotaBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/QuotaBar" "$APP/Contents/MacOS/QuotaBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate with scripts/generate-icon.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>QuotaBar</string>
    <key>CFBundleIdentifier</key><string>asia.solarapp.quotabar</string>
    <key>CFBundleName</key><string>QuotaBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
