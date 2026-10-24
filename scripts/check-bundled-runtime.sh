#!/bin/zsh
# Exercise the shipped app and helpers with PATH restricted to macOS system tools.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Mandarine.app"
FF="$APP/Contents/Helpers/ffmpeg"
PROBE="$APP/Contents/Helpers/ffprobe"
BIN="$APP/Contents/MacOS/Mandarine"
CHECK=$(mktemp -d /private/tmp/mandarine-runtime-check.XXXXXX)
trap 'rm -rf "$CHECK"' EXIT
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
codesign --verify --deep --strict "$APP"
for TOOL in "$FF" "$PROBE"; do
  lipo "$TOOL" -verify_arch arm64 x86_64
  otool -L "$TOOL" | awk '/compatibility version/ && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { print "External dependency: " $1; bad=1 } END { exit bad }'
done
"$FF" -hide_banner -loglevel error -f lavfi -i sine=frequency=440:duration=0.3 "$CHECK/tone.wav"
"$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=size=64x64:rate=10 -t 0.3 -c:v libx264 -pix_fmt yuv420p "$CHECK/clip.mp4"
"$FF" -hide_banner -loglevel error -i "$CHECK/clip.mp4" -frames:v 1 "$CHECK/still.png"
for FORMAT in mp3 opus ogg; do
  "$BIN" --convert "$CHECK/tone.wav" "$FORMAT"
  test -s "$CHECK/tone.$FORMAT"
  "$PROBE" -v error -show_entries format=duration -of default=nw=1 "$CHECK/tone.$FORMAT"
done
"$BIN" --convert "$CHECK/clip.mp4" webm
test -s "$CHECK/clip.webm"
for FORMAT in webp avif; do
  "$BIN" --convert "$CHECK/still.png" "$FORMAT"
  test -s "$CHECK/still.$FORMAT"
  "$PROBE" -v error -show_entries stream=codec_name -of default=nw=1 "$CHECK/still.$FORMAT"
done
echo "Bundled audio, video and image conversions passed."
