#!/bin/bash
# Builds "MeshKit.app" into build/ (release, host architecture, ad-hoc signed).
#
#   UNIVERSAL=1 Scripts/build-app.sh                         # arm64 + x86_64
#   CONFIG=debug Scripts/build-app.sh                        # debug build
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh   # real signing (hardened runtime, timestamp)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/MeshKit.app"
CONFIG="${CONFIG:-release}"

ARCHS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi

swift build -c "$CONFIG" --product MeshKit ${ARCHS[@]+"${ARCHS[@]}"} >&2
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MeshKit" "$APP/Contents/MacOS/MeshKit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (the flasher stubs, SwiftProtobuf's privacy manifest) sit next to the executable.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# Extended attributes would be stored in zips as `._*` files, which ordinary unzip tools extract as extra files and so
# break the signature. Strip them before signing.
xattr -cr "$APP"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  # The app isn't sandboxed (it needs raw serial and mounted-volume access) and needs no special entitlements.
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP" >&2
else
  codesign --force --deep --sign - "$APP" >&2
fi
echo "Built: $APP" >&2
echo "$APP"
