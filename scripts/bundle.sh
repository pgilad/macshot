#!/bin/bash
# Builds macshot.app from source with the Command Line Tools (no Xcode needed) and signs it.
#
# Environment:
#   MACSHOT_SIGN_IDENTITY  Code signing identity. Default: "macshot Local Signing" if it is
#                          valid, else ad-hoc ("-"). See scripts/create-signing-identity.sh.
#   APP_DIR                Output path. Default: build/macshot.app
#   SWIFT_FLAGS            Extra flags for swift build, for example -Xswiftc -warnings-as-errors
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR=${APP_DIR:-build/macshot.app}
DEFAULT_IDENTITY="macshot Local Signing"

VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  COMMIT="$COMMIT-dirty"
fi

echo "==> Building macshot $VERSION ($BUILD, $COMMIT)"
# SWIFT_FLAGS holds several words, so it is not quoted.
# shellcheck disable=SC2086
swift build --configuration release --arch arm64 --product macshot ${SWIFT_FLAGS:-}
BIN_DIR=$(swift build --configuration release --arch arm64 --show-bin-path)

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/macshot" "$APP_DIR/Contents/MacOS/macshot"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__COMMIT__/$COMMIT/" \
  Resources/Info.plist > "$APP_DIR/Contents/Info.plist"
plutil -lint -s "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
iconutil --convert icns --output "$APP_DIR/Contents/Resources/AppIcon.icns" Resources/AppIcon.iconset
cp Resources/StatusBarIcon.png Resources/StatusBarIcon@2x.png Resources/PermissionsGuide.png \
  "$APP_DIR/Contents/Resources/"

IDENTITY=${MACSHOT_SIGN_IDENTITY:-}
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning | grep -q "\"$DEFAULT_IDENTITY\""; then
    IDENTITY="$DEFAULT_IDENTITY"
  else
    IDENTITY="-"
    echo "warning: no valid \"$DEFAULT_IDENTITY\" identity; signing ad-hoc." >&2
    echo "warning: with an ad-hoc signature, macOS forgets the Screen Recording permission after each rebuild." >&2
    echo "warning: run scripts/create-signing-identity.sh once to fix this." >&2
  fi
fi

echo "==> Signing with identity: $IDENTITY"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/macshot.entitlements \
  --sign "$IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "==> Done: $APP_DIR"
