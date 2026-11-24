#!/usr/bin/env bash
# Builds Helios.app into ./build.noindex (".noindex" keeps Spotlight from listing a second copy). Pass --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Helios"
APP="build.noindex/Helios.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Helios"

# App icon: render once, then build every size macOS wants into an .icns.
ICON_PNG="build.noindex/icon-1024.png"
if [[ ! -f "$ICON_PNG" || scripts/make-icon.swift -nt "$ICON_PNG" ]]; then
    swift scripts/make-icon.swift "$ICON_PNG" >/dev/null
fi
ICONSET="build.noindex/AppIcon.iconset"
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
    <key>NSDesktopFolderUsageDescription</key><string>Programs you run in Helios's terminals (like Claude Code) read and write files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Programs you run in Helios's terminals (like Claude Code) read and write files in Documents.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Programs you run in Helios's terminals (like Claude Code) read and write files in Downloads.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Programs you run in Helios's terminals read and write files on external drives.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Programs you run in Helios's terminals read and write files on network volumes.</string>
</dict>
</plist>
PLIST

# Sign with the local "Helios Local Signing" certificate when present (see
# scripts/make-signing-cert.sh): macOS keys privacy grants such as Full Disk Access to the
# signature, so a stable identity keeps them across rebuilds. Otherwise fall back to an
# ad-hoc signature, whose grants reset on every build. codesign rejects extended attributes
# (Finder info etc.) that sips/iconutil can leave behind.
# Sign a copy outside the project: when it lives in an iCloud-synced folder, the sync
# re-adds Finder info to the bundle between xattr and codesign.
SIGN_DIR="$(mktemp -d)"; trap 'rm -rf "$SIGN_DIR"' EXIT
ditto --norsrc --noextattr "$APP" "$SIGN_DIR/Helios.app"
xattr -cr "$SIGN_DIR/Helios.app"
IDENTITY="Helios Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$SIGN_DIR/Helios.app"
else
    echo "note: no '$IDENTITY' certificate; ad-hoc signing (privacy grants reset each build)" >&2
    codesign --force --sign - "$SIGN_DIR/Helios.app"
fi
rm -rf "$APP"
ditto "$SIGN_DIR/Helios.app" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Replace the installed copy in place (ditto preserves the signature and metadata).
    rm -rf /Applications/Helios.app
    ditto "$SIGN_DIR/Helios.app" /Applications/Helios.app
    # Nudge Finder/Dock to pick up the new icon.
    touch /Applications/Helios.app
    echo "Installed to /Applications/Helios.app"
fi
