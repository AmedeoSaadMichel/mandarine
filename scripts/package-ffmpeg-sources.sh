#!/bin/zsh
# Publish the complete matching sources beside every installer containing FFmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
ARCHIVE=Mandarine-FFmpeg-9.0.2-sources.tar.gz
COPYFILE_DISABLE=1 tar -czf "dist/$ARCHIVE" scripts/build-ffmpeg.py vendor/ffmpeg/sources.json vendor/ffmpeg/NOTICE.md vendor/ffmpeg/licenses vendor/ffmpeg/sources
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Created dist/$ARCHIVE"
