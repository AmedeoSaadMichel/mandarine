#!/bin/zsh
# Build a universal app, then package a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.1}
export VERSION
./scripts/build-app.sh
./scripts/check-bundled-runtime.sh
APP="$PWD/build/Mandarine.app"
ARTIFACT="Mandarine-${VERSION}-universal.dmg"
mkdir -p dist
STAGING=$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
# ditto preserves bundle permissions, symlinks, and extended attributes.
ditto "$APP" "$STAGING/Mandarine.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Install Mandarine.txt" <<'TXT'
INSTALL MANDARINE

1. Drag Mandarine.app onto Applications.
2. Eject this disk image.
3. Open Mandarine from Applications. Look for the three-eyed mandarin in the menu bar.

Requires macOS 13 Ventura or later. Apple Silicon and Intel are supported.
This community build is ad-hoc signed and is not notarized by Apple.
If macOS blocks the first launch, use System Settings > Privacy & Security > Open Anyway
only if you trust this download. Do not disable Gatekeeper.

First steps: drag a file, then tap Shift for Conversion, Command for Tools,
Control for Actions, or Option for a shelf. With Control, begin dragging BEFORE pressing it.
All four shortcuts can be changed in Settings.

FFmpeg and its codec libraries are included inside Mandarine.app.
No Homebrew installation or separate FFmpeg download is needed.
Check Settings > Compatibility for the tools available on your Mac.
Licenses are included inside the app; matching sources are attached to the GitHub release.

Downloads, source code, and installation help:
https://github.com/AmedeoSaadMichel/mandarine
TXT
codesign --verify --deep --strict "$STAGING/Mandarine.app"
lipo "$STAGING/Mandarine.app/Contents/MacOS/Mandarine" -verify_arch arm64 x86_64
for HELPER in ffmpeg ffprobe; do
  lipo "$STAGING/Mandarine.app/Contents/Helpers/$HELPER" -verify_arch arm64 x86_64
done
# Reserve filesystem overhead explicitly for the larger bundled runtime.
IMAGE_KB=$(( $(du -sk "$STAGING" | awk '{print $1}') * 12 / 10 + 65536 ))
hdiutil create -volname "Mandarine" -srcfolder "$STAGING" -fs HFS+ -size "${IMAGE_KB}k" -ov -format UDZO "dist/$ARTIFACT"
(cd dist && shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256")
./scripts/package-ffmpeg-sources.sh
echo "Created dist/$ARTIFACT"
