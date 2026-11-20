#!/usr/bin/env bash
# Builds Helios.app into ./build. Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Helios"
APP="build/Helios.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Helios"

# App icon: render once, then build every size macOS wants into an .icns.
ICON_PNG="build/icon-1024.png"
if [[ ! -f "$ICON_PNG" || scripts/make-icon.swift -nt "$ICON_PNG" ]]; then
    swift scripts/make-icon.swift "$ICON_PNG" >/dev/null
fi
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px "$ICON_PNG" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$ICON_PNG" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Helios</string>
    <key>CFBundleDisplayName</key><string>Helios</string>
    <key>CFBundleIdentifier</key><string>local.helios</string>
    <key>CFBundleExecutable</key><string>Helios</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets a locally built app run. codesign rejects
# extended attributes (Finder info etc.) that sips/iconutil can leave behind.
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Replace the installed copy in place (ditto preserves the signature and metadata).
    rm -rf /Applications/Helios.app
    ditto "$APP" /Applications/Helios.app
    # Nudge Finder/Dock to pick up the new icon.
    touch /Applications/Helios.app
    echo "Installed to /Applications/Helios.app"
fi
