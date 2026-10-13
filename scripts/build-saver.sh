#!/bin/bash
# Build Leikki.saver (universal: Apple silicon + Intel, macOS 13+) into $1.
# Pass --with-akkurat to bundle the Akkurat font (the author's own copy only;
# shared builds fall back to Helvetica Neue, which ships with every Mac).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: build-saver.sh <out-dir> [--with-akkurat]}"
SAVER="$OUT/Leikki.saver"

rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -O2 \
  -framework Cocoa -framework ScreenSaver -framework QuartzCore -framework CoreText \
  -dynamiclib -install_name "Leikki" \
  -o "$SAVER/Contents/MacOS/Leikki" \
  src/STStoolView.m src/STStoolModel.m
cp src/Info.plist "$SAVER/Contents/Info.plist"
if [ "${2:-}" = "--with-akkurat" ]; then cp src/fonts/Akkurat.ttf "$SAVER/Contents/Resources/"; fi

codesign --force --sign - --timestamp=none "$SAVER"
codesign --verify "$SAVER"
echo "built $SAVER ($(lipo -archs "$SAVER/Contents/MacOS/Leikki"))"
