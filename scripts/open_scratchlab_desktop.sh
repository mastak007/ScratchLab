#!/usr/bin/env zsh
set -euo pipefail

PROJECT="ScratchLab.xcodeproj"
SCHEME="ScratchLabDesktop"

echo "Building $SCHEME (macOS Debug)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  -configuration Debug \
  build \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\*" | tail -5

# Resolve exact build product path from build settings
BUILD_SETTINGS=$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -showBuildSettings 2>/dev/null)

DERIVED=$(echo "$BUILD_SETTINGS" | grep "BUILT_PRODUCTS_DIR" | head -1 | sed 's/.*= //')
PRODUCT=$(echo "$BUILD_SETTINGS" | grep "FULL_PRODUCT_NAME" | head -1 | sed 's/.*= //')

APP="${DERIVED}/${PRODUCT}"

if [[ ! -d "$APP" ]]; then
  # Fallback: most-recently modified macOS .app under DerivedData, excluding iOS
  APP=$(find ~/Library/Developer/Xcode/DerivedData \
    -type d -name "*.app" \
    -path "*/Debug/*" \
    ! -path "*iphoneos*" \
    ! -path "*iphonesimulator*" \
    -print0 2>/dev/null \
    | xargs -0 stat -f "%m %N" \
    | sort -nr | head -1 | cut -d" " -f2-)
fi

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "ERROR: Could not locate macOS app bundle" >&2
  exit 1
fi

# Confirm this is a macOS binary (guard against accidentally opening iOS build)
PLATFORM=$(plutil -p "${APP}/Contents/Info.plist" 2>/dev/null \
  | awk -F'"' '/DTPlatformName/ { print $4 }')
if [[ "$PLATFORM" != "macosx" ]]; then
  echo "ERROR: App at $APP is not a macOS build (DTPlatformName=${PLATFORM})" >&2
  exit 1
fi

echo "Opening macOS app (platform=${PLATFORM}): ${APP}"
open "$APP"
