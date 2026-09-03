#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
DMG_PATH="$DIST_DIR/SSBNK-Client.dmg"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "build-dmg.sh must run on macOS." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "build-dmg.sh requires an Apple Silicon Mac (arm64)." >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Set DEVELOPER_ID_APPLICATION to the Developer ID Application signing identity." >&2
    exit 1
fi
if [[ "$SIGN_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "DEVELOPER_ID_APPLICATION must name a Developer ID Application identity, not an ad-hoc or development identity." >&2
    exit 1
fi
AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
if ! grep -Fq -- "\"$SIGN_IDENTITY\"" <<< "$AVAILABLE_IDENTITIES"; then
    echo "The requested Developer ID Application identity is not available in this login keychain: $SIGN_IDENTITY" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssbnk-client-package.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
APP_DIR="$WORK_DIR/dmg/SSBNK Client.app"
APP_CONTENTS="$APP_DIR/Contents"

cleanup() {
    if mount | grep -Fq "on $MOUNT_DIR "; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cd "$PROJECT_DIR"
swift test
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$WORK_DIR/dmg" "$DIST_DIR"
ditto "$BIN_DIR/SSBNKClient" "$APP_CONTENTS/MacOS/SSBNKClient"
ditto "$PROJECT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
chmod 0755 "$APP_CONTENTS/MacOS/SSBNKClient"

codesign \
    --force \
    --deep \
    --strict \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ln -s /Applications "$WORK_DIR/dmg/Applications"
hdiutil create \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -volname "SSBNK Client" \
    -srcfolder "$WORK_DIR/dmg" \
    "$DMG_PATH"
codesign \
    --force \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

mkdir -p "$MOUNT_DIR"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" -quiet
test -x "$MOUNT_DIR/SSBNK Client.app/Contents/MacOS/SSBNKClient"
codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/SSBNK Client.app"
hdiutil detach "$MOUNT_DIR" -quiet

echo "Created and verified: $DMG_PATH"
