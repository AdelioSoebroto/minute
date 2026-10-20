#!/bin/zsh
# Package Minute for other Macs: build, sign, (optionally) notarize, and zip.
#   ./release.sh                       signs with "Minute Local" (works on your own Macs)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=minute ./release.sh
#       signs with your Apple Developer ID and notarizes (create the profile once with: xcrun notarytool store-credentials minute)
# Without a Developer ID the zip still runs elsewhere, but macOS Gatekeeper asks the person to allow it once (right-click > Open).
set -e
cd "${0:A:h}"
./build.sh
APP=build/Minute.app
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="build/Minute-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "$SIGN_ID" && -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarized."
else
  echo "Not notarized (no SIGN_ID / NOTARY_PROFILE). Recipients: right-click Minute.app > Open the first time."
fi
echo "Created $ZIP"
