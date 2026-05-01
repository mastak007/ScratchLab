#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/ScratchLab.xcodeproj"
MODE="${1:-all}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install Xcode command line tools first."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to run capture-pipeline fixture tests."
  exit 1
fi

run_capture_pipeline_fixtures() {
  echo "==> Running capture-pipeline fixture tests"
  python3 "$SCRIPT_DIR/test_capture_pipeline.py"
}

run_mac_tests() {
  echo "==> Running ScratchLabDesktop XCTest plan"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme ScratchLabDesktop \
    -destination 'platform=macOS' \
    test
}

build_ios() {
  echo "==> Building ScratchLab (iOS)"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme ScratchLab \
    -destination 'generic/platform=iOS' \
    build
}

build_mac() {
  echo "==> Building ScratchLabDesktop (macOS)"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme ScratchLabDesktop \
    -destination 'platform=macOS' \
    build
}

build_watch() {
  echo "==> Building ScratchLabWatch (watchOS)"
  xcodebuild \
    -project "$PROJECT_PATH" \
    -target ScratchLabWatch \
    -sdk watchos \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
}

case "$MODE" in
  ios)
    run_capture_pipeline_fixtures
    run_mac_tests
    build_ios
    ;;
  mac)
    run_capture_pipeline_fixtures
    run_mac_tests
    build_mac
    ;;
  watch)
    run_capture_pipeline_fixtures
    run_mac_tests
    build_watch
    ;;
  all)
    run_capture_pipeline_fixtures
    run_mac_tests
    build_ios
    build_mac
    build_watch
    ;;
  *)
    echo "Usage: scripts/build.sh [ios|mac|watch|all]"
    exit 1
    ;;
esac
