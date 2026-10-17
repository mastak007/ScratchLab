# Confidence-only recorded-motion visibility — completed 18 October 2026

## Root cause and correction

The decoder accepted continuous short travel runs but assigned confidence from amplitude: `min(0.95, 0.7 + abs(steps)/1000)`. The canonical projection's 0.75 eligibility cutoff was also controlling display, so supported movement disappeared behind unknown markers. The supplied 80 BPM take contains nine such intervals (1.394457 seconds); the 95 BPM take contains seven (1.296394 seconds). Separate packet gaps and discarded/undersampled runs remain genuinely unresolved.

`ReferenceRecordedMotionReview` provides an explicitly labelled display derivative. It recovers only single, uncorrected travel runs rejected solely for `lowMovementConfidence`, validates the raw sidecar binding, matches an accepted run from the existing decoder, and uses continuous dense trajectory samples through the existing projector. No endpoint fallback, second integrator, inferred hold or global threshold change. The existing measured timing and within-run slope shape are retained.

Recovered curves retain original confidence and amber qualification bands across Recorded travel, Movement detail, Sample position, inspection and PNGs. True grey unknown gaps remain. Speed comparison excludes the qualified low-confidence curves. Raw/canonical records, restored historical evidence, comparison, approval, schemas and original recordings are unchanged. The export revision changes derived-picture identity only. This does not recover motion missing from the recording or prove hand-motion ground truth.

## Files changed

- `ScratchLab/Models/Reference/ReferenceTake.swift`: narrowly guarded, non-persisted display derivative and reuse of dense projection.
- `ScratchLab/Models/Reference/ReferenceAuthoringSession.swift`: validated raw decode cache outside playback ticks, refreshed when the source binding changes.
- `ScratchLab/Models/ScratchStrokeGeometry.swift`: uncertainty ranges through prepared views; excludes them from speed comparison.
- `ScratchLab/Services/ReferenceNotationPNGExport.swift`: uncertainty legend and derived-picture render revision.
- `ScratchLab/Services/SessionExportCoordinator.swift`: derivative for PNG input only; canonical JSON unchanged.
- `ScratchLabDesktop/Views/ReferenceAuthoringView.swift`: three finalized display consumers and explicit uncertainty legend.
- `ScratchLabDesktop/Views/ScratchPhraseChartView.swift`: amber bands/caps with blue measured curves and grey unknown intervals.
- `ScratchLabDesktopTests/ReferenceAuthoringViewModelTests.swift`: actual 80/95 recovery, hold/gap/eligibility and export/restore regressions.
- `ScratchLabDesktopTests/ScratchNotationPanelTests.swift`: export/review frame parity uses the display derivative.
- `ScratchLabDesktopTests/LivePerformedNotationTrackerTests.swift`: finalized derivative contract with live/comparison/saved canonical ownership preserved.

Workflow records: `TASKS.md`, `DEV_LOG.md`, `AI_HANDOFF.md`, `AI_HANDOFF/next_prompt.md` and this report. The unrelated untracked `cxl_baby_target.json` is excluded.

## Verification

- Baseline regression failed as expected for all 16 omitted curves in both configurations. Focused correction/export/contracts: **12 executions PASS**.
- Full `scripts/build.sh all`: **9,510 XCTest passed; 124 optional skipped; 1,064 named Swift Testing executions passed (532 in each configuration); 123 Python tests passed**. All 118 required selectors ran twice; all 44 expected render artifacts present.
- iOS, macOS Release, macOS CXLRelease and watchOS builds **PASS**. Supervisors exited successfully, reaped children and retained no survivors.
- Full snapshot SHA256: `169a70b1299393da59336d3465d6f396541a8dc78486f5194da2b399b0567b37`. Six actual 80/95 PNG pages visually inspected; matching final hashes confirmed. Visual receipts supplement the automated summary's original NOT RUN field.
- The first full attempt stopped at two obsolete source assertions requiring direct finalized canonical display. They were corrected to require the explicit derivative while protecting live/comparison/persistence canonical ownership; four focused executions passed before the new full run. A prior initializer-placement compile failure was also corrected. Failed receipts remain preserved; neither was called a pass or followed by installation.
- After full verification, live inspection found one ambiguous legend word. Changed only “Shaded intervals” to “Grey shaded intervals” in Sample position. Reused matching full/behavior receipts; an affected signed universal Mac rebuild, package roundtrip and final live legend check **PASS**. Final delta snapshot: `31c429b202ecd3828572c430dcf6a7d171bfe985d58abe89331cbcf8f31c1db5`.

## Installed application and live check

Installed/open: `/Applications/SL Capture Motion Confidence 2026-10-18.app`.
Final executable SHA256: `ffc79deae545c99cb6e20ddf39e62fe4b26af4d7853034364fdeb54ef009a365`.
Signed Developer ID, team `2DDKGL33BU`, stable CXL identifier/permissions, arm64+x86_64. Local development candidate; not a notarized/public release. Previous applications remain intact; the initial verified candidate is preserved separately in evidence.

One labelled unapproved review copy, `ui-confidence-check-5e854a90-16ec-4f06-88ee-904ec1cd7224`, was used. Repetition 2 bounds remain **10.50–23.25 beats**, media **5.001542–14.564042 seconds**. The existing overlap with repetition 3 remains and still prevents approval; this task did not change bounds, preference or approval.

- Playback clocks advanced 6.22→10.62 seconds; screenshots show the white cursor advancing across a fixed 5.00–14.56 second viewport. Seven visible anchors retained identical position/size. Inspect paused at13.32 seconds and moved only the close-up to12.32–14.32 seconds. This is a bounded saved-review check, not a general frame-pacing or recording-load guarantee.
- Recorded travel, Movement detail and Sample position visuals inspected. Final installed legend verified; left in Recorded travel with repetition2 expanded and paused.
- Actual Save Capture ZIP: **15 artifact hashes/sizes valid**, three1600×1420 PNGs inspected, original MOV/WAV, raw sidecar, sample playback and92canonical records unchanged. ZIP SHA256: `7108987fd15cc9d7525ad7a8fb10a822d2ef4c860eeb8e392a8fe84d4d814918`.
- Save was requested and the resulting ZIP/source identity verified; acceptance of a save panel was not observed. Do not infer operator approval.
- An initial bulk accessibility observation lost a transient element. Replaced the observer with named per-element properties and completed the bounded check; no product failure or general no-jump claim.
- All60pre-existing review files, ten earlier applications, original archives/media and protected demo retained; only the new labelled review copy was added. Its bounds remained unchanged.

## Remaining limits and how to verify

Remaining `?` markers mean insufficient recorded motion; they must not be replaced with invented holds or connecting curves. No new Rane/audio test, Intel responsiveness measurement or user visual acceptance was performed. Existing Debug geometry preparation showed quadratic cost in a process sample; this repair makes no performance claim and does not broaden into that separate issue.

On the open review copy, press **Play repetition**: check the moving white line, the full9.56second view, measured blue curves through amber bands, and grey gaps where evidence is missing. Use **Inspect at playhead** for a stationary close-up. The operator should judge readability separately from software PASS.

Durable receipts, images, source identities, failures and package: `/Users/karlwatson/ScratchLab-Local-Evidence/2026-10-18/confidence-visibility`. `RESULT.json` gives the bounded outcome; `GIT-RECEIPT.json` records the subsequent authorized commit/push identity. No extra full run is needed for workflow documentation.
