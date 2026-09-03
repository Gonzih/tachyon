#!/bin/bash
# Builds Tachyon.app from the SwiftPM executable target.
#
# The app bundle exists for two reasons: LSUIElement (no Dock icon even if the
# activation-policy call ever regressed) and SMAppService, which registers a
# bundle rather than a bare binary.
#
# Signing modes:
#   ./build.sh                       ad-hoc (local dev)
#   SIGN_IDENTITY="Developer ID Application: Wild Honey on the Porch, LLC (UQB3368A84)" ./build.sh
#                                    Developer ID + hardened runtime
#   NOTARIZE=1 SIGN_IDENTITY=... ./build.sh
#                                    + notarize via keychain profile
#                                    (xcrun notarytool store-credentials tachyon-notary ...)
#                                    + staple + zip for release
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tachyon-notary}"

swift build -c release

APP="build/Tachyon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Tachyon "$APP/Contents/MacOS/Tachyon"
cp assets/Tachyon.icns "$APP/Contents/Resources/Tachyon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.gonzih.tachyon</string>
  <key>CFBundleName</key><string>Tachyon</string>
  <key>CFBundleDisplayName</key><string>Tachyon</string>
  <key>CFBundleExecutable</key><string>Tachyon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleIconFile</key><string>Tachyon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
    # Keep an explicit signing identifier, but do not mistake it for a stable
    # TCC identity: an ad-hoc designated requirement is tied to this exact
    # build. The Claude keychain read does not depend on it; it shells out to
    # /usr/bin/security precisely so the "Always Allow" ACL survives rebuilds.
    codesign --force --sign - --identifier dev.gonzih.tachyon "$APP"
    echo "Built $APP (ad-hoc)"
else
    # Developer ID: hardened runtime is required for notarization. No
    # entitlements needed — Tachyon is not sandboxed and uses no restricted
    # capabilities.
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" --identifier dev.gonzih.tachyon "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Built $APP (signed: $SIGN_IDENTITY)"

    if [ "${NOTARIZE:-0}" = "1" ]; then
        ZIP="build/Tachyon-${VERSION}.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Submitting to notary service…"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        # Re-zip with the stapled ticket — this is the release artifact.
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarized + stapled: $ZIP"
    fi
fi

echo "Install: cp -R $APP ~/Applications/   (required for Launch at Login)"
