#!/bin/zsh
# Build Minute, install the app to ~/Applications and the pipeline to ~/.mom/bin.
# Usage: ./build.sh [deploy]   (without "deploy" it only builds into ./build)
set -e
cd "${0:A:h}"
APP=build/Minute.app
rm -rf build; mkdir -p "$APP/Contents/MacOS"
swiftc -target arm64-apple-macos14.2 -parse-as-library -O -o "$APP/Contents/MacOS/Minute" Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework CoreAudio -framework UserNotifications
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
if [[ "$1" == deploy ]]; then
  pkill -x Minute 2>/dev/null || true
  mkdir -p ~/Applications ~/.mom/bin
  if [[ -d ~/Applications/Minute.app ]]; then rm -rf ~/.mom/Minute.app.prev; mv ~/Applications/Minute.app ~/.mom/Minute.app.prev; fi
  cp -R "$APP" ~/Applications/
  cp pipeline/mom ~/.mom/bin/mom; chmod +x ~/.mom/bin/mom
  [[ -f ~/.mom/template.docx ]] || echo "NOTE: put your Word template at ~/.mom/template.docx"
  echo "deployed. previous app kept at ~/.mom/Minute.app.prev"
fi
