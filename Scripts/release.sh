#!/usr/bin/env bash
# Builds a NotchMon anyone can run: universal, Developer ID signed, hardened,
# notarised and stapled.
#
# Usage:  Scripts/release.sh <build-number>
#
# Needs, once, before this will work:
#   1. A **Developer ID Application** certificate for the team. An "Apple
#      Development" certificate is NOT it — that one signs builds for machines
#      registered to the account, and both Gatekeeper on a stranger's Mac and
#      notarisation reject it.
#      Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID
#      Application. Requires the Account Holder or Admin role.
#   2. A stored notary credential:
#      xcrun notarytool store-credentials notarytool \
#        --apple-id <you@example.com> --team-id "$TEAM_ID" \
#        --password <app-specific-password from appleid.apple.com>
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${NOTCHMON_TEAM_ID:-RKK53HCN6A}"
BUILD_NUMBER="${1:-}"
[ -n "$BUILD_NUMBER" ] || { echo "usage: Scripts/release.sh <build-number>" >&2; exit 2; }

APP="dist/NotchMon.app"
ZIP="dist/NotchMon-$BUILD_NUMBER.zip"

# --- 1. The identity, checked before anything is built ------------------------
IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 \
  | sed -E 's/.*"(.*)"/\1/')" || true
if [ -z "${IDENTITY:-}" ]; then
  echo "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain." >&2
  echo "Present identities:" >&2
  security find-identity -v -p codesigning >&2
  echo "See the header of this script for how to create one." >&2
  exit 1
fi
echo "signing as: $IDENTITY"

# --- 2. A universal tokscale --------------------------------------------------
# The build machine's npm install only fetches its own architecture, so the
# other slice is pulled straight from the registry and the two are lipo'd. An
# Intel user running an arm64-only helper gets a launch failure the app cannot
# explain, so this is not optional for a public build.
./Scripts/vendor-tokscale.sh
VER="$(node -p "require('./vendor/node_modules/tokscale/package.json').version")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
for slice in arm64 x64; do
  ( cd "$WORK" && npm pack "@tokscale/cli-darwin-$slice@$VER" >/dev/null 2>&1 \
    && tar xzf "tokscale-cli-darwin-$slice-$VER.tgz" \
    && mv package/bin/tokscale "tokscale-$slice" && rm -rf package )
done
lipo -create "$WORK/tokscale-arm64" "$WORK/tokscale-x64" -output vendor/tokscale-universal
chmod +x vendor/tokscale-universal
echo "tokscale $VER: $(lipo -archs vendor/tokscale-universal)"

# --- 3. Assemble, signed and hardened ----------------------------------------
NOTCHMON_ARCHS="arm64 x86_64" NOTCHMON_SIGN="$IDENTITY" NOTCHMON_BUILD="$BUILD_NUMBER" \
  ./Scripts/bundle.sh release

echo "app:      $(lipo -archs "$APP/Contents/MacOS/NotchMon")"
codesign --verify --strict --deep --verbose=2 "$APP"

# --- 4. Notarise --------------------------------------------------------------
# The zip is only a transport for the upload; what gets stapled afterwards is
# the .app itself, so the ticket travels with whatever you distribute.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile notarytool --wait
xcrun stapler staple "$APP"

# Re-zip after stapling: the first archive holds the pre-ticket bundle.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- 5. The disk image ---------------------------------------------------------
# What a person actually downloads. It carries its own signature and its own
# ticket: an unsigned DMG raises the warning when the image is opened, before
# the window it exists to show is ever seen.
DMG="dist/NotchMon-$BUILD_NUMBER.dmg"
./Scripts/make-dmg.sh "$BUILD_NUMBER" "$IDENTITY"
xcrun notarytool submit "$DMG" --keychain-profile notarytool --wait
xcrun stapler staple "$DMG"

# --- 6. The real test ----------------------------------------------------------
# `spctl` answers the question a stranger's Mac will ask, of both artefacts.
spctl --assess --type execute --verbose=4 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
# --- 7. The appcast ------------------------------------------------------------
# The file an installed copy reads to learn that a newer one exists. Sparkle
# signs the enclosure with the private EdDSA key in this machine's keychain, and
# the public half is baked into every app already out there -- so the feed can be
# served from anywhere, by anyone, and still cannot offer an update that was not
# signed here.
#
# generate_appcast decides whether a signature is needed by reading the app
# INSIDE the archive: no SUPublicEDKey in its Info.plist and it writes an
# unsigned enclosure without complaining. If the signature is missing below, the
# DMG was built from a bundle that predates Sparkle.
SPARKLE_BIN="$(/usr/bin/find .build/artifacts -type d -name bin -path '*sparkle*' 2>/dev/null | head -1)"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
UPDATES=dist/updates
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/huynextlevel/notchmon/releases/download/v$SHORT/" \
  --link "https://github.com/huynextlevel/notchmon" \
  "$UPDATES"
cp "$UPDATES/appcast.xml" appcast.xml

grep -q edSignature appcast.xml \
  || echo "warning: appcast has no EdDSA signature — Sparkle will refuse this update" >&2

echo "released $DMG and $ZIP"
echo "next: commit appcast.xml, and upload $DMG to the v$SHORT GitHub release"
