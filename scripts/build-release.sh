#!/usr/bin/env bash
#
# Build the release .app, put it in ~/Downloads and open it.
#
#   ./scripts/build-release.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXE="MangaworldDownloader"
VERSION="1.0.0"
APP="$HOME/Downloads/Mangaworld Downloader.app"
cd "$REPO"

echo "==> Test"
if ! out="$(swift test 2>&1)"; then echo "$out"; exit 1; fi
echo "$out" | grep -E "Executed [0-9]+ tests" | tail -1

echo "==> Build"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXE"

echo "==> Bundle"
# Only ever replace a previous build of this app: anything else with the name is somebody's file.
if [[ -e "$APP" && ! -x "$APP/Contents/MacOS/$EXE" ]]; then
  echo "   «$APP» esiste e non è una build di quest'app. Rimuovilo a mano." >&2
  exit 1
fi
pkill -f "/$EXE( |$)" || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
# The icon is an Icon Composer document. actool turns it into Assets.car — each appearance macOS 26
# draws, the glass rendered by the system — plus an .icns for macOS 15, which predates the format.
xcrun actool "$REPO/icon/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --include-all-app-icons --platform macosx --target-device mac --minimum-deployment-target 15.0 \
  --output-partial-info-plist "$(mktemp)" >/dev/null
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.mangaworld.downloader</string>
  <key>CFBundleDevelopmentRegion</key><string>it</string>
  <key>CFBundleName</key><string>Mangaworld Downloader</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
# Tells the Finder and the Dock to read the icon anew.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo
echo "Pronta: $APP · $VERSION · $(du -sh "$APP" | cut -f1)"
open "$APP"
