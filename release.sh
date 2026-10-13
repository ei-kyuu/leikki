#!/bin/bash
# Publish a Leikki update to GitHub. Every installed copy picks it up within a
# day (see dist/update.sh).
#
#   ./release.sh 1.1 "What changed"
set -euo pipefail
cd "$(dirname "$0")"
REPO="ei-kyuu/leikki"
short="${1:?usage: ./release.sh <version, e.g. 1.1> [notes]}"
notes="${2:-Leikki $short}"

# Build numbers count releases, so each release is strictly newer than the last.
count="$(gh release list -R "$REPO" --limit 1000 --json tagName --jq length 2>/dev/null || echo 0)"
build=$((count + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short" -c "Set :CFBundleVersion $build" src/Info.plist

rm -rf release && mkdir release
scripts/build-saver.sh release            # shared build: no Akkurat
( cd release
  ditto -c -k --norsrc --noextattr --keepParent Leikki.saver Leikki.zip
  shasum -a 256 Leikki.zip > Leikki.zip.sha256
  echo "$build $short" > version.txt )
cp dist/update.sh release/update.sh
scripts/make-gift.sh release

git add -A
git commit -m "Leikki $short (build $build)" || true
git tag -f "v$short"
git push origin HEAD
git push -f origin "v$short"
gh release create "v$short" -R "$REPO" --title "Leikki $short" --notes "$notes" \
  release/Leikki.zip release/Leikki.zip.sha256 release/version.txt release/update.sh release/Leikki-Gift.zip
echo "published Leikki $short (build $build)"
