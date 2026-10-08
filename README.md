<p align="center">
  <img src="assets/logo.svg" alt="macshot logo" width="160">
</p>

<h1 align="center">macshot</h1>

<p align="center">A private screenshot and annotation tool for macOS.</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#keyboard">Keyboard</a> ·
  <a href="#privacy">Privacy</a>
</p>

macshot freezes the screen, lets you select an area, window or display, and gives you annotation tools before you copy, save or pin the result. This fork of [sw33tLie/macshot](https://github.com/sw33tLie/macshot) keeps the screenshot tool and removes everything that records, uploads or connects to the network.

## Install

Requires macOS 26 or later on Apple silicon. Build from source with the Command Line Tools (`xcode-select --install`). Xcode is not needed.

```fish
git clone https://github.com/pgilad/macshot.git
cd macshot
make signing-identity   # once per Mac
make install            # build, sign, copy to /Applications and start
```

`make signing-identity` creates a local code-signing certificate, so macOS keeps the Screen Recording permission after each rebuild. On first start, grant **Screen Recording** (in System Settings: **Screen & System Audio Recording**). Scroll capture's auto-scroll and element snapping also ask for **Accessibility** (on macOS 27: **Device Control and Data Access**).

To update, run `git pull` and `make install`.

## Features

- Capture an area, a window (with transparent corners), a full display or the last area again. Selections can span displays.
- Freeze transient UI: menus and Spotlight-style panels stay in the capture.
- Annotate with arrows, lines, shapes, text, pencil, marker, numbered steps, emoji stamps, a pixel ruler, a magnifier and a spotlight. Click any annotation to move, resize, rotate or restyle it.
- Redact with pixelate, blur, solid fill or erase, or let auto-redact find emails, phone numbers, card numbers and API keys.
- Read text and QR codes with on-device OCR.
- Scroll capture stitches a long page into one image.
- Beautify with a window frame, shadow and gradient backdrop, or adjust brightness, contrast and color.
- Remove the background of a subject, and invert colors.
- Pin a capture as a floating window, or keep it in the floating thumbnail.
- Open a capture in the editor window to crop, flip, zoom, add more captures or paste images.
- Browse recent captures and reopen them with their annotations still editable.
- Save as PNG, JPEG, HEIC or AVIF, with filename templates and subfolders.

## Keyboard

Global shortcuts (change or add more in **Settings → Shortcuts**):

| Key | Action |
| --- | --- |
| <kbd>⇧⌘X</kbd> | Capture an area |

Full screen, OCR, quick capture, scroll capture, history and pin from clipboard have no default shortcut, so macshot does not take common app shortcuts such as <kbd>⇧⌘T</kbd> or <kbd>⇧⌘S</kbd>.

During a capture:

| Key | Action |
| --- | --- |
| <kbd>↩</kbd> | Confirm (copy or save, as set in Settings) |
| <kbd>⌘C</kbd> / <kbd>⌘S</kbd> | Copy / save |
| <kbd>⌘Z</kbd> / <kbd>⇧⌘Z</kbd> | Undo / redo |
| <kbd>⇥</kbd> | Turn window snapping on or off |
| <kbd>F</kbd> before you select | Select the full screen |
| <kbd>⇧</kbd> while drawing | Straight lines and regular shapes |
| <kbd>Space</kbd> while drawing | Move the shape |
| <kbd>⌫</kbd> | Delete the selected annotation |
| <kbd>⎋</kbd> | Cancel |

Tools have single-key shortcuts after you select an area: <kbd>A</kbd> arrow, <kbd>L</kbd> line, <kbd>P</kbd> pencil, <kbd>M</kbd> marker, <kbd>R</kbd> rectangle, <kbd>O</kbd> ellipse, <kbd>T</kbd> text, <kbd>N</kbd> number, <kbd>B</kbd> censor, <kbd>H</kbd> spotlight, <kbd>I</kbd> color sampler, <kbd>G</kbd> stamp, <kbd>S</kbd> auto-adjust the selection, <kbd>E</kbd> open in the editor, <kbd>F</kbd> pin. Change them in **Settings → Shortcuts**.

## Privacy

- No network access. The app has no network entitlement, so the App Sandbox blocks every outgoing connection. There is no telemetry, no auto-updater and no upload.
- OCR, QR reading, auto-redact and background removal run on this Mac with Apple's Vision framework.
- The app links only Apple frameworks.
- Captures stay in the app container and the save folder you choose. History keeps the 10 most recent captures by default. A capture with redactions is kept only flattened, so the redacted pixels cannot be recovered from history.
- The `macshot://` URL scheme is off by default. When on, it can only start an interactive capture or open Settings.

See [PRIVACY.md](PRIVACY.md) for the details.

## About this fork

This fork started from macshot 4.4.0-beta.6 by sw33tLie. It removes screen recording and the video editor, uploads to imgbb, Google Drive and S3, OCR translation, Sparkle auto-update, rich-text clipboard pins, WebP saving, translations of the app, and all third-party Swift packages. It requires macOS 26 and builds with SwiftPM. Its bundle ID is `com.pgilad.macshot`, so it does not share data or permissions with upstream macshot.

## Development

```fish
make test   # unit tests (Swift Testing)
make app    # release build in build/macshot.app
make run    # build and start build/macshot.app
```

The tests run headless: they need no Screen Recording permission and no windows.

## License

GPLv3. See [LICENSE](LICENSE).
