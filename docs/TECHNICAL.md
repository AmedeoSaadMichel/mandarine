# Technical details

## Build from source

Requires Xcode command-line tools with Swift 5.9 or newer, Python 3, CMake, and pkg-config. Building the included FFmpeg runtime from source takes several minutes on the first build; later builds reuse it.

```sh
git clone https://github.com/AmedeoSaadMichel/mandarine.git
cd mandarine
swift test
./scripts/build-app.sh    # universal build/Mandarine.app
./scripts/build-dmg.sh    # dist/Mandarine-0.1.1-universal.dmg
```

Release version can be set with `VERSION=0.1.2 ./scripts/build-dmg.sh`. Generated bundles and disk images are excluded from Git; downloadable installers are attached to releases.

## Limitations

- No automatic updater yet; install future releases from this page.
- Available formats depend on the encoders included in the bundled FFmpeg build.
- Spreadsheet conversion uses the first sheet and does not preserve formulas, styling, or other sheets. EPUB conversion extracts text.
- No OCR, AI backgrounds, or support for XLS, PPT/PPTX, or Pages.
- Native processing limits and timeouts protect against oversized files.


## Included runtime and licenses

FFmpeg and ffprobe 9.0.2 are included as universal command-line helpers. Codec libraries are statically linked; only Apple system libraries are required. Mandarine prefers its bundled runtime, with external paths available for source builds. See [build recipe, component licenses, and corresponding sources](../vendor/ffmpeg/NOTICE.md).

For download verification and troubleshooting, see the [installation guide](INSTALL.md).
