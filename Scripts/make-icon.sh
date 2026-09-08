#!/usr/bin/env bash
# Builds NotchMon.icns from design/icons/icon.svg.
#
# Run this when the icon changes, and commit the .icns — the app bundle then
# needs nothing but a copy, so building NotchMon does not depend on librsvg
# being installed.
#
# The master SVG is full-bleed 1024, which is the shape macOS 26 wants and the
# shape every other platform wants. A classic .icns is NOT masked by the system,
# though: whatever is in it is what Finder draws. So the macOS variant wraps the
# master in Apple's own icon grid — an 824-point rounded square inside the 1024
# canvas, sitting high to leave room for its shadow. Skip that and the icon
# renders as a hard square next to everyone else's rounded ones.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "needs librsvg: brew install librsvg" >&2; exit 1; }

ICONS=design/icons
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

rsvg-convert -w 1024 -h 1024 "$ICONS/icon.svg" -o "$WORK/full.png"

cat > "$WORK/macos.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <clipPath id="grid"><rect x="100" y="90" width="824" height="824" rx="185" ry="185"/></clipPath>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.35"/>
    </filter>
  </defs>
  <g filter="url(#drop)">
    <g clip-path="url(#grid)">
      <image xlink:href="$WORK/full.png" x="100" y="90" width="824" height="824"/>
    </g>
  </g>
</svg>
SVG

SET="$WORK/NotchMon.iconset"
mkdir -p "$SET"
render() { rsvg-convert -w "$1" -h "$1" "$WORK/macos.svg" -o "$SET/$2"; }
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$ICONS/NotchMon.icns"
echo "built $ICONS/NotchMon.icns"
