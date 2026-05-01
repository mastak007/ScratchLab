#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$REPO_ROOT/ScratchLab.xcodeproj"
SCHEME_NAME="ScratchLabWatch"
CONFIGURATION="Debug"

WATCH_DEVICE_ID="${1:-${WATCH_DEVICE_ID:-}}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install Xcode command line tools first."
  exit 1
fi

if ! xcrun -f devicectl >/dev/null 2>&1; then
  echo "devicectl is not available in the active Xcode."
  echo "Select a recent Xcode with: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

DESTINATIONS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME_NAME" -showdestinations 2>&1 || true)"
if echo "$DESTINATIONS" | grep -Eq "watchOS .* is not installed"; then
  echo "The active Xcode is missing the watchOS runtime needed for watch device builds."
  echo "Install it with: xcodebuild -downloadPlatform watchOS"
  exit 1
fi

if [[ -z "$WATCH_DEVICE_ID" ]]; then
  WATCH_DEVICE_ID="$(
    echo "$DESTINATIONS" \
      | awk -F'id:' '
          /platform:watchOS/ && $0 !~ /placeholder/ && $0 !~ /Simulator/ {
            split($2, fields, ",");
            gsub(/ /, "", fields[1]);
            print fields[1];
            exit
          }
        '
  )"
fi

if [[ -z "$WATCH_DEVICE_ID" ]]; then
  echo "No paired Apple Watch destination found."
  echo "Unlock the watch and its paired iPhone, keep both on the same network, then rerun."
  exit 1
fi

echo "Using watch: $WATCH_DEVICE_ID"

echo "Building watch app with automatic provisioning updates..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -destination "id=$WATCH_DEVICE_ID" \
  -configuration "$CONFIGURATION" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

BUILD_SETTINGS="$(
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -destination "id=$WATCH_DEVICE_ID" \
    -configuration "$CONFIGURATION" \
    -showBuildSettings 2>/dev/null
)"

TARGET_BUILD_DIR="$(
  echo "$BUILD_SETTINGS" | awk -F' = ' '
    /Build settings for action build and target ScratchLabWatch:/ {in_target=1; next}
    in_target && /TARGET_BUILD_DIR/ {print $2; exit}
  '
)"
WRAPPER_NAME="$(
  echo "$BUILD_SETTINGS" | awk -F' = ' '
    /Build settings for action build and target ScratchLabWatch:/ {in_target=1; next}
    in_target && /WRAPPER_NAME/ {print $2; exit}
  '
)"
APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"

if [[ -z "$TARGET_BUILD_DIR" || -z "$WRAPPER_NAME" || ! -d "$APP_PATH" ]]; then
  echo "Build finished, but watch app not found at:"
  echo "  $APP_PATH"
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")"

echo "Installing $BUNDLE_ID..."
ATTEMPT=1
MAX_ATTEMPTS=3
while true; do
  if INSTALL_OUTPUT="$(xcrun devicectl device install app --device "$WATCH_DEVICE_ID" "$APP_PATH" 2>&1)"; then
    echo "$INSTALL_OUTPUT"
    break
  fi

  echo "$INSTALL_OUTPUT"
  if [[ "$ATTEMPT" -ge "$MAX_ATTEMPTS" ]]; then
    echo "Watch install failed after $ATTEMPT attempts."
    echo "Keep the watch and its paired iPhone unlocked and reachable over Wi-Fi, then rerun."
    exit 1
  fi

  echo "Install attempt $ATTEMPT failed. Retrying..."
  ATTEMPT=$((ATTEMPT + 1))
  sleep 3
done

echo "Done."
