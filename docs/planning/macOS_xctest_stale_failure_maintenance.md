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

- XCTest: **1222 run, 12 skipped, 33 failures** (11 distinct failing test cases;
  several have multiple assertion failures).
- Swift Testing: **147 tests, 13 issues** (~8 distinct failing tests across 7
  suites).
- **1 headless hang**: `AutoCutVisualPlaybackTests.testAutoCutVisualPlaybackIsGatedToAutoCutMode`
  (excluded via `-skip-testing` so the suite could finish).
- Distinct failing tests total: **19**, plus the 1 hang.
- The 12 skipped are intentional fixture gates (`BABY_PLATTER_FIXTURE_PATH`
  unset → `BabyPlatterFixtureDecodeTests`, `NotationGrammarFixtureTests`) — not
  failures, no action.

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

### Group D — Environment / headless hang

- `AutoCutVisualPlaybackTests.testAutoCutVisualPlaybackIsGatedToAutoCutMode`
  starts and never finishes under a headless run (needs a real AV/run-loop).

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
- **D:** Test depends on real playback infrastructure that does not complete in
  a windowserver-less / headless environment.

## Recommended fix order

1. **Group A (assets)** — highest signal, mechanical: align expectations to the
   shipped assets (or revert the asset if the change was unintended). Decide the
   `baby_reel.json` shipping question first (Group A also gates the App-Review
   hygiene check in C).
2. **Group C (copy)** — small, App-Review-relevant; confirm the qualifying copy
   still exists in some form and re-point the assertions.
3. **Group D (AutoCut hang)** — unblocks running the *whole* suite headlessly in
   CI without `-skip-testing`.
4. **Group B (source-string guards)** — largest set; convert to behavioural
   assertions where feasible (see below), otherwise refresh the literals.

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
- `DemoTimingFoundationTests` lane-source / parity suites → assert renderer /
  geometry / lane behaviour via the shared types, not source text.
- Where a source-string guard is genuinely intended as an architectural fence
  (e.g. "no scoring/capture/live-mic in the lane"), keep it but anchor on stable
  API symbols rather than incidental comment/copy text.

## AutoCut headless-hang fix plan

- Reproduce in isolation: `xcodebuild … -only-testing:ScratchLabDesktopTests/AutoCutVisualPlaybackTests test`.
- Identify the blocking wait (likely a `waitForExpectations` with no/long
  timeout or a `RunLoop.run()` awaiting AV playback that never starts headless).
- Fix options (pick the least invasive that keeps the test meaningful):
  - Add an explicit, short `XCTestExpectation` timeout so it **fails fast**
    instead of hanging.
  - Gate the playback-dependent path behind an injectable clock / test double so
    it does not require a real windowserver/AV pipeline.
  - If it genuinely cannot run headless, mark it as requiring a GUI/CI host and
    document the `-skip-testing` exclusion for headless runs.
- Goal: the full suite runs to completion headlessly without `-skip-testing`.

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
  with **no** `-skip-testing` and confirm 0 failures, 0 hangs (12 fixture skips
  remain expected).
- Keep the build gates green throughout: iOS Debug + macOS Debug + macOS
  build-for-testing + watchOS.
- Do not touch the pre-existing dirty files (deleted AppIcon 1024,
  `docs/feature-walkthrough.md`, `docs/planning/`).
