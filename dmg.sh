#!/bin/zsh
# Packages an existing signed app; does not rebuild or increment its version.
# Usage: CODESIGN_IDENTITY="Apple Development: ..." ./dmg.sh [path/to/Vitals.app]
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-build/Vitals.app}"
[[ -d "$APP" ]] || { echo "App bundle not found: $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
VERSION="$SHORT_VERSION.$BUILD_NUMBER"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Invalid version: $VERSION" >&2; exit 1; }
mkdir -p build
OUTPUT="$PWD/build/Vitals-$VERSION.dmg"
[[ ! -e "$OUTPUT" ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }

DMG_WORK=$(mktemp -d "${TMPDIR:-/tmp}/vitals-dmg.XXXXXX")
MOUNTED=0
cleanup() {
    if [[ "$MOUNTED" == 1 ]]; then
        if ! hdiutil detach "$DMG_WORK/mounted" -quiet; then
            echo "Could not detach image; temporary files retained at $DMG_WORK" >&2
            return
        fi
    fi
    rm -rf "$DMG_WORK"
}
trap cleanup EXIT

mkdir "$DMG_WORK/source" "$DMG_WORK/mounted"
/usr/bin/ditto "$APP" "$DMG_WORK/source/Vitals.app"
ln -s /Applications "$DMG_WORK/source/Applications"
codesign --verify --deep --strict "$DMG_WORK/source/Vitals.app"

# HFS+ and zlib compression support all macOS versions supported by Vitals.
hdiutil create -volname "Vitals $VERSION" -srcfolder "$DMG_WORK/source" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_WORK/Vitals.dmg"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_WORK/Vitals.dmg"
    codesign --verify --strict "$DMG_WORK/Vitals.dmg"
fi
hdiutil verify "$DMG_WORK/Vitals.dmg"
hdiutil attach "$DMG_WORK/Vitals.dmg" -readonly -nobrowse -mountpoint "$DMG_WORK/mounted" -quiet
MOUNTED=1
codesign --verify --deep --strict "$DMG_WORK/mounted/Vitals.app"
[[ "$(readlink "$DMG_WORK/mounted/Applications")" == /Applications ]]
cmp "$APP/Contents/Info.plist" "$DMG_WORK/mounted/Vitals.app/Contents/Info.plist"
for BINARY in Contents/MacOS/Vitals Contents/MacOS/VitalsHelper Contents/Library/LaunchServices/online.equishow.vitals.helper; do
    cmp "$APP/$BINARY" "$DMG_WORK/mounted/Vitals.app/$BINARY"
done
hdiutil detach "$DMG_WORK/mounted" -quiet
MOUNTED=0
mv "$DMG_WORK/Vitals.dmg" "$OUTPUT"
(cd build && shasum -a 256 "Vitals-$VERSION.dmg" > "Vitals-$VERSION.dmg.sha256")
echo "Verified DMG: $OUTPUT"
