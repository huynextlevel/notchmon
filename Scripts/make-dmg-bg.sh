#!/usr/bin/env bash
# Builds design/dmg/background.tiff from design/dmg/background.svg.
#
# Run this when the artwork changes, and commit the .tiff — the same bargain
# Scripts/make-icon.sh makes, so building a release needs no librsvg.
#
# A TIFF holding both scales, not a PNG. Finder picks the representation that
# matches the display; hand it a lone 2x PNG and it downsamples on every
# non-retina Mac, which is why so many DMG backgrounds look soft.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "needs librsvg: brew install librsvg" >&2; exit 1; }

SRC=design/dmg/background.svg
OUT=design/dmg/background.tiff
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rsvg-convert -w 660  -h 400 "$SRC" -o "$WORK/bg.png"
rsvg-convert -w 1320 -h 800 "$SRC" -o "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$OUT" >/dev/null

echo "built $OUT ($(du -h "$OUT" | cut -f1), 660x400 + 1320x800)"
