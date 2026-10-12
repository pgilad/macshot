## Install

Requires macOS 26 or later on Apple silicon.

1. Download `macshot-__VERSION__-arm64.zip` below. Open it and move **macshot** to **Applications**.
2. Open macshot. macOS blocks the first start, because the app is not notarized. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Grant **Screen Recording** (in System Settings: **Screen & System Audio Recording**). Scroll capture's auto-scroll and element snapping also ask for **Accessibility** (on macOS 27: **Device Control and Data Access**).

To update, quit macshot and replace the app. If macOS blocks the new version, do step 2 again. macshot checks GitHub once a day and tells you when a new release is out. To turn this off, go to **Settings → About**.

This release uses the bundle ID `com.giladpeleg.macshot` and the shared `Gilad Peleg Local Signing` identity used by local builds. Compared with the former `com.pgilad.macshot` builds, it has a separate sandbox for history and settings and needs new Screen Recording and Accessibility grants. Your previous data remains in the old container; it is not migrated automatically.

## Verify the download

```fish
shasum -a 256 -c macshot-__VERSION__-arm64.zip.sha256
gh attestation verify macshot-__VERSION__-arm64.zip --repo pgilad/macshot
```
