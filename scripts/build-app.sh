#!/usr/bin/env bash
# Builds Deskwork.app — a real macOS bundle you can double-click, keep in
# /Applications and pin to the Dock.
#
# This matters beyond polish. A binary launched from a terminal inherits that
# terminal's environment, which is how a stray CLAUDECODE variable can leak in
# and stop a nested agent session from starting. A bundle launched from Finder
# gets a clean environment from launchd instead.
set -euo pipefail

cd "$(dirname "$0")/../app"
APP="${1:-$HOME/Applications}/Deskwork.app"
VERSION="$(git -C .. describe --tags --always 2>/dev/null || echo 0.1.0)"
SOURCE_ROOT="$(cd .. && pwd)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "building…"
swift build -c release 2>&1 | grep -vE "build database|^\[" || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Deskwork "$APP/Contents/MacOS/Deskwork"
# Ship the headless core alongside it, so `deskwork-cli` is available without a
# second build.
cp .build/release/deskwork-cli "$APP/Contents/MacOS/deskwork-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>Deskwork</string>
  <key>CFBundleDisplayName</key>          <string>Deskwork</string>
  <key>CFBundleIdentifier</key>           <string>dev.deskwork.app</string>
  <key>CFBundleExecutable</key>           <string>Deskwork</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>${VERSION}</string>
  <key>CFBundleVersion</key>              <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>       <string>13.0</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <!-- Terminals live here; the app is not a document editor. -->
  <key>LSApplicationCategoryType</key>    <string>public.app-category.developer-tools</string>
  <!-- Where this bundle was built from, so the app can rebuild and update
       itself without the user opening a terminal. Absent in a bundle shipped
       without source, and the app says so rather than guessing. -->
  <key>DWSourceRoot</key>                 <string>${SOURCE_ROOT}</string>
  <key>DWBuiltAt</key>                    <string>${BUILT_AT}</string>
</dict>
</plist>
PLIST

if [ -f ../assets/AppIcon.icns ]; then
  cp ../assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Without it macOS nags on every launch; with it the app runs
# on the machine that built it. Not a substitute for a Developer ID for
# distribution, and the README says so.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (unsigned — Gatekeeper will ask once)"

echo "built $APP"
echo "  open it:    open '$APP'"
echo "  cli:        '$APP/Contents/MacOS/deskwork-cli' usage"
