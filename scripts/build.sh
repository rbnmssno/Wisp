#!/bin/bash
# Builds Wisp.app and Wisp.dmg into dist/.
# Usage: scripts/build.sh            build the app and the disk image
#        scripts/build.sh --app-only build only dist/Wisp.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Wisp.app"
DMG="dist/Wisp.dmg"

echo "==> Compiling"
swift build -c release --arch arm64 2>&1 | grep -E "error:|Build complete" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Wisp"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wisp"
strip -x "$APP/Contents/MacOS/Wisp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The page script that connects the site to the app.
cp Resources/bridge.js "$APP/Contents/Resources/"
# The language folders tell macOS which languages the app speaks (English and Russian); it then
# picks one for the menus and for system-provided texts.
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"

# The icon is an Icon Composer document; actool turns it into Assets.car (drawn by macOS 26 and later
# with its own glass and dark variants) and AppIcon.icns for older systems.
ICON_WORK="$(mktemp -d)"
if [ -d "$ROOT/Resources/AppIcon.icon" ] && xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ROOT/$APP/Contents/Resources" \
     --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist "$ICON_WORK/icon.plist" >"$ICON_WORK/actool.log" 2>&1; then
  echo "==> Icon compiled"
else
  echo "==> Icon not compiled"; [ -f "$ICON_WORK/actool.log" ] && cat "$ICON_WORK/actool.log" || true
fi
rm -rf "$ICON_WORK"

# Signature. With the local identity from scripts/make-signing-identity.sh every build has the same
# identity, so macOS keeps whatever it allowed the app. Without it, an ad hoc signature: runs fine,
# but each build counts as a new app.
KC="$ROOT/signing/wisp.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p wisp-local "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Wisp Local Signing/ {print $2; exit}')
  codesign --force --timestamp=none --keychain "$KC" --sign "$ID" "$APP" 2>&1 | grep -v "replacing existing" || true
  echo "==> Signed with Wisp Local Signing"
else
  codesign --force --sign - --timestamp=none "$APP"
  echo "==> Signed ad hoc (run scripts/make-signing-identity.sh once to keep one identity across builds)"
fi
codesign --verify --strict "$APP"

if [ "${1:-}" = "--app-only" ]; then
  echo "==> Done: $APP"
  exit 0
fi

echo "==> Creating $DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Wisp.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
if ! hdiutil create -volname "Wisp" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >"$STAGE.log" 2>&1; then
  cat "$STAGE.log"
  rm -rf "$STAGE" "$STAGE.log"
  exit 1
fi
rm -rf "$STAGE" "$STAGE.log"
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
