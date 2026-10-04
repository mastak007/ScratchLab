# Checkpoint — SL Capture PNG references, 4 October 2026

User authorized implementation, checkpoint, commit and push. Save Capture previously
exported media and notation JSON without a PNG reference. The completed feature
adds source-bound, paginated images of the saved canonical notation to the same
validated ZIP. Existing drafts can be exported again without recording.

## Changed
- Shared ReferenceNotationPNGExport service and both platform source memberships.
- SessionExportCoordinator: generation after source validation, PNG/source binding,
  hydration, manifest file and hash records, staged and extracted byte verification.
- Save Capture explanatory copy and generic quick-start instructions.
- Native PNG/geometry/archive regressions and strict optional PNG validation in
  the existing offline validator. Unknown artifact keys remain rejected.

## Verification
9188 XCTest executions passed, 124 skipped, zero failures; 1064 Swift Testing and 123 Python tests passed. iOS, macOS Release, macOS CXLRelease and watchOS builds passed.
Final focused gate: 34 XCTest executions passed, including the repaired MIDI Learn test. Four new native tests each ran
twice in the full gate; the new Python case passed. Synthetic rendered page
inspection confirmed the header/footer, four rows, independent fader cuts and
MOTION UNKNOWN gap. Round-trip tests decoded images, retained exact companion
bytes and verified archive hashes. Stale image bindings and corrupt PNGs fail.

An initial full gate stopped on an existing MIDI Learn test that drained the main
run loop for a fixed 50 ms before checking an asynchronous publication. Its first
execution passed and its second checked too early. The one test now awaits the
actual Listening feedback event, retaining the same state/feedback assertions,
and uses its existing injected MIDI preferences seam with a unique test-owned
suite (the focused check exposed a saved-mapping dependency).
No production MIDI code changed and no sleep, polling, retry policy or decoder
threshold was added. The failed receipt and diagnosis remain in local evidence;
a fresh complete gate verified the amended candidate.

The full-gate candidate and the Developer ID app have identical runtime/data and
resource payloads, with only classified signing, UUID and debug-path differences.
Strict signature verification and delivery ZIP extraction/hash comparison passed.

## Delivery
/Users/karlwatson/Downloads/SL-Capture-Pro-DJ-PNG-2026-10-04.zip
ZIP SHA-256: 5270f79e57ad32ee985f47612816e88ce3cd3d36ad082a216bffee1135c62a4c
Executable SHA-256: 70cad5e9f984750c7af78897a204360cdd3e75a9c3ce7f734724f4aaac4ba903
macOS 15+, Intel and Apple silicon; version 1.0.1 (24).
Developer ID signed; not notarized. This package was not installed or launched.

## Evidence and boundaries
/Users/karlwatson/ScratchLab-Local-Evidence/2026-10-04/capture-notation-png
The source slice is the earlier verified generic performer update plus the PNG
feature. Canonical unrelated dirty changes were preserved and excluded. Original
captures, decoder confidence/loss rules, audio, calibration, scoring, Learner and
signing settings were not changed. Existing accepted two-fader audio/state/export
and muted-trace evidence stays accepted within its original scope. No new rig,
operator PNG acceptance or training-data eligibility is claimed.
PNG output is supplementary; raw media and canonical JSON remain authoritative.
The separate Export Approved Package format is unchanged.
