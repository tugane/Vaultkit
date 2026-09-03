#!/bin/bash
#
# Build, sign, notarize and staple a distributable Vaultkit.dmg.
#
#   scripts/release.sh              # release the version in Models.swift
#   VAULTKIT_IDENTITY="..." scripts/release.sh
#
# Vaultkit is a SwiftPM executable, not an Xcode target, so there is no archive
# to export: the .app bundle is assembled here around the built binary. The
# rest follows the same order Auger's pipeline learned the hard way:
#
#  * The app is notarized and stapled BEFORE the DMG is built, so the DMG
#    contains an already-stapled app. The DMG is then signed, notarized and
#    stapled too, so a downloaded image opens with no network round-trip.
#  * The binary is signed with --options runtime. Notarization rejects
#    anything without the hardened runtime, and nothing earlier complains:
#    the build succeeds, the app runs locally, the submission is refused.
#  * DEVELOPER_DIR is set explicitly because xcode-select may point at
#    CommandLineTools, which cannot build SwiftUI's macros.
#
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

IDENTITY="${VAULTKIT_IDENTITY:-Developer ID Application: Amiel Tugane Mutarataza (A98VDXK9K4)}"
PROFILE="${VAULTKIT_NOTARY_PROFILE:-auger-notary}"
BUNDLE_ID="${VAULTKIT_BUNDLE_ID:-com.tugane.Vaultkit}"

VERSION=$(grep -m1 'static let current' Sources/Vaultkit/Models/Models.swift | sed -E 's/.*"(.+)".*/\1/')
[[ -n "$VERSION" ]] || { echo "could not read the version from Models.swift" >&2; exit 1; }
APP="release/Vaultkit.app"

echo "==> releasing Vaultkit $VERSION"

echo "==> tests"
# The Swift Testing helper can fail to load an all-XCTest suite and take the
# exit code with it, so assert on the reported results instead.
swift test > /tmp/vaultkit-release-test.log 2>&1 || true
if ! grep -qE "Executed [0-9]+ tests, with 0 failures" /tmp/vaultkit-release-test.log; then
  echo "tests failed — see /tmp/vaultkit-release-test.log" >&2
  tail -30 /tmp/vaultkit-release-test.log >&2
  exit 1
fi
grep -E "Executed [0-9]+ tests" /tmp/vaultkit-release-test.log | tail -1

echo "==> build (release)"
rm -rf release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift build -c release --disable-sandbox > release/build.log 2>&1
cp "$(swift build -c release --show-bin-path)/Vaultkit" "$APP/Contents/MacOS/Vaultkit"

echo "==> assemble the bundle"
scripts/make-icon.sh "$APP/Contents/Resources/Vaultkit.icns"
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

echo "==> sign (hardened runtime)"
# Vaultkit is deliberately unsandboxed: it must read ~/.ssh and ~/.gitconfig and
# drive diskutil. The hardened runtime is what notarization requires; the app
# sandbox would break the tool's entire purpose.
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarize the app"
ditto -c -k --keepParent "$APP" release/Vaultkit-app.zip
xcrun notarytool submit release/Vaultkit-app.zip --keychain-profile "$PROFILE" --wait --timeout 25m
xcrun stapler staple "$APP"

echo "==> build the DMG"
mkdir -p release/dmg-staging
cp -R "$APP" release/dmg-staging/
ln -s /Applications release/dmg-staging/Applications
hdiutil create -volname "Vaultkit" -srcfolder release/dmg-staging \
  -format UDZO release/Vaultkit.dmg > /dev/null
codesign --force --sign "$IDENTITY" --timestamp release/Vaultkit.dmg

echo "==> notarize the DMG"
xcrun notarytool submit release/Vaultkit.dmg --keychain-profile "$PROFILE" --wait --timeout 25m
xcrun stapler staple release/Vaultkit.dmg

echo "==> verify as a downloader would see it"
xcrun stapler validate release/Vaultkit.dmg
hdiutil attach release/Vaultkit.dmg -nobrowse -mountpoint /tmp/vaultkit-release-verify > /dev/null
spctl -a -vv --type execute /tmp/vaultkit-release-verify/Vaultkit.app
hdiutil detach /tmp/vaultkit-release-verify > /dev/null

echo
echo "Vaultkit $VERSION"
shasum -a 256 release/Vaultkit.dmg
echo
echo "Publish it, and put that SHA-256 in the release notes so people can check"
echo "what they downloaded:"
echo "  gh release create v$VERSION release/Vaultkit.dmg --title \"Vaultkit $VERSION\""
