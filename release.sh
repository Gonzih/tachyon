#!/bin/bash
# Cloud-signed release pipeline for Tachyon.
#
# Uses the team's *cloud-managed* Developer ID certificate (Apple holds the
# key; an Admin with "Access to Cloud Managed Developer ID Certificate" can
# sign). Plain `codesign` cannot use cloud keys, so signing goes through
# `xcodebuild -exportArchive` against a fabricated .xcarchive; notarization
# goes through notarytool with the "tachyon-notary" keychain profile.
#
#   ./release.sh [version]        e.g. ./release.sh 1.0
#
# Output: build/Tachyon-<version>.zip — signed, notarized, stapled.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
TEAM_ID="UQB3368A84"

# Refuse to sign or notarize anything that has not passed the exact same
# deterministic gate as CI, plus the credential-backed provider diagnostic.
./verify.sh --live

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Build the bundle (ad-hoc, hardened runtime so the flag survives re-sign).
VERSION="$VERSION" ./build.sh >/dev/null
codesign --force --options runtime --sign - --identifier dev.gonzih.tachyon build/Tachyon.app

# 2. Fabricate an .xcarchive around it.
ARCHIVE="$WORK/Tachyon.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications"
cp -R build/Tachyon.app "$ARCHIVE/Products/Applications/"
cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>Tachyon</string>
  <key>SchemeName</key><string>Tachyon</string>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Tachyon.app</string>
    <key>CFBundleIdentifier</key><string>dev.gonzih.tachyon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>Team</key><string>${TEAM_ID}</string>
  </dict>
</dict></plist>
PLIST

cat > "$WORK/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST

# 3. Cloud-sign locally.
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$WORK/exportOptions.plist" \
    -exportPath "$WORK/export" \
    -allowProvisioningUpdates | grep -E "Exported|EXPORT"
STAGED="$WORK/export"

# 4. Notarize the exact artifact, then staple it.
ditto -c -k --keepParent "$STAGED/Tachyon.app" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile tachyon-notary --wait
xcrun stapler staple "$STAGED/Tachyon.app"

spctl -a -vv --type exec "$STAGED/Tachyon.app"

# 5. Emit the release artifact.
OUT="build/Tachyon-${VERSION}.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$STAGED/Tachyon.app" "$OUT"
echo "Release artifact: $OUT"
