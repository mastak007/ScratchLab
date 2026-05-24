#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

FILE="ScratchLabDesktop/Views/MacAnalyzerView.swift"

echo "== check Motion samples badge =="
grep -n 'Motion samples' "$FILE"

echo "== check raw timeline accessor references =="
grep -n 'lastDrainedPlatterPositionTimeline' "$FILE"

echo "== macOS build =="
xcodebuild build \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_motion_samples_macos.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_motion_samples_macos.log

echo "== git status =="
git status --short --branch

echo "PASS: Review motion samples verification succeeded"
