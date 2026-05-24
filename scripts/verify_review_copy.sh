#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

FILES=(
  "ScratchLabDesktop/Views/MacAnalyzerView.swift"
  "ScratchLabDesktop/Views/NotationVisualizerView.swift"
)

echo "== stale user-facing Text strings: classified strokes =="
if grep -nE 'Text\("[^"]*classified strokes' "${FILES[@]}"; then
  echo "FAIL: stale user-facing Text string containing 'classified strokes'" >&2
  exit 1
fi
echo "PASS: none"

echo "== stale user-facing Text strings: diagnostics only =="
if grep -nE 'Text\("[^"]*[Dd]iagnostics only' "${FILES[@]}"; then
  echo "FAIL: stale user-facing Text string containing diagnostics only" >&2
  exit 1
fi
echo "PASS: none"

echo "== stale return strings: classified strokes / diagnostics only =="
if grep -nE 'return "[^"]*(classified strokes|[Dd]iagnostics only)' "${FILES[@]}"; then
  echo "FAIL: stale return string" >&2
  exit 1
fi
echo "PASS: none"

echo "== macOS build =="
xcodebuild build \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_review_copy_macos.log \
  | tail -40
grep -q "BUILD SUCCEEDED" /tmp/scratchlab_verify_review_copy_macos.log

echo "PASS: Review copy verification succeeded"
