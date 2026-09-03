#!/bin/bash
#
# Build Vaultkit and install it into /Applications for your own use.
#
#   scripts/install-local.sh
#
# This is the local path, NOT the distribution one — see release.sh for that.
# The bundle is signed ad-hoc ("-"), which is enough for macOS to run it on
# this machine but is tied to it: the app is not notarized and will not open
# on anyone else's Mac. Ad-hoc identity also changes whenever the binary is
# rebuilt, so macOS treats each build as a new app and any TCC permission
# (Files and Folders, say) is asked for again.
#
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

BUNDLE_ID="${VAULTKIT_BUNDLE_ID:-com.tugane.Vaultkit}"
DEST="${VAULTKIT_DEST:-/Applications}"
VERSION=$(grep -m1 'static let current' Sources/Vaultkit/Models/Models.swift | sed -E 's/.*"(.+)".*/\1/')
[[ -n "$VERSION" ]] || { echo "could not read the version from Models.swift" >&2; exit 1; }
APP="release/Vaultkit.app"

echo "==> build (release) — Vaultkit $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift build -c release --disable-sandbox
cp "$(swift build -c release --show-bin-path)/Vaultkit" "$APP/Contents/MacOS/Vaultkit"

echo "==> icon"
scripts/make-icon.sh "$APP/Contents/Resources/Vaultkit.icns"

echo "==> assemble"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vaultkit</string>
    <key>CFBundleDisplayName</key><string>Vaultkit</string>
    <key>CFBundleExecutable</key><string>Vaultkit</string>
    <key>CFBundleIconFile</key><string>Vaultkit</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright (C) 2026 Amiel Tugane Mutarataza. GPL-3.0-or-later.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> sign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> install to $DEST"
# Replace rather than merge: a stale file from an older build left inside the
# bundle would still be signed for and could be loaded.
rm -rf "$DEST/Vaultkit.app"
cp -R "$APP" "$DEST/Vaultkit.app"
# Let the icon services notice the bundle actually changed.
touch "$DEST/Vaultkit.app"

echo
echo "installed: $DEST/Vaultkit.app  (Vaultkit $VERSION, ad-hoc signed)"
echo "open it with:  open -a Vaultkit"
