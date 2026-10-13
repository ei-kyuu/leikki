#!/bin/bash
# Removes Leikki and its updater from this Mac.
launchctl bootout "gui/$(id -u)/com.aq.leikki.updater" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.aq.leikki.updater.plist"
rm -rf "$HOME/Library/Application Support/Leikki"
rm -rf "$HOME/Library/Screen Savers/Leikki.saver"
rm -f "$HOME/Library/Logs/Leikki.log"
killall -9 legacyScreenSaver 2>/dev/null || true
echo
echo "  Leikki has been removed."
echo
