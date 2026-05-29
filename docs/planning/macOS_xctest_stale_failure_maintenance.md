# macOS XCTest stale-failure maintenance

Separate maintenance task to bring the macOS test suite back to green. This is
**independent** of the Baby notation / TestFlight work and must not block it.

## Context

- Branch reference: `release/testflight-1 @ d343915` (in sync with origin).
- Builds are green: iOS Debug, macOS Debug, macOS build-for-testing, watchOS.
- The full macOS XCTest suite was run and is **red**.
- Triage of record lives in `AI_HANDOFF.md` ("Full macOS test triage —
  release/testflight-1 @ c7abf5e").
- **Not caused by PR #11 Baby notation work.** Proven: every implicated
  asset/source was last changed by commits that are ancestors of branch point
  `8cef014`; the merge commits `e0a0f7e` / `fbda84e` touched only
  `ScratchNotationSmoothPath.swift`, `ScratchNotationTeachingProfile.swift`,
  `MacBabyScratchPracticeGuideView.swift` (referenced by no test), two test
  files, and the pbxproj. The Baby notation suites
  (`ScratchNotationSmoothPathTests`, `ScratchNotationTeachingProfileTests`) pass.

## Failure summary (counts)

**Latest full no-skip run — `release/testflight-1 @ 47ff4f2`:** the suite
**completed headlessly without hanging** (no crashes, no timeouts, no restarts;
normal `xcodebuild … test`, no `-skip-testing`).

- XCTest: **1224 executed, 12 skipped, 38 failures** (12 distinct failing test
  cases; several have multiple assertion failures).
- Swift Testing: **147 tests, 7 issues**.
- `AutoCutVisualPlaybackTests.testAutoCutVisualPlaybackIsGatedToAutoCutMode`
  **failed fast in ~0.045 s** with 5 assertion failures — it does **not** hang.
  The earlier full-run "hang" was a one-off environmental / test-host stall,
  now disproven (it also completes in ~0.2 s when run in isolation).
- The 12 skipped are intentional fixture gates (`BABY_PLATTER_FIXTURE_PATH`
  unset → `BabyPlatterFixtureDecodeTests`, `NotationGrammarFixtureTests`) — not
  failures, no action.

Progress vs the first triage run (1222 / 12 / 33 XCTest, 13 Swift Testing
issues): slice 1 (`47ff4f2`) aligned the Baby reel manifest + ghost tests →
Swift Testing issues 13 → 7. XCTest failures 33 → 38 because AutoCut now runs to
a fast failure instead of stalling silently (+5 = AutoCut's 5 assertions).

## Failure groups

### Group A — Reel / coach-demo-audio asset-manifest expectations (stale)

Intentional asset changes (call-response reel, single-phrase notation) outran
the tests.

- `CaptureReliabilityPhase1CoreTests.testBabyScratchNotationJSONDecodesAndContainsNoSourceProvenance`
- `CaptureReliabilityPhase1CoreTests.testBabyScratchNotationClassifiesNonUniformStrokeSpeeds`
- `CaptureReliabilityPhase1CoreTests.testCoachDemoAudioResourceFolderShipsOnlyRuntimeWavs`
- `DemoTimingFoundationTests`: "The bundled Baby Scratch reel manifest is valid
  and matches its audio", "The bundled Baby reel derives ghosts for all three
  copy windows", and the reel-timeline suites ("PracticeReelTimeline",
  "Copy-window ghost strokes", "A Demo reel adapts to non-looping content…",
  "Demo follows the demo-audio clock…").

### Group B — Brittle source-string guard tests (stale after refactor)

Tests that read a `.swift` file's source and assert specific substrings; the
strings moved/renamed during legitimate refactors.

- `CaptureReliabilityPhase1CoreTests.testCoachPreviewSourceLoadsBundledCoachUSDZWithRealityKitDiagnosticsAndARViewFraming`
- `CaptureReliabilityPhase1CoreTests.testNotationVisualizerViewModelDrivesTimingFromAudioPlayer`
- `CaptureReliabilityPhase1CoreTests.testPracticeModeSourceExposesBabyScratchAudioMotionFeedback`
- `PracticeNotationPlaybackStatusTests.testNotationPreviewUsesSessionOwnedClock`
- `PracticeTargetNotationChartTests.testTargetNotationChartIsRenderedInPracticeModeView`
- `ScratchLabNotationAndExportTests.testScratchNotationCanvasViewBabyScratchModel`
  (canvas no longer literally contains `movementKind` / `releaseNormalPlayback`)
- `AutoCutVisualPlaybackTests.testAutoCutVisualPlaybackIsGatedToAutoCutMode`
  **(reclassified from the old "Group C / headless hang")** — it is a pure
  source-string test on `PracticeModeView.swift` with no AV / wait / async; it
  fails fast (~0.045 s), not a hang. The Auto-cut feature is intact (`case
  autoCut`, the "Auto-cut" label, `autoCutExplainer`, "Preview playing" all
  present), but the asserted literals moved on refactor: `struct
  AutoCutTargetChart`, `showPlayhead: true`, `practiceAssistMode == .autoCut`
  (now a `switch case`), `AutoCutTargetChart(notation:`, and the
  "visual preview — no audio playback yet" copy (moved into
  `CoachCopy.AssistMode.autoCutExplainer`). Its sibling
  `testAutoCutVisualPlaybackIsNotCoupledToEngineLayers` passes.
- `DemoTimingFoundationTests` lane-source / parity suites: "Scratch motion lane
  source", "Cross-platform notation parity", "LaneContent adapters",
  "User-attempt overlay scaffold", "Timing-lane wiring", "iOS practice lane uses
  the same shared renderer + geometry", "One lane renderer, its axis chosen by
  orientation".

### Group C — User-facing copy guards (stale; App-Review hygiene flag)

- `PracticeAssistModePickerTests.testAssistModePickerCopyIsPresentInPracticeModeView`
  — 5 verbatim explainer strings are absent from the codebase (reworded/moved).
- `ScratchLabNotationAndExportTests.testPracticeCopyAvoidsRealTimeCoachClaimAndQualifiesEstimates`
  — `MacAnalyzerView.swift` no longer contains `"estimated confidence"` /
  `"Est. Conf"`. **Note:** the overclaim-*add* guard (`"react in real time"`
  must be absent) did **not** fail, so this is a missing-qualifier wording issue,
  not an added overclaim. Quick owner glance for App-Review hygiene.

### Group D — Environment / headless hang — **OBSOLETE (no real hang)**

There is no headless hang. `AutoCutVisualPlaybackTests` was investigated and
**reclassified into Group B** (stale source-string) — see above. In isolation it
runs in ~0.2 s and fails fast; the full no-skip suite completes headlessly. The
original full-run freeze was a one-off environmental / test-host stall, not
caused by this test's code. This group is closed.

## Likely root causes

- **A:** `Resources/Notation/baby_scratch.json` updated to a single phrase
  (now 19 strokes / `phraseEnd ≈ 5.0687`, was expected 40 / ~42 s); the
  call-response reel added `baby_reel_callresponse.wav` + `baby_reel.json` to
  `Resources/CoachDemoAudio/` and the reel manifest moved to
  `baby_reel_callresponse.wav` / 8 segments / 75 strokes / 4 copy windows.
- **B:** Source files (PracticeModeView, ScratchMotionLane, CoachPreview,
  NotationVisualizer, ScratchNotationCanvasView) were refactored; the guarded
  literal substrings no longer match. The tests assert on source text, not
  behaviour, so they break on any rename even when behaviour is intact.
- **C:** Practice/assist copy was reworded; the qualifier strings moved.
- **D (obsolete):** No headless hang exists. The AutoCut test is a Group-B
  source-string staleness (asserted literals moved on refactor), proven to fail
  fast in ~0.045 s and to complete headlessly in the full no-skip run.

## Recommended fix order

Slice 1 (`47ff4f2`, **done**) handled the unambiguous Group A reel-manifest +
ghost tests. Group D is **closed** (no hang — reclassified to B). Remaining work:

1. **Group A — deferred decisions** (owner sign-off needed before editing):
   - `Resources/Notation/baby_scratch.json` source-of-truth: is the 19-stroke
     single phrase intended (update tests, incl. speed-variety thresholds) or a
     regression (fix the asset)?
   - CoachDemoAudio folder policy: should `baby_reel.json` (+ reel wav) ship in
     `CoachDemoAudio`, or move the json so the "no-json" guard stays?
2. **Group B — stale brittle source-string / copy tests** (largest set; includes
   the former Group C copy guards and the reclassified AutoCut test): convert to
   behavioural assertions where feasible (see below), otherwise refresh the
   literals to the current source. App-Review hygiene: confirm the
   `MacAnalyzerView` "estimated confidence" qualifier and the assist-mode
   explainer copy still exist in some form before re-pointing.

## Stale expectation updates (exact)

- `baby_scratch.json` tests: update to **19 strokes**, `phraseEnd ≈ 5.0687`,
  `stroke[2].startTime ≈ 0.557`, single-phrase timeline — or revert the JSON if
  40 strokes / ~42 s was the intended contract.
- `testCoachDemoAudioResourceFolderShipsOnlyRuntimeWavs`: add
  `baby_reel_callresponse.wav` and `baby_reel.json` to the allowed set **after**
  confirming the reel is intended to ship; if a `.json` should not live in
  `CoachDemoAudio`, that is a packaging fix instead.
- Reel-manifest tests: expect `baby_reel_callresponse.wav`, **8 segments**,
  **75 strokes**, **4 copy windows**, ghost count **75**, and the measured
  audio duration of `baby_reel_callresponse.wav` (~42.866 s).
- Group C copy guards: re-point to the current Practice/assist copy and the
  current `MacAnalyzerView` qualifier wording.

## Tests to convert from source-string → behavioural

These currently grep `.swift` source text and should assert observable
behaviour / model output instead (so refactors don't break them):

- `testScratchNotationCanvasViewBabyScratchModel` (asserts `movementKind` /
  `releaseNormalPlayback` substrings) → assert the canvas/model differentiates
  slope by movement kind and handles `releaseNormalPlayback` via the model API.
- `testPracticeModeSourceExposesBabyScratchAudioMotionFeedback`,
  `testNotationVisualizerViewModelDrivesTimingFromAudioPlayer`,
  `testNotationPreviewUsesSessionOwnedClock`,
  `testTargetNotationChartIsRenderedInPracticeModeView`,
  `testCoachPreviewSourceLoadsBundledCoachUSDZ…` → assert via view-model /
  public API state rather than source substrings.
- `testAutoCutVisualPlaybackIsGatedToAutoCutMode` → assert Auto-cut gating via
  the assist-mode enum / view-model state (and that the explainer comes from
  `CoachCopy.AssistMode.autoCutExplainer`) instead of literal struct-name and
  `==` substrings.
- `DemoTimingFoundationTests` lane-source / parity suites → assert renderer /
  geometry / lane behaviour via the shared types, not source text.
- Where a source-string guard is genuinely intended as an architectural fence
  (e.g. "no scoring/capture/live-mic in the lane"), keep it but anchor on stable
  API symbols rather than incidental comment/copy text.

## AutoCut headless-hang fix plan — **OBSOLETE**

No hang exists, so there is no hang to fix. Investigation (see Group B / D-obsolete
above) showed `AutoCutVisualPlaybackTests.testAutoCutVisualPlaybackIsGatedToAutoCutMode`
is a pure source-string test that fails fast (~0.045 s in the full run, ~0.2 s
isolated) and the full no-skip suite completes headlessly. The fix is the normal
Group-B treatment (convert to behavioural / refresh literals) — there is no AV
wait, expectation timeout, or test double to add. No `-skip-testing` exclusion is
needed for headless CI.

## Non-goals

- No product feature changes.
- No Baby notation changes (`ScratchNotationSmoothPath`,
  `ScratchNotationTeachingProfile`, `MacBabyScratchPracticeGuideView` stay as-is).
- Not a TestFlight blocker — builds are green and the app runs; this is test
  maintenance, tracked separately.
- No audio/JSON asset changes unless a Group-A decision concludes an asset was
  changed unintentionally (separate, explicitly-approved change).
- No signing / bundle ID / entitlements / Info.plist / Copy Bundle Resources
  changes.

## Verification plan

- Per-group: re-run only the touched classes with
  `xcodebuild … -only-testing:ScratchLabDesktopTests/<Class> test` and confirm
  green.
- After all groups: run the full macOS suite (`xcodebuild -scheme
  ScratchLabDesktop -configuration Debug -destination 'platform=macOS' test`)
  with **no** `-skip-testing` and confirm 0 failures (12 fixture skips remain
  expected). **Headless completion / no-hang is already confirmed** as of
  `47ff4f2` (full no-skip run finished in ~134 s; remaining target is 0
  failures).
- Keep the build gates green throughout: iOS Debug + macOS Debug + macOS
  build-for-testing + watchOS.
- Do not touch the pre-existing dirty files (deleted AppIcon 1024,
  `docs/feature-walkthrough.md`, `docs/planning/`).
