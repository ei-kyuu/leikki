#!/bin/bash
# Leikki updater, run by launchd (com.aq.leikki.updater) at login and daily.
# Installs the latest GitHub release if it is newer than the installed build.
# Quiet when there's nothing to do; notes what it did in ~/Library/Logs/Leikki.log.
set -uo pipefail

REPO="ei-kyuu/leikki"
BASE="https://github.com/$REPO/releases/latest/download"
SAVER="$HOME/Library/Screen Savers/Leikki.saver"
SUPPORT="$HOME/Library/Application Support/Leikki"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || echo 0; }

installed="$(build_of "$SAVER")"
latest="$(curl -fsSL --max-time 30 "$BASE/version.txt" 2>/dev/null | awk 'NR==1 {print $1}')"
[[ "$latest" =~ ^[0-9]+$ ]] || exit 0          # offline, or no release yet
[ "$latest" -gt "$installed" ] || exit 0

log "updating from build $installed to $latest"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --max-time 300 "$BASE/Leikki.zip" -o "$tmp/Leikki.zip" || { log "download failed"; exit 1; }
want="$(curl -fsSL --max-time 30 "$BASE/Leikki.zip.sha256" | awk '{print $1}')"
have="$(shasum -a 256 "$tmp/Leikki.zip" | awk '{print $1}')"
[ -n "$want" ] && [ "$want" = "$have" ] || { log "checksum mismatch, skipped"; exit 1; }
ditto -x -k "$tmp/Leikki.zip" "$tmp/x" || { log "unzip failed"; exit 1; }
new="$tmp/x/Leikki.saver"
[ "$(build_of "$new")" = "$latest" ] || { log "archive has the wrong build, skipped"; exit 1; }
codesign --verify "$new" 2>/dev/null || { log "signature check failed, skipped"; exit 1; }

# Swap in place: copy beside the old one, then replace it.
rm -rf "$SAVER.new"
ditto "$new" "$SAVER.new" && rm -rf "$SAVER" && mv "$SAVER.new" "$SAVER" || { log "install failed"; exit 1; }
xattr -dr com.apple.quarantine "$SAVER" 2>/dev/null || true

# Refresh this updater too. Write a new file and rename it over the old one,
# so the copy of this script that's running now is never modified.
if curl -fsSL --max-time 30 "$BASE/update.sh" -o "$tmp/update.sh" 2>/dev/null \
   && head -1 "$tmp/update.sh" | grep -q '^#!/bin/bash'; then
    chmod +x "$tmp/update.sh"
    mv "$tmp/update.sh" "$SUPPORT/update.sh.new" && mv "$SUPPORT/update.sh.new" "$SUPPORT/update.sh"
fi

# Screen saver hosts keep old builds loaded. Restart them so the new build is
# used, but not while the screen saver is showing.
if ! pgrep -xq ScreenSaverEngine; then killall -9 legacyScreenSaver 2>/dev/null || true; fi
log "installed build $latest"
