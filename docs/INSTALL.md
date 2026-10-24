# Install Mandarine

## Requirements

- macOS 13 Ventura or later.
- Apple Silicon or Intel Mac. The DMG contains a universal application.
- FFmpeg and its codec libraries are included. No Homebrew or separate FFmpeg installation is needed.

## Download and install

1. Get the DMG from the [latest release](https://github.com/AmedeoSaadMichel/mandarine/releases/latest).
2. Open it and drag **Mandarine.app** to the **Applications** shortcut inside the disk image.
3. Eject the disk image. Launch Mandarine from **Applications**, not from the DMG.
4. Look for the mandarin icon in the menu bar. Use **Settings…** to configure it.

## macOS blocks the app

This first release is ad-hoc signed, not signed with an Apple Developer ID or notarized by Apple. See [Apple’s guidance on safely opening downloaded apps](https://support.apple.com/102445).

After trying to open Mandarine, open **System Settings → Privacy & Security**. Scroll to the security section, click **Open Anyway**, and confirm the launch if you trust the download. This exception applies to this app; do not turn off Gatekeeper globally. The option may be restricted on managed Macs.

If macOS reports the app is damaged, download a fresh copy from the release. If it still fails, report the exact message and macOS version in an issue rather than removing security attributes with Terminal commands.

## Verify the download

A `.sha256` file is attached alongside the DMG. Download both to the same folder and run:

```sh
cd ~/Downloads
shasum -a 256 -c Mandarine-0.1.1-universal.dmg.sha256
```

The expected result is `OK`. A checksum verifies file integrity; it is not a substitute for Apple notarization.

## Included audio/video support

The installer contains FFmpeg 9.0.2 and ffprobe, built for Apple Silicon and Intel. Open **Settings → Compatibility**: FFmpeg should show **Included with Mandarine**. The bundled helpers use only Apple system libraries; you do not need to install Homebrew or any codec package.

Licenses are included inside `Mandarine.app/Contents/Resources/FFmpeg`. The complete corresponding [source archive](https://github.com/AmedeoSaadMichel/mandarine/releases/download/v0.1.1/Mandarine-FFmpeg-9.0.2-sources.tar.gz) is attached to the same release, with [build instructions and notices](../vendor/ffmpeg/NOTICE.md).

If FFmpeg is reported missing, replace the app with a fresh copy from the latest DMG.

## First gesture

Start dragging a Finder file, then tap **Shift** for conversions, **Command** for tools, **Control** for actions, or **Option** for a shelf. Keep the mouse button held until you drop on the chosen target.

Always start dragging **before** pressing Control, otherwise macOS opens the context menu. Shortcuts are customizable in Settings. The equivalent actions are available from the menu-bar menu without dragging.

## Update or uninstall

Quit Mandarine before replacing it in Applications with a newer download. To uninstall, quit and move Mandarine.app from Applications to Trash. Shelf references and preferences may remain in your user Library; uninstalling the app does not delete the original files placed on shelves.
