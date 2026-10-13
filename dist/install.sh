#!/bin/bash
# Leikki installer.
#
# Installs the Leikki screen saver for this user, plus a tiny updater that
# checks once a day for a newer release and installs it quietly.
#
#   Double-click "Install Leikki.command", or in Terminal:
#   curl -fsSL https://raw.githubusercontent.com/ei-kyuu/leikki/main/dist/install.sh | bash
#
# Remove everything again with "Uninstall Leikki.command" (dist/uninstall.sh).
set -euo pipefail

REPO="ei-kyuu/leikki"
BASE="https://github.com/$REPO/releases/latest/download"
SAVERS="$HOME/Library/Screen Savers"
SUPPORT="$HOME/Library/Application Support/Leikki"
AGENT_LABEL="com.aq.leikki.updater"
AGENT="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LOG="$HOME/Library/Logs/Leikki.log"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo; echo "Leikki could not be installed: $*"; echo "Check your internet connection and try again."; exit 1; }

echo
echo "  Leikki"
echo "  ------"
echo "  Installing the screen saver…"

curl -fsSL --max-time 300 "$BASE/Leikki.zip" -o "$tmp/Leikki.zip" || fail "the download didn't complete."
want="$(curl -fsSL --max-time 30 "$BASE/Leikki.zip.sha256" | awk '{print $1}')" || fail "the checksum didn't download."
have="$(shasum -a 256 "$tmp/Leikki.zip" | awk '{print $1}')"
[ -n "$want" ] && [ "$want" = "$have" ] || fail "the download was damaged (checksum mismatch)."
ditto -x -k "$tmp/Leikki.zip" "$tmp/x" || fail "the download couldn't be unpacked."
codesign --verify "$tmp/x/Leikki.saver" 2>/dev/null || fail "the screen saver's signature didn't check out."

mkdir -p "$SAVERS" "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
rm -rf "$SAVERS/Leikki.saver"
ditto "$tmp/x/Leikki.saver" "$SAVERS/Leikki.saver"
xattr -dr com.apple.quarantine "$SAVERS/Leikki.saver" 2>/dev/null || true

if [ -z "${LEIKKI_NO_UPDATER:-}" ]; then
  echo "  Setting up automatic updates…"
  curl -fsSL --max-time 30 "$BASE/update.sh" -o "$tmp/update.sh" || fail "the updater didn't download."
  head -1 "$tmp/update.sh" | grep -q '^#!/bin/bash' || fail "the updater looked wrong."
  mv "$tmp/update.sh" "$SUPPORT/update.sh"
  chmod +x "$SUPPORT/update.sh"

  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SUPPORT/update.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>86400</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT" || fail "the updater couldn't be scheduled."
fi

# Screen saver hosts keep old builds loaded; restart them unless the saver is
# on screen right now.
if ! pgrep -xq ScreenSaverEngine; then killall -9 legacyScreenSaver 2>/dev/null || true; fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SAVERS/Leikki.saver/Contents/Info.plist")"
echo
echo "  Leikki $version is installed."
echo "  In Screen Saver settings, pick Leikki (under Other), then Options…"
echo "  to choose stools, tables or vases."
echo
[ -z "${LEIKKI_NO_OPEN:-}" ] && open "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension" 2>/dev/null || true
exit 0
