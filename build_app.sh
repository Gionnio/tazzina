#!/bin/bash
# Compila Tazzina e crea build/Tazzina.app (con il servizio per il coperchio chiuso).
# Requisiti: Xcode Command Line Tools (Swift 5.9+), macOS 14+.
#
# Uso: ./build_app.sh            → build/Tazzina.app
#      ./build_app.sh --install  → anche installata in /Applications e avviata
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Tazzina.app"
VERSION="1.0.0"
BUILD_NUMBER="1"

echo "▸ Compilo"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "▸ Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/Tazzina" "$APP/Contents/MacOS/Tazzina"
cp "$BIN_DIR/TazzinaHelper" "$APP/Contents/MacOS/TazzinaHelper"
cp "$ROOT/LaunchDaemons/com.github.gionnio.Tazzina.Helper.plist" "$APP/Contents/Library/LaunchDaemons/"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tazzina</string>
    <key>CFBundleDisplayName</key><string>Tazzina</string>
    <key>CFBundleIdentifier</key><string>com.github.gionnio.Tazzina</string>
    <key>CFBundleExecutable</key><string>Tazzina</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>com.github.gionnio.Tazzina</string>
        <key>CFBundleURLSchemes</key><array><string>tazzina</string></array>
    </dict></array>
    <key>NSLocationUsageDescription</key><string>Tazzina reads the Wi-Fi network name for Wi-Fi triggers. macOS requires Location access for this.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>Tazzina reads the Wi-Fi network name for Wi-Fi triggers. macOS requires Location access for this.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Tazzina checks which Bluetooth devices are connected for Bluetooth triggers.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Gionnio. MIT License.</string>
</dict>
</plist>
PLIST

ICNS="$BUILD/AppIcon.icns"
iconutil -c icns "$ROOT/icon/AppIcon.iconset" -o "$ICNS"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# Firma ad-hoc: prima il servizio (con il suo identificativo, controllato dall'app), poi l'app.
codesign --force --options runtime --identifier com.github.gionnio.Tazzina.Helper --sign - "$APP/Contents/MacOS/TazzinaHelper"
codesign --force --options runtime --identifier com.github.gionnio.Tazzina --sign - "$APP"
touch "$APP"
echo "✅ $APP"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Installo in /Applications"
    osascript -e 'quit app "Tazzina"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Tazzina.app
    ditto "$APP" /Applications/Tazzina.app
    open /Applications/Tazzina.app
    echo "✓ Tazzina installata. Dopo una reinstallazione macOS può chiedere di nuovo i permessi (notifiche, servizio per il coperchio chiuso)."
fi
