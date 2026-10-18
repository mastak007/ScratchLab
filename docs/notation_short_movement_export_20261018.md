# Short movement-check export correction — completed 18 October 2026

The supplied 84BDB91F recording lasts 10.034512 seconds. Its first deliberate forward stroke lasts 2.028879 seconds; the nearly equal-distance return lasts 0.294050 seconds, making the return 6.872 times faster on average. Four-second PNG rows split this pair. Independent row height scales also magnified the final small movement by about 54.5 times relative to the second row. See the original read-only analysis in ../short95-84BDB91F-analysis/REPORT.md.

## Implemented correction

Short beatless movement checks, up to 16 seconds, now export as one full-width chart, 900 points tall. The existing affine fit supplies one fixed linear height scale for the entire take. The first forward/return pair stays together; slopes preserve the measured timing and travel. The footer explicitly describes the scale.

Longer and timed exports retain their existing pagination. The live review and pinned close-up are unchanged. The 16-second limit is a presentation choice, not a claim that all longer recordings avoid row-boundary cuts. Small movements remain small relative to larger movements; there is no per-stroke amplification or idealized wave.

Raw vertices, timestamps, decoder thresholds, confidence rules, canonical evidence, metadata, stored schemas, audio, capture and approval are unchanged. Render identity revision 4 invalidates older derived pictures only.

## Files changed

- ScratchLab/Services/ReferenceNotationPNGExport.swift: short-take layout, height, scale wording and derived-picture identity.
- ScratchLabDesktopTests/ScratchNotationPanelTests.swift: actual supplied-capture regression and short/timed/long boundary cases; updated the existing short-take pagination expectation while retaining geometry assertions.
- TASKS.md, DEV_LOG.md, AI_HANDOFF.md and AI_HANDOFF/next_prompt.md: task and continuation records.

## Verification status

- Red regression: four expected failing executions reproduced the split/full-width defect. The recorded speed ratio already passed before the layout change.
- Focused corrected class: 22 executions passed, covering 11 named cases in two configurations.
- Visual inspection: complete 10.035-second take fits one page; gradual forward motion and sharp return appear together; confidence bands and unknown gaps remain; labels and footer fit.
- Warm build and repository-access preflight: passed.
- Full `scripts/build.sh all`: 9,514 XCTest passes, 124 optional skips, 1,064 named Swift Testing passes, 123 Python passes, zero failures. All 120 required selectors executed twice; 45 render artifacts present. iOS, macOS Release, CXLRelease and Watch builds passed. Frozen snapshot: 6f60e4bc33539104452d0e4241de098cbb3da9b06a9d2d4621fdbb45031514f4. Supervisors reaped their children with no survivors. Six timed80/95 export pages match the previously inspected images byte for byte.
- Signed universal Mac installation and native Save Capture: passed. The actual ZIP contains one1600×1420 PNG; all six declared artifact hashes and sizes match. Original MOV/WAV, bound raw sidecar, canonical16records, detected notation and session metadata are unchanged. The native save dialog was observed and accepted. Checkpoint identity is recorded separately in GIT-RECEIPT.json.
- New physical/audio, Intel responsiveness and operator acceptance: not run.

The protected baseline contains 62 pre-existing review files, 11 earlier Applications copies, original archives/media and the untracked cxl_baby_target.json. All 62 original review files and 11 earlier applications were preserved. A separate labelled unapproved copy was added; no bounds, preference or approval changes were made. Runtime: /private/tmp/sl-short-take-export-20261018. Canonical base commit: 19cc31e.

## Installed result and remaining limits

Installed and opened: `/Applications/SL Capture Complete Movement 2026-10-18.app`.
Executable SHA256: `70d0c8a4bd196fd5ae061f63e0d8860857819205072dc58630a642af969262e5`.
Developer ID signed, stable CXL identifier/team, arm64 and x86_64; ZIP round-trip signature/content check passed. This is a local development candidate, not a notarized public release.

Review copy: `ui-short-export-check-11f0bcba-1ad6-4b4e-a144-62bc09accb2c`. Actual exported archive: `short95-complete-movement.zip`, SHA256 `c847d447345bad39b263984b26158c7c64bd6030fd480b1d8b9ebd469ea946a8`.

The first live-export observer had an incorrect assumption copied from the older timed-take export: file/artifact key equality and a separate sidecar artifact. The supplied movement-check source ZIP uses the same notation-only file entry and embeds raw sidecar data in its source binding. The observer was corrected against that existing contract and now verifies the embedded sidecar SHA/bytes, all declared artifacts, unchanged detected notation/session metadata and source media. The failed observer is retained in evidence; no product change or weakened preservation assertion was needed. An overly broad accessibility read was stopped and replaced with bounded queries; no app process was terminated for it.

To verify, open the actual exported PNG in `live-export-pages/notation_png_001.png`. The first deliberate forward movement lasts2.028879s; its near-equal-distance return lasts0.294050s. Both appear together on one linear scale. The later long release and small ending movements retain their true relative sizes. Longer/timed export layouts and live review are unchanged. Grey gaps remain unknown; this change does not recover absent telemetry. No new recording/audio/Intel or learner acceptance is claimed. No additional full run is required for the workflow documentation.
