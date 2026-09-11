#!/bin/bash
# Assembles dist/NotchMon.app around the SwiftPM executable.
#
# A hand-built bundle rather than an Xcode target: the app needs exactly one
# executable, one Info.plist and one vendored binary, and an .xcodeproj to hold
# those three things is more to keep in sync than to gain.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="dist/NotchMon.app"

# Overridable so Scripts/release.sh can reuse this assembly rather than keeping a
# second, drifting copy of it.
#   NOTCHMON_ARCHS  — e.g. "arm64 x86_64" for a universal build. Default: host.
#   NOTCHMON_SIGN   — a codesign identity. Default "-", which is ad-hoc: enough
#                     for Gatekeeper to run a locally built app and not enough to
#                     hand to anyone else.
#   NOTCHMON_BUILD  — CFBundleVersion. Must increase for every build uploaded.
ARCHS="${NOTCHMON_ARCHS:-}"
SIGN="${NOTCHMON_SIGN:--}"
BUILD_NUMBER="${NOTCHMON_BUILD:-1}"

# Build, THEN ask where the binary landed. `--show-bin-path` only prints a path;
# on its own it will happily point at a stale binary from an earlier build, and
# the bundle then ships code that is not the code in the tree — which looks
# exactly like a change that did not work.
# `${a[@]+"${a[@]}"}` rather than `"${a[@]}"`: macOS ships bash 3.2, where an
# empty array under `set -u` counts as unbound.
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_PATH="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/NotchMon" "$APP/Contents/MacOS/NotchMon"

# The hook an agent runs. In Resources rather than MacOS: MacOS is for things
# the system launches, and this is launched by somebody else's CLI. It is built
# from the same package, so it cannot drift from the socket protocol the app
# reads -- which a checked-in script would.
# ...when the app is built with the hook path on. `HookServer.enabled` is the
# single switch; this reads it from the source so the two cannot disagree, and a
# build with the listener off carries no helper for it either.
HOOKS_ON="$(grep -c 'static let enabled = true' Sources/NotchMon/Usage/HookServer.swift || true)"
if [ "$HOOKS_ON" != "0" ]; then
  cp "$BIN_PATH/notchmon-hook" "$APP/Contents/Resources/notchmon-hook"
  chmod +x "$APP/Contents/Resources/notchmon-hook"
fi

# Sparkle. SwiftPM links against the framework but never embeds it — at `swift
# build` time there is no bundle to embed into — so it is copied here, and the
# executable was linked with an rpath of @executable_path/../Frameworks to find
# it. `ditto` rather than `cp -R`: a framework is a tree of version symlinks and
# copying it wrong produces a bundle that passes every check until it launches.
SPARKLE="$(/usr/bin/find .build/artifacts -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' 2>/dev/null | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found — run 'swift build' once first" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# tokscale: a universal slice when one has been built, otherwise the host's.
if [ -x "vendor/tokscale-universal" ]; then
  cp vendor/tokscale-universal "$APP/Contents/Resources/tokscale"
  chmod +x "$APP/Contents/Resources/tokscale"
else
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64) PKG="@tokscale/cli-darwin-arm64" ;;
    *) PKG="@tokscale/cli-darwin-x64" ;;
  esac
  if [ -x "vendor/node_modules/$PKG/bin/tokscale" ]; then
    cp "vendor/node_modules/$PKG/bin/tokscale" "$APP/Contents/Resources/tokscale"
    chmod +x "$APP/Contents/Resources/tokscale"
  else
    echo "warning: tokscale not vendored — run 'make vendor' first" >&2
  fi
fi

# The icon is committed rather than rendered here, so building the app needs no
# librsvg. Regenerate it with Scripts/make-icon.sh when the artwork changes.
cp design/icons/NotchMon.icns "$APP/Contents/Resources/NotchMon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotchMon</string>
  <key>CFBundleDisplayName</key><string>NotchMon</string>
  <key>CFBundleIdentifier</key><string>com.notchmon.app</string>
  <key>CFBundleExecutable</key><string>NotchMon</string>
  <key>CFBundleIconFile</key><string>NotchMon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Updates. SUPublicEDKey is the public half of the EdDSA pair whose private
       half lives in the release machine's keychain; an update signed by anything
       else is refused before it is unpacked. SUEnableAutomaticChecks skips the
       permission prompt Sparkle otherwise raises on second launch, because the
       same choice is a switch in Settings and being asked twice for one setting
       reads as the first answer not having been recorded. -->
  <key>SUFeedURL</key><string>https://raw.githubusercontent.com/huynextlevel/notchmon/main/appcast.xml</string>
  <key>SUPublicEDKey</key><string>a+RXi2efEN0pRAD2UjSRT8BZmKBpSbOO56WrttvkQlI=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <!-- No Dock icon and no app menu: the notch is the whole interface. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Substituted after the heredoc so the plist above stays readable as a literal.
/usr/bin/sed -i '' "s/__BUILD__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"

# Inside out, and deliberately not `--deep`.
#
# `--deep` is a convenience that re-signs nested code with the OUTER seal, which
# Apple has discouraged for years and which notarisation rejects: the vendored
# tokscale binary needs its own signature, made first, so the app's seal is taken
# over a bundle that is already internally consistent.
RUNTIME=()
[ "$SIGN" = "-" ] || RUNTIME=(--options runtime --timestamp)

FW="$APP/Contents/Frameworks/Sparkle.framework"
for nested in "$FW/Versions/B/Updater.app" "$FW/Versions/B/Autoupdate" "$FW"; do
  codesign --force --sign "$SIGN" ${RUNTIME[@]+"${RUNTIME[@]}"} "$nested" \
    >/dev/null 2>&1 || echo "warning: could not sign $(basename "$nested")" >&2
done

for helper in tokscale notchmon-hook; do
  [ -e "$APP/Contents/Resources/$helper" ] || continue
  codesign --force --sign "$SIGN" ${RUNTIME[@]+"${RUNTIME[@]}"} "$APP/Contents/Resources/$helper" \
    >/dev/null 2>&1 || echo "warning: could not sign $helper" >&2
done
codesign --force --sign "$SIGN" ${RUNTIME[@]+"${RUNTIME[@]}"} "$APP" \
  >/dev/null 2>&1 || echo "warning: codesign failed" >&2
echo "built $APP"
