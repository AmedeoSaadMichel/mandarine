<div align="center">

<img src="docs/images/icon.png" width="112" alt="Mandarine three-eyed mandarin icon">

# Mandarine

### A little universe for your files.

Convert, edit, and keep files close — with a drag, a key, and a three-eyed mandarin.

**[Download for Mac](https://github.com/AmedeoSaadMichel/mandarine/releases/latest/download/Mandarine-0.1.1-universal.dmg)** · [Installation help](docs/INSTALL.md) · [All releases](https://github.com/AmedeoSaadMichel/mandarine/releases) · [Buy me a coffee](https://buymeacoffee.com/asmichel)

macOS 13+ · Apple Silicon & Intel · Free & open source · English interface

</div>

## Install in a minute

1. **[Download Mandarine.dmg](https://github.com/AmedeoSaadMichel/mandarine/releases/latest/download/Mandarine-0.1.1-universal.dmg)** and open it.
2. Drag **Mandarine** onto **Applications**.
3. Eject the disk image and open **Mandarine** from Applications.
4. Find the three-eyed mandarin in your **menu bar**. Open its menu to access Settings, shelves, and file actions.

**First launch:** this initial community release is ad-hoc signed and **not notarized by Apple**. macOS may block it. After attempting to open it, go to **System Settings → Privacy & Security → Open Anyway**, if you trust this download. See [installation help](docs/INSTALL.md). No need to disable Gatekeeper.

## Drag. Tap. Done.

Start dragging a file, keep the mouse button held, then tap a modifier and drop onto a segment of the wheel.

| Default key | What opens | What you can do |
|---|---|---|
| **⇧ Shift** | Conversion wheel | Pick an output format. With multiple files, only compatible formats appear. |
| **⌘ Command** | Tools wheel | Crop, trim, compress, resize, edit metadata, and more. |
| **⌃ Control** | Actions wheel | Reveal in Finder, open, duplicate, copy files or paths, open Terminal, calculate SHA-256, or send to a shelf. |
| **⌥ Option** | Shelf | Collect files and carry them to another app or folder. |

**Using Control? Start dragging first, then press Control.** Control-click before a drag opens the macOS context menu.

Prefer clicking? Use the menu-bar icon → **Convert files…**, **Open tool for files…**, or **File actions…**.

Change a shortcut in **Settings → General** (wheels) or **Settings → Shelves**: click its key button and press Shift, Command, Control, or Option. **Esc** cancels. If a wheel and a shelf share a modifier, the wheel takes priority.

## A shelf for your next move

- Persistent shelves with **grid, list, and compact stack** views.
- Drag files in, then drag one file, a selection, or the whole stack out.
- Press **Space** for Quick Look; double-click to open a file.
- Dock a shelf to the left or right screen edge. It hides automatically and returns when you hover or drag over its tab.
- Optional **remove after a successful drag** removes shelf references, never the originals.
- Shelves, views, positions, and docking are restored when you reopen the app.

<img src="docs/images/shelf-stack.png" width="330" alt="Mandarine compact shelf with file previews and a yellow file counter">

## Tools for everyday files

| Files | Tools |
|---|---|
| Images | Photo editing, background, crop, redact, resize, rotate, collage, create PDF |
| Video | Trim, crop, change speed and speed zones, join, split, save frames, redact |
| Audio | Trim, normalize, visualizer, channels, bleep |
| PDF | Merge, split, reorder and rotate pages |
| Mixed files | Compress and edit metadata where supported |

Conversion covers images, text documents, spreadsheets, audio, and video. Available actions depend on the selected files and installed components. Existing output files are not overwritten; Mandarine adds a number to the new filename.

**FFmpeg is included.** The DMG contains FFmpeg, ffprobe, and the codec libraries for Apple Silicon and Intel. There is no Homebrew setup and no separate download. Open **Settings → Compatibility** to see the included runtime and available encoders.

This software uses [FFmpeg](https://ffmpeg.org), distributed with GPL components. Its [corresponding source archive](https://github.com/AmedeoSaadMichel/mandarine/releases/download/v0.1.1/Mandarine-FFmpeg-9.0.2-sources.tar.gz), build recipe, and [license notices](vendor/ffmpeg/NOTICE.md) are available alongside the installer.

## Made for your Mac

The Citrus interface brings plum surfaces, cream lettering, mint accents, and the three-eyed mascot to wheels, editors, shelves, and settings. Files are processed on your Mac. The core drag gesture does not require Accessibility or Input Monitoring permissions.

<img src="docs/images/settings-about.png" width="760" alt="Mandarine Citrus settings and Buy Me a Coffee banner">

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

## Support

Found a bug? [Open an issue](https://github.com/AmedeoSaadMichel/mandarine/issues) with your macOS version and the steps to reproduce it. Avoid uploading private files.

If Mandarine makes your day a little easier, [buy me a coffee](https://buymeacoffee.com/asmichel).

## License

[MIT](LICENSE) · © 2026 AmedeoSaadMichel. Lilita One is bundled under the [SIL Open Font License](Sources/Mandarine/Resources/LilitaOne-OFL.txt). Bundled FFmpeg is a separate command-line work distributed under GPL version 2 or later, with matching sources. Its codec libraries retain their own licenses; see [third-party notices](vendor/ffmpeg/NOTICE.md).
