# Privacy

macshot runs only on your Mac. It collects nothing and sends nothing.

## Network

- The app has no network entitlement. The App Sandbox blocks every outgoing connection, so a capture cannot leave the Mac through macshot, even through a bug.
- There is no telemetry, no crash reporting, no auto-updater and no upload service.
- The app links only Apple frameworks.
- **AI Search** in the OCR window opens your browser with a Google search for the recognized text. This happens only when you click it.

## Permissions

- **Screen Recording** (in System Settings: Screen & System Audio Recording) is required to capture the screen.
- **Accessibility** (on macOS 27: Device Control and Data Access) is asked for only when you use scroll capture's auto-scroll or element snapping.
- Element snapping does not change other apps by default. If you turn on **Settings → Capture → Turn on accessibility in Chromium and Electron apps for element snapping**, macshot asks those apps to build their full accessibility tree during a capture and turns it off again when the capture ends or macshot quits.
- macshot does not use the camera, the microphone, speech recognition or Input Monitoring.

## Data on your Mac

Everything is in the app's sandbox container, `~/Library/Containers/com.pgilad.macshot/`, except the captures you save to a folder you choose.

- **Saved captures** go to the save folder you choose. macshot keeps access to that folder with a security-scoped bookmark.
- **History** keeps the 10 most recent captures by default (Settings can change the number, make it unlimited or turn it off) in `Data/Library/Application Support/com.pgilad.macshot/history/`. The folder is readable only by you. To reopen a capture with editable annotations, history also keeps the image without annotations. When a capture has redactions (pixelate, blur, solid fill or erase), history keeps only the flattened image, so the redacted pixels cannot be recovered from it.
- **Settings** are in `Data/Library/Preferences/com.pgilad.macshot.plist`. Settings export leaves out your save folder and history.
- **The clipboard** is read only when you choose Pin from Clipboard, Open from Clipboard or paste into the editor. Copied captures contain image data only, never a file path.

## On-device processing

OCR, QR code reading, auto-redact, people and face detection, and background removal use Apple's Vision framework on this Mac.

## URL scheme

The `macshot://` URL scheme is off by default. When you turn it on in Settings, any app or web page can use it to start an interactive capture or open Settings. Nothing is saved, copied or shown without your action.
