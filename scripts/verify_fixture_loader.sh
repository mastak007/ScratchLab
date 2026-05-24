#!/usr/bin/env bash
set -euo pipefail

cd "${1:-/Users/karlwatson/Downloads/ScratchLab}"

XCTEST_BUNDLE="${XCTEST_BUNDLE:-$HOME/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest}"
FIXTURE="${BABY_PLATTER_FIXTURE_PATH:-$PWD/Tests/Fixtures/LocalOnly/baby_platter.json}"

echo "== macOS build-for-testing =="
xcodebuild build-for-testing \
  -scheme ScratchLabDesktop \
  -destination 'platform=macOS' \
  | tee /tmp/scratchlab_verify_fixture_bft.log \
  | tail -40
grep -q "TEST BUILD SUCCEEDED" /tmp/scratchlab_verify_fixture_bft.log

echo "== ensure xctest bundle exists =="
test -d "$XCTEST_BUNDLE" || {
  echo "FAIL: xctest bundle not found: $XCTEST_BUNDLE" >&2
  exit 1
}

echo "== env unset: BabyPlatterFixtureDecodeTests =="
env -u BABY_PLATTER_FIXTURE_PATH \
  xcrun xctest -XCTest ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests "$XCTEST_BUNDLE" \
  | tee /tmp/scratchlab_fixture_unset.log

grep -q "0 failures" /tmp/scratchlab_fixture_unset.log

echo "== fixture file exists =="
test -f "$FIXTURE" || {
  echo "FAIL: fixture not found: $FIXTURE" >&2
  exit 1
}

echo "== env set: BabyPlatterFixtureDecodeTests =="
BABY_PLATTER_FIXTURE_PATH="$FIXTURE" \
  xcrun xctest -XCTest ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests "$XCTEST_BUNDLE" \
  | tee /tmp/scratchlab_fixture_set.log

grep -q "0 failures" /tmp/scratchlab_fixture_set.log

echo "== DEBUG env var confinement check =="
awk '
  /^[[:space:]]*#if DEBUG/ { in_debug = 1; next }
  /^[[:space:]]*#endif/    { in_debug = 0; next }
  /BABY_PLATTER_FIXTURE_PATH/ {
    if (in_debug) print "DEBUG-OK  " FILENAME ":" NR ":" $0
    else {
      print "LEAK!     " FILENAME ":" NR ":" $0
      leaked = 1
    }
  }
  END { exit leaked ? 1 : 0 }
' ScratchLabDesktop/Views/MacAnalyzerView.swift

echo "PASS: fixture loader verification succeeded"
