#!/bin/bash
# Build relightCam (Release) for a connected iPhone and install + launch it.
#   tools/install.sh                     -> first reachable iPhone
#   tools/install.sh "My iPhone"         -> a specific device by name (or CoreDevice identifier)
# Waits up to 10 minutes for the phone (USB, or Wi-Fi on a network that allows device-to-device traffic).
# New phones are registered with the signing team automatically (needs a signed-in Xcode account).
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
WANT="${1:-}"
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/RelightCam-cli}"
BUNDLE=be.uantwerpen.jverlinden.relightcam

# prints: <coredevice id> <udid> <developer mode> <name>
find_device() {
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  python3 -I - "$json" "$WANT" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
for x in d.get("result", {}).get("devices", []):
    hp, dp, cp = x["hardwareProperties"], x["deviceProperties"], x.get("connectionProperties", {})
    if hp.get("deviceType") != "iPhone": continue
    if want and want not in (dp.get("name"), x["identifier"]): continue
    # "unavailable" means not reachable right now
    if cp.get("tunnelState") != "unavailable":
        print(x["identifier"], hp.get("udid"), dp.get("developerModeStatus"), dp.get("name")); break
EOF
  rm -f "$json"
}

echo "Waiting for a connected iPhone${WANT:+ ($WANT)}…"
DEV=""
for i in $(seq 1 120); do
  DEV=$(find_device || true)
  [ -n "$DEV" ] && break
  sleep 5
done
[ -n "$DEV" ] || { echo "No iPhone reachable after 10 minutes."; exit 2; }
read -r ID UDID MODE NAME <<<"$DEV"
echo "Found $NAME ($UDID), developer mode: $MODE"

if [ "$MODE" != "enabled" ]; then
  echo "Turn on Developer Mode on the phone: Settings › Privacy & Security › Developer Mode, restart, confirm."
  for i in $(seq 1 120); do
    sleep 5
    MODE=$(find_device | awk '{print $3}')
    [ "$MODE" = "enabled" ] && break
  done
  [ "$MODE" = "enabled" ] || { echo "Developer Mode still off."; exit 3; }
fi

# Pair (shows "Trust This Computer?" on the phone) if needed; harmless when already paired.
xcrun devicectl manage pair --device "$ID" --timeout 120 >/dev/null 2>&1 || true

echo "Building for $NAME…"
xcodebuild -project RelightCam.xcodeproj -scheme RelightCam -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 \
  | grep -E "error:|BUILD" | grep -v DVTDeveloperAccount
APP="$DD/Build/Products/Release-iphoneos/RelightCam.app"
[ -d "$APP" ] && security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | grep -q "$UDID" || {
  echo "Build failed, or $NAME is not in the provisioning profile yet."
  echo "Sign in again in Xcode › Settings › Accounts, then rerun this script."
  exit 4
}

echo "Installing on $NAME…"
xcrun devicectl device install app --device "$ID" "$APP" || exit 5
xcrun devicectl device process launch --device "$ID" "$BUNDLE" \
  || echo "Installed. Open it from the home screen (trust the developer in Settings › General › VPN & Device Management if asked)."
