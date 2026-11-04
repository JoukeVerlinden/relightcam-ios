#!/bin/bash
# Archive relightCam for App Store Connect and (optionally) upload it to TestFlight.
#   tools/testflight.sh            -> archive + export a signed .ipa to build/export (nothing is uploaded)
#   tools/testflight.sh --upload   -> archive + upload to App Store Connect (the app record must exist)
# Each run gets a fresh build number (yyMMddHHmm), so uploads never collide.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD=$(date +%y%m%d%H%M)
ARCHIVE=build/relightCam-$BUILD.xcarchive
OPTS=$(mktemp -t ExportOptions).plist
cp tools/ExportOptions.plist "$OPTS"
if [ "${1:-}" = "--upload" ]; then
  /usr/libexec/PlistBuddy -c "Set :destination upload" "$OPTS"
fi

echo "Archiving build $BUILD…"
xcodebuild -project RelightCam.xcodeproj -scheme RelightCam -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" archive \
  | grep -E "error:|warning: .*(sign|provision)|ARCHIVE" || true
[ -d "$ARCHIVE" ] || { echo "Archive failed"; exit 1; }

echo "Exporting…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" \
  -exportPath build/export -allowProvisioningUpdates \
  | grep -E "error|Upload|EXPORT|Uploaded|succeeded|failed" || true
rm -f "$OPTS"
ls -la build/export 2>/dev/null || true
