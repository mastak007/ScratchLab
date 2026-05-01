#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$REPO_ROOT/ScratchLab.xcodeproj"
SCHEME_NAME="ScratchLab"
CONFIGURATION="Debug"
SDK="iphoneos"

DEVICE_ID="${1:-${DEVICE_ID:-}}"

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
if echo "$DESTINATIONS" | grep -q "iOS .* is not installed"; then
  echo "The active Xcode is missing required iOS device support."
  echo "Open Xcode -> Settings -> Components and install the iOS platform."
  exit 1
fi

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(
    xcrun devicectl list devices 2>/dev/null \
      | awk '
          /connected/ && /(iPhone|iPad)/ {
            for (i = 1; i <= NF; i++) {
              if ($i ~ /^[A-F0-9-]+$/ && length($i) == 36) {
                print $i
                exit
              }
            }
          }
        '
  )"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No connected iPhone/iPad found."
  echo "Connect and unlock your device, then rerun."
  exit 1
fi

echo "Using device: $DEVICE_ID"

echo "Checking lock state..."
LOCK_STATE="$(xcrun devicectl device info lockState --device "$DEVICE_ID" 2>/dev/null || true)"
if echo "$LOCK_STATE" | grep -q "passcodeRequired: true"; then
  echo "Phone is locked. Unlock it and rerun."
  exit 1
fi

echo "Building app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

BUILD_SETTINGS="$(
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    -showBuildSettings
)"

TARGET_BUILD_DIR="$(
  echo "$BUILD_SETTINGS" | awk -F' = ' '
    /Build settings for action build and target ScratchLab:/ {in_target=1; next}
    in_target && /TARGET_BUILD_DIR/ {print $2; exit}
  '
)"
WRAPPER_NAME="$(
  echo "$BUILD_SETTINGS" | awk -F' = ' '
    /Build settings for action build and target ScratchLab:/ {in_target=1; next}
    in_target && /WRAPPER_NAME/ {print $2; exit}
  '
)"
APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"

if [[ -z "$TARGET_BUILD_DIR" || -z "$WRAPPER_NAME" || ! -d "$APP_PATH" ]]; then
  echo "Build finished, but app not found at:"
  echo "  $APP_PATH"
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Info.plist")"

echo "Installing $BUNDLE_ID..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "Launching $BUNDLE_ID..."
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "Done."
