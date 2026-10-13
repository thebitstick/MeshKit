#!/bin/bash
# Builds a release MeshKit.app and packages it as a zip and a DMG in build/.
#
#   Scripts/package.sh                       # universal (arm64 + x86_64), ad-hoc signed
#   UNIVERSAL=0 Scripts/package.sh           # this Mac's architecture only (faster)
#
# To sign and notarise (needs an Apple Developer account; not exercised by the project's tests):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=meshkit-notary \          # created once with: xcrun notarytool store-credentials meshkit-notary
#   Scripts/package.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
export UNIVERSAL=${UNIVERSAL:-1}
APP=$(Scripts/build-app.sh | tail -1)

DIST=build/release
rm -rf "$DIST"; mkdir -p "$DIST"
NAME="MeshKit-$VERSION"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_IDENTITY:-}" ] || { echo "NOTARY_PROFILE needs SIGN_IDENTITY too" >&2; exit 1; }
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$DIST/notarize.zip"
fi

# Zip: what most people will download. No extended attributes or resource forks go in, so any unzip tool (not just
# Finder) produces an app whose signature still verifies.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$DIST/$NAME.zip"

# DMG: the app next to an Applications shortcut.
STAGE=$(mktemp -d)
ditto --norsrc --noextattr "$APP" "$STAGE/MeshKit.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "MeshKit $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg"
rm -rf "$STAGE"

# Prove it: unpack with the stock unzip (which, unlike Finder, doesn't merge AppleDouble files) and verify the signature.
CHECK=$(mktemp -d); unzip -q "$DIST/$NAME.zip" -d "$CHECK"
codesign --verify --deep --strict "$CHECK/MeshKit.app" && echo "  signature verifies after a plain unzip"
rm -rf "$CHECK"

( cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt )
echo "Packaged:"; ls -lh "$DIST" | sed 's/^/  /'
lipo -archs "$APP/Contents/MacOS/MeshKit" 2>/dev/null | sed 's/^/  architectures: /'
