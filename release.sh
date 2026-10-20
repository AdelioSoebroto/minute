#!/bin/zsh
# Package Minute for other Macs: test, build, sign, (optionally) notarize, zip, and write the release notes.
#   ./release.sh                       signs with "Minute Local" (works on your own Macs)
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=minute ./release.sh
#       signs with your Apple Developer ID and notarizes (create the profile once with: xcrun notarytool store-credentials minute)
# Every release needs a section in CHANGELOG.md for the version in VERSION; the script refuses to continue without it.
# Without a Developer ID the zip still runs elsewhere, but macOS Gatekeeper asks the person to allow it once (right-click > Open).
set -e
cd "${0:A:h}"
VERSION=$(tr -d '[:space:]' < VERSION)
NOTES=$(awk -v v="[$VERSION]" '/^## /{ if (found) exit; found = index($0, v) > 0; next } found' CHANGELOG.md)
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "CHANGELOG.md has no section for $VERSION. Add what is new, improved and fixed first."; exit 1; }
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || { echo "Commit your changes first, so the release matches a commit."; exit 1; }
./build.sh test
./build.sh
APP=build/Minute.app
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --options runtime --entitlements Minute.entitlements --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --strict --deep "$APP"
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
{ echo "# Minute $VERSION"; echo; echo "$NOTES"; } > build/RELEASE_NOTES.md
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
git tag -a "v$VERSION" -m "Minute $VERSION" 2>/dev/null && echo "Tagged v$VERSION (push it with: git push origin v$VERSION, CI then publishes the GitHub release)." || echo "Tag v$VERSION already exists."
echo "Created $ZIP and build/RELEASE_NOTES.md"
