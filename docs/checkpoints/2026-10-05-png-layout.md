# 2026-10-05 — PNG layout repair and updated DJ package

The real 24.136-second Baby capture exposed a misleading export scale: the final
0.136-second row filled the same width as a four-second row. Timed PNG rows now
span whole-bar durations using the recorded BPM and meter, with a minimum of
four seconds per row to retain the existing bounded allocation. Movement check
keeps four-second rows. Final partial rows occupy proportional width. The chart
retains its take-relative beat origin; no recording or beat clock is retimed.

PNG-only 1.5x chart scaling enlarges strokes and labels. Concise footer wording
replaces the long diagnostic paragraph, with all detailed reasons retained in the
original JSON. The stored projection, measured curves, separate faders, confidence
rules and unknown intervals are unchanged. No new decoder defect was demonstrated.

Files changed:
- ScratchLab/Services/ReferenceNotationPNGExport.swift
- ScratchLab/Services/SessionExportCoordinator.swift
- ScratchLabDesktopTests/ScratchNotationPanelTests.swift
- docs/capture_notation_png.md and workflow/checkpoint documentation

Verification: 36 focused XCTest executions passed, including a temporary isolated
inspection that regenerated the supplied take without changing its projection.
Both PNG pages were visually inspected and were byte-identical across the two
native test configurations. That local-only inspection method was removed before
the final gate and is not included in the app, committed tests or distribution.
Required scripts/build.sh all PASS: 9,190 XCTest executions passed, 124 existing
skips, zero failures; 1,064 Swift Testing and 123 Python tests passed. iOS, full
macOS Release, macOS CXLRelease and watchOS builds passed. New partial-row/meter
regression executed twice. All supervised children were reaped with no survivors.

The existing Developer-ID overlay build passed with signing-only settings
differences. Runtime/data/resource equivalence with the tested Capture build was
verified for both architectures, classifying only signature, UUID and exact debug
file-path differences. Stage receipt, strict signature and ZIP extraction/hash
round-trip passed. Installed baseline app retained unchanged; no app installation,
launch, new hardware acceptance, Learner edits, decoder changes or signing changes.

Distribution: /Users/karlwatson/Downloads/SL-Capture-Pro-DJ-PNG-2026-10-05.zip
ZIP SHA-256: 11335f53f10d5106f54959b6c308dd79ef67806a19eaa79719765a1d54e3afaa
Executable SHA-256: 552800295d1c04a09a66c72bd858fbdf7958f3d115e17e2dcdc0e4f0d0c9aa74
Universal Mac app, macOS 15+, version 1.0.1 (24). Developer ID signed, not notarized.
Each new DJ rig still needs one short record/play/save/reopen/export check before
a long session. Save Capture preserves raw evidence even when canonical approval
is unavailable; PNG appearance does not establish physical truth or teaching fitness.

Open an existing saved draft and Save Capture again for corrected PNG references.
No new recording is needed for this layout repair. Preserve prior accepted
muted-trace/two-fader evidence within its original scope. The supplied take's grey
regions remain unknown and are not converted to stationary holds or target triangles.

Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-05/png-layout-repair
Read full-verification-summary.json, real-capture-preview-receipt.json,
DELIVERY-RECEIPT.json and GIT-RECEIPT.json for exact software, source, package and
publication receipts. Raw capture evidence and build output remain local; the app
ZIP contains no user capture files. Unrelated dirty/untracked work is preserved.
