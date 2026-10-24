# FFmpeg included with Mandarine

Starting with Mandarine 0.1.1, the DMG contains standalone universal **FFmpeg 9.0.2** and **ffprobe 9.0.2** in `Mandarine.app/Contents/Helpers`. No Homebrew or separate runtime installation is required.

Mandarine runs these independent command-line executables as subprocesses; it does not link its Swift application against libav*. Mandarine's own code remains under the MIT License. FFmpeg is a separate work, built with GPL components, and is distributed under **GPL version 2 or later**. x264 is GPL-licensed; other bundled codecs retain their own licenses. No `--enable-nonfree` components are included.

## Corresponding sources and rebuild instructions

The **Mandarine-FFmpeg-9.0.2-sources.tar.gz** asset attached to [release 0.1.1](https://github.com/AmedeoSaadMichel/mandarine/releases/tag/v0.1.1) contains the complete, unmodified source archives for FFmpeg and every third-party library compiled into the helpers, pinned SHA-256 hashes, and the exact build recipe. The same server hosts the DMG and corresponding source archive. Licenses are included in the source archives and in `Mandarine.app/Contents/Resources/FFmpeg/licenses`.

The upstream download URLs and content hashes are recorded in [sources.json](sources.json). FFmpeg upstream: <https://ffmpeg.org>. Licensing information: <https://ffmpeg.org/legal.html>.

To reproduce with Xcode command-line tools, Python 3, CMake, and pkg-config installed:

1. Extract the source archive.
2. Run `python3 scripts/build-ffmpeg.py` from its root.
3. The script verifies each archive, builds the host assembler, and compiles x264, LAME, Opus, libvpx, WebP, AOM, FFmpeg and ffprobe for macOS 13 on arm64 and x86_64.
4. `vendor/ffmpeg/universal` contains the universal helpers. `build/ffmpeg/<arch>/ffmpeg/configure.log` records the configuration invocation; configure/make logs and generated configuration files remain in `build/ffmpeg`.

The recipe disables automatic discovery of host libraries and checks that the finished executables link only against Apple system libraries/frameworks. Codec dependencies are statically included. Network protocols and device capture are disabled; the helpers process local files.

No restrictions are imposed on replacing, modifying, rebuilding, or redistributing the GPL/LGPL components under their license terms. These programs are supplied without warranty, as described in their licenses. Codec patent rights are distinct from copyright licenses.
