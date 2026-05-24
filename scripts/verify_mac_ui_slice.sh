#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

echo "== macOS build =="
xcodebuild build \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_mac_ui_slice.log \
  | tail -40

grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_mac_ui_slice.log

echo "== git status =="
git status --short --branch

echo "PASS: macOS UI slice build succeeded"
