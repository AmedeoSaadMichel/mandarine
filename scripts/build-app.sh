#!/bin/zsh
# Builds Mandarine.app into ./build
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}
# Universal builds run natively on both Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=build/Mandarine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ${BIN_DIR}/Mandarine "$APP/Contents/MacOS/Mandarine"
if [[ -d ${BIN_DIR}/Mandarine_Mandarine.bundle ]]; then
  cp -R ${BIN_DIR}/Mandarine_Mandarine.bundle "$APP/Contents/Resources/"
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Sources/Mandarine/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mandarine</string>
<key>CFBundleIdentifier</key><string>dev.local.Mandarine</string>
<key>CFBundleName</key><string>Mandarine</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
