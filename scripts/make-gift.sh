#!/bin/bash
# Assemble the gift download: install/uninstall launchers plus a read-me, zipped.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: make-gift.sh <out-dir>}"
G="$OUT/gift/Leikki"
rm -rf "$OUT/gift" && mkdir -p "$G"
cp dist/install.sh "$G/Install Leikki.command"
cp dist/uninstall.sh "$G/Uninstall Leikki.command"
cp "dist/Read Me.txt" "$G/Read Me.txt"
chmod +x "$G/"*.command
( cd "$OUT/gift" && ditto -c -k --keepParent Leikki ../Leikki-Gift.zip )
echo "gift: $OUT/Leikki-Gift.zip"
