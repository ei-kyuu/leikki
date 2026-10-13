#!/bin/bash
# Build the author's own copy (with Akkurat) and install it on this Mac.
set -euo pipefail
cd "$(dirname "$0")"
scripts/build-saver.sh build --with-akkurat

echo "==> installing to ~/Library/Screen Savers"
rm -rf "$HOME/Library/Screen Savers/Leikki.saver" "$HOME/Library/Screen Savers/stool-bounce.saver"
cp -R build/Leikki.saver "$HOME/Library/Screen Savers/"
# The full-screen Preview host caches loaded savers for its lifetime, and it
# ignores SIGTERM (hosts survived for weeks on plain killall), so force-kill.
killall -9 legacyScreenSaver 2>/dev/null || true
echo "==> done"
