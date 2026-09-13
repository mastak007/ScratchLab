#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${1:-$SCRIPT_DIR/..}"

echo "== iOS build =="
xcodebuild build \
  -scheme ScratchLab \
  -destination 'generic/platform=iOS' \
  | tee /tmp/scratchlab_verify_ios.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_ios.log

echo "== full macOS Release build =="
xcodebuild build \
  -scheme ScratchLabDesktop \
  -configuration Release \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_macos.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_macos.log

echo "== CXL macOS capture build =="
xcodebuild build \
  -scheme ScratchLabCXL \
  -configuration CXLRelease \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_cxl.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_cxl.log

echo "== macOS build-for-testing =="
xcodebuild build-for-testing \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_macos_bft.log \
  | tail -40
grep -q "TEST BUILD SUCCEEDED" /tmp/scratchlab_verify_macos_bft.log

echo "== git status =="
git status --short --branch

echo "PASS: iOS, full macOS Release, CXL, and macOS build-for-testing succeeded"
