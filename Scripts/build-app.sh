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

ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/MeshKit"

# Extended attributes would be stored in zips as `._*` files, which ordinary unzip tools extract as extra files and so
# break the signature. Strip them before signing.
xattr -cr "$APP"

# Sparkle's helpers are signed first, then the framework, then the app. The app isn't sandboxed (it needs raw serial
# and mounted-volume access) and needs no special entitlements.
if [ -n "${SIGN_IDENTITY:-}" ]; then SIGN=(--options runtime --timestamp --sign "$SIGN_IDENTITY"); else SIGN=(--sign -); fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$SPARKLE"/XPCServices/*.xpc "$SPARKLE/Updater.app" "$SPARKLE/Autoupdate" "$APP/Contents/Frameworks/Sparkle.framework" "$APP"; do
  codesign --force "${SIGN[@]}" "$nested" >&2
done
echo "Built: $APP" >&2
echo "$APP"
