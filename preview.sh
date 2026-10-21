#!/bin/bash
# Fast iteration loop: builds a windowed preview app (no System Settings, no
# stale-host caching) and launches it. Close the window or Cmd-Q to quit.
set -e
cd "$(dirname "$0")"

APP="preview.app"
BIN="$APP/Contents/MacOS/preview"

echo "==> compiling preview app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -target arm64-apple-macos13.0 -fobjc-arc -O2 \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore -framework CoreText \
  -o "$BIN" \
  src/STStoolView.m src/STStoolModel.m src/PreviewMain.m

cp src/PreviewInfo.plist "$APP/Contents/Info.plist"
cp src/fonts/*.ttf "$APP/Contents/Resources/"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"


echo "==> launching"
killall preview 2>/dev/null || true
[ -n "$NO_LAUNCH" ] || open "$APP"
