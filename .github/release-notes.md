## Install

Requires macOS 26 or later on Apple silicon.

1. Download `macshot-__VERSION__-arm64.zip` below. Open it and move **macshot** to **Applications**.
2. Open macshot. macOS blocks the first start, because the app is not notarized. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Grant **Screen Recording** (in System Settings: **Screen & System Audio Recording**). Scroll capture's auto-scroll and element snapping also ask for **Accessibility** (on macOS 27: **Device Control and Data Access**).

To update, quit macshot and replace the app. If macOS blocks the new version, do step 2 again. macshot makes no network requests, so it does not check for updates: watch this repository's releases. All releases are signed with the same certificate, so macOS keeps the permissions.

If you used a build from source before, macOS does not apply its permissions to a release. Remove macshot from the Screen Recording list (and the Accessibility list) and add it again.

## Verify the download

```sh
shasum -a 256 -c macshot-__VERSION__-arm64.zip.sha256
gh attestation verify macshot-__VERSION__-arm64.zip --repo pgilad/macshot
```
