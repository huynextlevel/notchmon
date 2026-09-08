#!/usr/bin/env bash
# Builds dist/NotchMon-<build>.dmg — the window a stranger opens first.
#
# Usage:  Scripts/make-dmg.sh <build-number> [signing-identity]
#
# Hand-rolled on hdiutil rather than create-dmg, for the same reason
# Scripts/bundle.sh is hand-rolled rather than an Xcode target: this needs one
# background, two icon positions and one window size, and a dependency that has
# to be installed before anyone can build a release costs more than it saves.
#
# ONE PERMISSION IS NEEDED, ONCE. Laying out the window means telling Finder
# where to put things, and macOS gates that behind Automation. The first run
# raises "Terminal wants to control Finder" — it has to be allowed, and nobody
# can allow it on your behalf. Refuse it and the build still produces a working
# DMG, just with Finder's default list view and no background.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${1:-}"
[ -n "$BUILD_NUMBER" ] || { echo "usage: Scripts/make-dmg.sh <build-number> [identity]" >&2; exit 2; }
SIGN="${2:-}"

APP="dist/NotchMon.app"
BG="design/dmg/background.tiff"
VOL="NotchMon 0.1.1"
DMG="dist/NotchMon-$BUILD_NUMBER.dmg"

[ -d "$APP" ] || { echo "no $APP — run 'make app' first" >&2; exit 1; }
[ -f "$BG" ]  || { echo "no $BG — run 'make dmg-bg' first" >&2; exit 1; }

# The window's own numbers, in one place. They are the numbers design/dmg.html
# draws, so the render and the shipped window cannot drift.
WIN_W=660; WIN_H=400; TITLEBAR=28
WIN_L=200; WIN_T=160
ICON_SIZE=128
APP_X=170;  APP_Y=186
APPS_X=490; APPS_Y=186

STAGE="$(mktemp -d)"
RW="$(mktemp -d)/rw.dmg"
trap 'rm -rf "$STAGE" "$(dirname "$RW")"' EXIT

mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"
cp -R "$APP" "$STAGE/NotchMon.app"
ln -s /Applications "$STAGE/Applications"

# Sized with slack rather than -srcfolder's tight fit: Finder has to write a
# .DS_Store into this image after it is created, and a volume with no free
# space silently keeps the default layout instead.
MB=$(( $(du -sm "$STAGE" | cut -f1) + 60 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -format UDRW -size "${MB}m" -ov "$RW" >/dev/null

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/GUID_partition_scheme|Apple_HFS/ {print $1}' | head -1)"
MOUNT="/Volumes/$VOL"
[ -d "$MOUNT" ] || { echo "the image did not mount at $MOUNT" >&2; exit 1; }

# `|| true`: a refused Automation prompt must not throw away a build that is
# otherwise finished. The warning says what was lost.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- The sidebar lives INSIDE the window's bounds. Leave it on and the
    -- content area is ~258pt narrower than the background, which paints as
    -- bare white down the right-hand side of the artwork.
    set sidebar width of container window to 0
    set the bounds of container window to {$WIN_L, $WIN_T, $((WIN_L + WIN_W)), $((WIN_T + WIN_H + TITLEBAR))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "NotchMon.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    close
    open
    -- Re-asserted after the reopen: Finder resolves the geometry again on the
    -- way in, and only what is true at the moment it writes .DS_Store is what
    -- the recipient's Finder will read back.
    set sidebar width of container window to 0
    set the bounds of container window to {$WIN_L, $WIN_T, $((WIN_L + WIN_W)), $((WIN_T + WIN_H + TITLEBAR))}
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder would not take the layout — the DMG will open with the" >&2
  echo "         default view and no background. Allow Terminal to control" >&2
  echo "         Finder in System Settings > Privacy & Security > Automation." >&2
fi

sync
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# A DMG carries its own signature and its own notarisation ticket. Without them
# the warning appears when the disk image is opened — before the window this
# whole script exists to draw is ever seen.
if [ -n "$SIGN" ]; then
  codesign --force --sign "$SIGN" --timestamp "$DMG"
fi

echo "built $DMG ($(du -h "$DMG" | cut -f1))"
