#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

echo "== iOS build =="
xcodebuild build \
  -scheme ScratchLab \
  -destination 'generic/platform=iOS' \
  | tee /tmp/scratchlab_verify_ios.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_ios.log

echo "== macOS build =="
xcodebuild build \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_macos.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_macos.log

echo "== macOS build-for-testing =="
xcodebuild build-for-testing \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_macos_bft.log \
  | tail -40
grep -q "TEST BUILD SUCCEEDED" /tmp/scratchlab_verify_macos_bft.log

echo "== git status =="
git status --short --branch

echo "PASS: iOS build, macOS build, and macOS build-for-testing succeeded"
