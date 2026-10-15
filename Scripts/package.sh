#!/bin/bash
# Builds a release MeshKit.app and packages it as a zip and a DMG in build/.
#
#   Scripts/package.sh                       # universal (arm64 + x86_64), ad-hoc signed
#   UNIVERSAL=0 Scripts/package.sh           # this Mac's architecture only (faster)
#
# Release notes for Sparkle's update window and the GitHub release: write them once in a Markdown file and pass it in.
#   NOTES_FILE=notes.md Scripts/package.sh       # copied into the appcast; use the same file for `gh release create -F`
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

# Sparkle's feed: signed with the key in the login keychain (created once with Sparkle's generate_keys --account
# rip.bitstick.MeshKit). The app reads it from the latest release, so the file is uploaded with every release.
SPARKLE_BIN=$(swift build -c release --show-bin-path 2>/dev/null | sed 's#/\.build/.*#/.build#')/artifacts/sparkle/Sparkle/bin
APPCAST=$(mktemp -d); cp "$DIST/$NAME.zip" "$APPCAST/"
NOTES_FLAG=()
if [ -n "${NOTES_FILE:-}" ]; then
  [ -f "$NOTES_FILE" ] || { echo "NOTES_FILE not found: $NOTES_FILE" >&2; exit 1; }
  cp "$NOTES_FILE" "$APPCAST/$NAME.md"; NOTES_FLAG=(--embed-release-notes)
fi
"$SPARKLE_BIN/generate_appcast" --account rip.bitstick.MeshKit ${NOTES_FLAG[@]+"${NOTES_FLAG[@]}"} \
  --download-url-prefix "https://github.com/thebitstick/MeshKit/releases/download/v$VERSION/" \
  --link "https://github.com/thebitstick/MeshKit" "$APPCAST" >&2
cp "$APPCAST/appcast.xml" "$DIST/appcast.xml"; rm -rf "$APPCAST"

( cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt )
echo "Packaged:"; ls -lh "$DIST" | sed 's/^/  /'
lipo -archs "$APP/Contents/MacOS/MeshKit" 2>/dev/null | sed 's/^/  architectures: /'
