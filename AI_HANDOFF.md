# AI Handoff

## 2026-05-24 — iOS Phase 3.1 equivalent NOT NEEDED (investigation only)

Read-only investigation of whether iOS needs its own `PlatterPositionRecorder`
wiring. Recording here so future agents searching for "iOS Phase 3.1" find
the rationale without re-investigating.

- **Finding**: no iOS Phase 3.1 equivalent is needed right now.
- **Reason**: iOS does not have a local hand-tracking / Vision /
  `(rawPoint, time)` sample pipeline at all.
  - `CompanionCameraBroadcaster.captureOutput(_:didOutput:from:)`
    (line ~863 in `ScratchLab/Services/CompanionCameraBroadcaster.swift`)
    only forwards / JPEG-encodes frames for broadcast to macOS over
    MultipeerConnectivity. It does NOT run Vision and does NOT
    produce platter-position samples.
  - `PracticeModeView.CameraPreviewView`
    (`ScratchLab/Views/PracticeModeView.swift:1372`) is a bare
    `AVCaptureSession` + `AVCaptureVideoPreviewLayer` for visual
    reference only. No `AVCaptureVideoDataOutput`, no sample-buffer
    delegate, no Vision, no recorder path.
  - Zero iOS-target references to `HandDirectionTracker`,
    `VNDetectHumanHandPoseRequest`, or any of the sample-stream
    types Phase 3.1 consumes.
- **Therefore**: `PlatterPositionRecorder.observe(point:at:)` has
  nowhere safe to mount on iOS today. There is no producer to feed
  it, no recording lifecycle (`startRoutineRecording` /
  `finalizeRoutineRecording` don't exist on iOS) to bracket it
  with, and no `lastDrainedPlatterPositionTimeline` consumer to
  read it.
- **iOS debug UI implication**: a Phase 3.2-equivalent card on iOS
  would only ever show "Missing" until either (a) macOS relays raw
  timeline data back over MultipeerConnectivity, or (b) iOS gains
  its own Vision pipeline. Neither change is in scope.
- **Current recommendation: zero iOS code changes.** macOS Phase 3.1
  (commit `7e3286d`) and Phase 3.2 (commit `09a7d53`) ship as the
  full producer + DEBUG inspector surface. iOS remains a passive
  camera/audio source streaming to macOS.
- **Future options if Karl ever decides iOS needs a raw timeline**
  (NOT in scope now — each is its own planning slice):
  1. Add a full iOS Vision / hand-tracking pipeline (heavy:
     duplicates the macOS Vision loop, doubles maintenance,
     device-CPU/thermal budget needs validation).
  2. Relay macOS raw samples / timeline back to iOS via the
     existing `MCSession` (medium: new packet type, end-to-end
     latency, iOS card renders second-hand data).
  3. Promote / tune `HandDirectionTracker` for shared use across
     both targets (conceptually clean but its history + hysteresis
     are tuned for macOS capture cadence; iOS may need different
     parameters, risking Phase 1 invariants).
- **Constraints honoured by this finding**: no app code touched,
  no project file touched, no fixtures, no `reference_*`, no
  `xcschememanagement.plist`. Plan file lives at
  `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  with the full per-question breakdown.

---

## 2026-05-24 — Phase 3.1 MacCaptureEngine wiring smoke test PASSED

Real macOS capture exercised the wiring end-to-end. Recording the
result here so it survives `/clear` and future agents can find it
without re-running the smoke test.

- **What was tested**: Phase 3.1 wiring (commit `7e3286d` on
  `origin/main`) — `PlatterPositionRecorder` mounted inside
  `MacCaptureEngine`'s start / observe / drain lifecycle.
- **How**: Karl ran the macOS `ScratchLab.app` manually, started a
  routine recording via the Capture surface, moved a hand in front
  of the camera, and stopped the recording. The drain block in
  `finalizeRoutineRecording` executed and a temporary one-line
  diagnostic print (since reverted) reported the drained timeline's
  shape.
- **Result**: `finalizeRoutineRecording` reached, drain hook fired,
  `lastDrainedPlatterPositionTimeline` was **non-nil**. Exact
  numbers from the run:
  - `sampleCount` = **261**
  - `timeRange` = **0.0 … 22.69094208333263** seconds
  - `positionRange` = **−0.0806029886007309 … 0.7671469897031784**
    (unbounded signed platter-axis displacement units, per the Phase
    1 docstring on `PlatterPositionSample`)
- **Derived sanity**: ~261 samples / 22.69 s ≈ **11.5 Hz** — above
  the Phase 1 selector's 10 Hz floor with margin, consistent with
  `activeHandPoseInterval` at the active routine-recording cadence.
  The positionRange straddles zero with a non-trivial span, which
  is direct evidence the `Δx` integration produces signed motion in
  both directions (not a stuck-at-zero or one-sided integrator bug).
- **State after smoke test**:
  - Temporary diagnostic `print(...)` block has been **reverted**.
  - `MacCaptureEngine.swift` is byte-identical to `origin/main`'s
    Phase 3.1 commit (`7e3286d`).
  - **No source-code changes remain** from the diagnostic.
  - `git diff -- ScratchLabDesktop/Services/MacCaptureEngine.swift`
    is empty.
  - Remaining dirty / untracked files are only the same
    pre-existing entries from earlier sessions:
    `ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist`
    (modified-unstaged), `reference_frames/` (untracked),
    `reference_videos/` (untracked).
- **Implication for future work**:
  - The Phase 3 + Phase 3.1 producer side is **functionally
    verified** against real camera input. Future consumer slices
    (renderer overlay, fixture comparison, captured-user trace) can
    rely on `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
    being populated after every successful routine recording.
  - Phase 4 (companion loader + non-bundled fixture) remains
    blocked on Karl-provided `baby_platter.json` — see entry below.

---

## 2026-05-24 — Phase 4 BLOCKED — awaiting real `baby_platter.json` from Karl

Phase 4 (companion loader + non-bundled fixture) is **paused**. No
work — no code, no scaffolding, no placeholder JSON. Karl is the
single source of truth for the fixture content and has not yet
provided it.

- **Why blocked**: I cannot author a meaningful raw-platter fixture
  myself. I have no computer-vision capability, and the only
  available reference material in the workspace
  (`reference_frames/`, `reference_videos/`) is **off-limits for
  bundling or for derived assets** per `SOUL.md` ("Do not use
  YouTube/Ortofon material for training.") and the prior
  `AI_HANDOFF.md` entry quarantining them as local-analysis-only.
- **Karl's locked constraints**:
  - Do **NOT** use `reference_frames/` or `reference_videos/` —
    not as a source, not as a derivative, not as inspiration for a
    synthetic surrogate.
  - Do **NOT** bundle fixture data into any Copy Bundle Resources
    phase. The fixture, when it exists, lives outside the app
    bundle (e.g., `ScratchLabDesktopTests/Fixtures/baby_platter.json`
    or similar test-only path).
  - Do **NOT** create a placeholder JSON or synthesise content as a
    substitute for the real fixture. An empty / fake fixture is
    worse than no fixture because it would let tests pass on
    contentless data.
- **Unblock signal**: a real `baby_platter.json` (hand-authored or
  commissioned) appears in the working tree at a non-bundled path,
  AND Karl explicitly approves resuming Phase 4. Until then,
  `AI_HANDOFF/next_prompt.md` gates the slice as DO-NOT-START.
- **What still works after Phase 3.1**:
  - The full `PlatterPositionRecorder` → `MacCaptureEngine` wiring
    is live on `origin/main` (commit `7e3286d`). Every macOS
    routine recording produces a `PlatterPositionTimeline` and
    stashes it in `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
    (in-memory; v4 export schema unchanged).
  - No consumer reads that property yet. Phase 4's loader + tests
    would have been the first consumer-shaped slice; that's now
    deferred along with the rest of Phase 4.
- **Most useful manual smoke test available right now (no code
  changes required from Claude)**:
  1. Build and run `ScratchLabDesktop` on macOS.
  2. Start a routine recording via the Mac Analyzer surface.
  3. Move the tracked hand in front of the camera so
     `HandDirectionTracker.recordObservation(...)` receives
     non-trivial samples.
  4. Stop the recording cleanly (so `fileOutput(...didFinishRecordingTo:)`
     fires and `finalizeRoutineRecording` runs).
  5. Inspect `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
     (via debugger, Xcode preview, or a temporary `print`):
     - Expected: **non-nil** `PlatterPositionTimeline` with
       `samples.count > 0`, `endTime > startTime`,
       `positionRange` spanning a non-trivial range when the hand
       actually moved.
     - If nil after a real move: the wiring did not fire —
       investigate `processVideoSampleBuffer`'s observe call site
       or the `platterPositionRecorder.isRecording` gate.
- **Reminder to anyone reopening Phase 4**: respect the prior
  pre-flight gates in `AI_HANDOFF/next_prompt.md`. Do not start
  without (a) a real fixture file from Karl, (b) Karl's explicit
  "go" message, AND (c) acknowledgement that the
  `reference_frames/` / `reference_videos/` material remains
  off-limits.

---

## 2026-05-24 — Phase 3.1 MacCaptureEngine wiring (uncommitted, awaiting approval)

Karl's Phase 4 pre-flight pivot: Phase 4 (bundled fixture) is paused
because the slice as written required manual angle extraction from a
reference video — which I can't do (no vision) and which would also
violate `SOUL.md` (`reference_frames/` + `reference_videos/` are
local-analysis-only, not shippable). Instead we ship the Phase 3
wiring follow-up first — mounting `PlatterPositionRecorder` inside
`MacCaptureEngine` so live takes actually produce a raw timeline.

- **Slice status: uncommitted, awaiting Karl's approval.** Working
  tree has one modified file (`MacCaptureEngine.swift`). Nothing
  staged. No commit, no push.
- **Pre-flight decisions captured for future Phase 4 (when it resumes)**:
  - Fixture source: defer — when Phase 4 resumes, Karl will hand-author
    or commission the JSON externally; I add only the loader + tests.
  - Fixture bundle membership: NOT bundled — keep as a test fixture
    only until a future slice promotes it.
  - Fixture sample rate (when authored): 30 Hz matching live producer.
- **File modified** (one): `ScratchLabDesktop/Services/MacCaptureEngine.swift`
  (+52 lines). Four small additions, all in `ScratchLabDesktop` target:
  1. **Property declaration block** (next to `handDirectionTracker` at
     line ~1736): adds `platterPositionRecorder` (sibling
     `PlatterPositionRecorder` instance), `platterRecordingStartTime`
     (`CFTimeInterval` host-time anchor for the active take),
     `lastDrainedPlatterPositionTimeline` (`PlatterPositionTimeline?`,
     `private(set)` so it's readable from `@testable import` callers
     but only mutable internally), and `platterRecorderLock`
     (`NSLock` — funnels all recorder access through one lock
     because the recorder is touched by `sessionQueue` (start),
     `videoQueue` (observe), and the `AVCaptureFileOutput` delegate
     queue (drain); mirrors the existing `midiCaptureLock` pattern).
  2. **Start hook** (inside `startRoutineRecording`'s sessionQueue
     block, just before `movieOutput.startRecording(...)` at line
     ~2241): under the lock, clears `lastDrainedPlatterPositionTimeline`,
     captures `platterRecordingStartTime = CACurrentMediaTime()`,
     and calls `platterPositionRecorder.startRecording(at: 0)`.
  3. **Observe hook** (inside `processVideoSampleBuffer` immediately
     after the existing `handDirectionTracker.recordObservation(rawPoint:, at: now)`
     call at line ~3230): under the lock, if `platterPositionRecorder.isRecording`,
     computes take-relative time as `max(0, now - platterRecordingStartTime)`
     and calls `platterPositionRecorder.observe(point: rawTrackedPoint, at: ...)`.
     The `isRecording` gate is a perf optimisation — `observe(...)` is
     itself a no-op when not recording per Phase 3 design.
  4. **Drain hook** (inside `finalizeRoutineRecording` immediately
     after the existing `drainCapturedMidiCCEvents()` call at line
     ~2923): under the lock, computes `platterEndRelative = max(0, CACurrentMediaTime() - platterRecordingStartTime)`,
     calls `platterPositionRecorder.finishRecording(at: platterEndRelative)`,
     stores the result in `lastDrainedPlatterPositionTimeline`, and
     resets `platterRecordingStartTime = 0`.
- **Constraints honoured**:
  - `HandDirectionTracker` — NOT modified. The recorder runs in
    parallel; the existing tracker call at line 3230 is unchanged.
  - `PlatterPositionRecorder` (Phase 3 artefact) — NOT modified.
  - `CaptureCore.DetectedNotationSnapshot` — NOT modified. Codable
    shape unchanged; v4 export schema byte-stable.
  - `scratchlab_session_export_v4` and `scratchlab_detected_notation_v1`
    constants — verified byte-stable.
  - No Practice/scoring/coaching code touched. The wiring is purely
    capture-side instrumentation. The drained timeline lives
    in-memory on the engine and is read by no consumer today.
  - No new files added. No pbxproj edits.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID, or
    entitlements changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` preserved as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer.
- **Concurrency**: the new lock (`platterRecorderLock`) serialises
  every recorder access — start, observe, drain — across the three
  queues that touch it. Mirrors the existing `midiCaptureLock`
  pattern used for `capturedMidiCCEvents` / `midiRecordingStartTime`.
- **No dedicated wiring test** (limitation): a true wiring test would
  need an AVCaptureSession + camera permission + mocked video output —
  large test surface for low marginal value, since Phase 3 already
  proved the recorder's contract with 8 unit cases (including
  sibling-tracker non-interference). Phase 3.1 ships the call-site
  additions only; verification is via macOS build + the full Phase 3
  test suite still passing + manual smoke-testing on a live capture
  session when Karl exercises it.
- **Builds run**:
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → NOT re-run this slice. The Phase 3 commit's iOS blockage
    (CoreSimulator service stuck) likely persists; in any case the
    wiring change is in `ScratchLabDesktop/Services/MacCaptureEngine.swift`
    which is macOS-target-only, so iOS behaviour is unchanged.
- **Tests run** (Phase 1 + Phase 2 + Phase 3 + HandDirectionTracker):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS' -only-testing:<four classes>`
    → **TEST EXECUTE SUCCEEDED**. **48 / 48 passed**, 0 failures.
    (16 HandDirectionTracker + 15 Phase 1 + 9 Phase 2 + 8 Phase 3.)
    Including the existing `HandDirectionTrackerTests` re-run is the
    runtime-level evidence that the wiring did not perturb tracker
    behaviour, complementing Phase 3's unit-level non-interference
    assertion.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLabDesktop/Services/MacCaptureEngine.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 3.1 scope only — plist is pre-existing dirty):
  ```
  ScratchLabDesktop/Services/MacCaptureEngine.swift | 52 ++++++++++++++++++++++
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 3.1: wire PlatterPositionRecorder into MacCaptureEngine lifecycle`.
  2. Approve `next_prompt.md` rewrite pointing at Phase 4 (bundled
     fixture), now that the wiring follow-up is resolved?

---

## 2026-05-24 — Phase 3 live producer (uncommitted, awaiting approval)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has 2 new files + 3 modified files (incl. pbxproj). Nothing staged.
  No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (Phase 3 section). Karl's 2026-05-24 pre-flight decisions:
  - Ribbon layout (Phase 2.1/2.2): **settled** — proceed.
  - Sample rate: **tracker-native** (~30 Hz active / ~4 Hz idle).
  - Buffer strategy: **unbounded with end-of-take drain**.
  - Position unit: **raw integrated platter-axis units** (NOT
    revolutions). Phase 1 docstring relaxed to remove the "revolutions"
    claim — exact wording per Karl: *"Unbounded signed platter-axis
    displacement units, produced by integrating normalized tracker
    deltas. Not calibrated to revolutions yet; calibration is deferred
    to a future slice."*
- **Files added** (2 new, untracked at slice end):
  - `ScratchLabDesktop/Services/PlatterPositionRecorder.swift` —
    sibling consumer of `(rawPoint, time)` tracker samples. API:
    `init(source:)`, `startRecording(at:)`, `observe(point:at:)`,
    `finishRecording(at:) -> PlatterPositionTimeline?`,
    `isRecording: Bool`, `sampleCount: Int`. Integration: each
    `observe` accumulates `Δx = point.x - lastPoint.x` into a signed
    running position; the first sample of a recording lands at
    `position = 0`. Confidence = 1.0 for every sample (direct sensor
    reading). Buffer is unbounded; drained + cleared on `finishRecording`.
    Sample times clamped into `[startTime, +∞)` so the Phase 1
    `samples.first.time >= startTime` invariant always holds. End time
    widened on drain if the last sample overshoots the requested
    `endTime` (keeps `samples.last.time <= endTime` invariant).
    Reference type. Single-threaded usage assumed (Phase 3 ships the
    isolated recorder; future wiring slice will mount it inside
    `MacCaptureEngine`).
  - `ScratchLabDesktopTests/PlatterPositionRecorderTests.swift` — 8
    XCTest cases:
    1. Fresh recorder: `!isRecording`, zero samples, drain returns nil.
    2. Integration produces signed running sum from a 4-sample
       deterministic input.
    3. Drained timeline satisfies Phase 1 invariants (sorted samples,
       in-range times, source label preserved).
    4. `finishRecording` widens `endTime` when the last sample
       overshoots the requested value.
    5. State resets between consecutive recordings (running integration
       cleared, new recording starts at position 0).
    6. `observe(...)` outside an active recording is silently ignored.
    7. Empty recording (start without observe) drains to nil.
    8. **Sibling `HandDirectionTracker` non-interference**: a tracker
       running alongside the recorder produces the EXACT same Direction
       sequence as a tracker running alone with the same input. This
       is the strongest single test of "recorder does not modify the
       tracker".
- **Files modified** (3):
  - `ScratchLab/Models/PlatterPositionTimeline.swift` — Phase 1
    docstring on `PlatterPositionSample` relaxed per Karl's wording.
    Inline `positionRange` docstring also updated ("platter-axis
    displacement units" instead of "revolutions"). No API change; no
    Codable shape change.
  - `ScratchLab/Models/ScratchMotionRenderer.swift` — one docstring
    line on the raw-trace velocity-to-thickness mapping updated to
    say "platter-axis displacement units / second" instead of
    "revolutions/second". No code change.
  - `ScratchLab.xcodeproj/project.pbxproj` (+8 lines) — file refs +
    build files for both new files + group entries. UUID prefix `PPR`.
    `PlatterPositionRecorder.swift` mounted in the
    `ScratchLabDesktop/Services` group (next to `HandDirectionTracker.swift`)
    and the ScratchLabDesktop target's Sources phase only.
    `PlatterPositionRecorderTests.swift` mounted in the flat
    `ScratchLabDesktopTests` group + Sources phase (matches Phase 1/2
    convention).
- **Constraints honoured**:
  - `HandDirectionTracker` — NOT modified. The recorder is an
    independent class; test #8 proves non-interference behaviourally.
  - `CaptureCore.DetectedNotationSnapshot` — NOT modified. Codable
    shape unchanged.
  - `scratchlab_session_export_v4` (line 23) — byte-stable, verified.
  - `scratchlab_detected_notation_v1` (line 379) — byte-stable, verified.
  - `MacCaptureEngine` — NOT modified. The recorder is shipped in
    isolation; future wiring slice will mount it in the capture engine.
  - No `.mlmodel` / `.mlmodelc` / `.mlpackage` / resource / Info.plist /
    PrivacyInfo / signing / Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` preserved as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer.
- **Builds run**:
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BLOCKED** by a system-side CoreSimulator service issue that
    surfaced mid-slice ("CoreSimulator is out of date. Current version
    (1051.50.0) is older than build version (1051.54.0). Simulator
    device support disabled."). `xcrun simctl list devices booted`
    still shows the iPhone 17 simulator alive, but `xcodebuild
    -showdestinations` can't see it — xcodebuild's connection to the
    CoreSimulator service is stuck. Recovery typically requires either
    an Xcode restart or `sudo killall -9
    com.apple.CoreSimulator.CoreSimulatorService`, neither of which
    I performed without explicit permission. **Phase 3 only touches
    the ScratchLabDesktop target — no iOS code was modified — so iOS
    behaviour is unchanged by this slice.** Re-run the iOS build
    after Xcode restart to confirm.
- **Tests run** (Phase 1 + Phase 2 + Phase 3 targeted run):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests
    -only-testing:ScratchLabDesktopTests/LaneRawTraceFallbackTests
    -only-testing:ScratchLabDesktopTests/PlatterPositionRecorderTests`
    → **TEST EXECUTE SUCCEEDED**. **32 / 32 passed**, 0 failures, 0
    unexpected. (15 Phase 1 + 9 Phase 2 + 8 Phase 3.) Total ~0.027 s.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLab/Models/PlatterPositionTimeline.swift
   M ScratchLab/Models/ScratchMotionRenderer.swift
  ?? ScratchLabDesktop/Services/PlatterPositionRecorder.swift
  ?? ScratchLabDesktopTests/PlatterPositionRecorderTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 3 scope — plist is pre-existing dirty, new
  files are untracked until staged):
  ```
  ScratchLab.xcodeproj/project.pbxproj             | 8 +
  ScratchLab/Models/PlatterPositionTimeline.swift  | 18 +++++++++-------
  ScratchLab/Models/ScratchMotionRenderer.swift    | 3 ++-
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 3: PlatterPositionRecorder live producer (unwired, tests-only)`.
  2. Accept macOS-only verification given the system-side iOS build
     blockage, or do you want me to attempt a CoreSimulator service
     restart (requires sudo) before commit?
  3. Approve `next_prompt.md` rewrite pointing at Phase 4 (bundled
     fixture + companion producer)?

---

## 2026-05-24 — Phase 2.2 ribbon time-alignment tune (still uncommitted)

Karl's follow-up decision after reviewing 2.1: in portrait the
85%-from-the-left ribbon NOW position was visually awkward (past
dominated the strip). Tune the **ribbon strip viewport only** — the
motion canvas's `actionLineFraction(for:)` stays untouched.

- **Single edit** in `ScratchLab/Views/ScratchMotionLane.swift`:
  - New private helper `ribbonActionLineFraction(for axis:)`:
    - Portrait (`.vertical`) → returns `0.5` (centered NOW on the
      horizontal strip).
    - Landscape (`.horizontal`) → returns
      `actionLineFraction(for: axis)` (i.e., `0.18` — matches the
      motion's action line for direct vertical alignment).
  - `ribbonStrip(width:now:)`'s `LaneViewport` now uses
    `ribbonActionLineFraction(for: axis)` instead of
    `actionLineFraction(for: axis)`.
  - Docstrings on both helpers updated to reflect the Phase 2.2
    decision.
- **No changes to**: the motion canvas's `actionLineFraction(for:)`,
  the renderer (`ScratchMotionRenderer.swift`), capture pipeline,
  export schema (`scratchlab_session_export_v4`,
  `scratchlab_detected_notation_v1` both byte-stable), resources, or
  the test file.
- **No-events fallback unchanged**: the new helper is only consulted
  by `ribbonStrip(width:now:)`, which is only mounted when
  `content.faderEvents` is non-empty. The no-events VStack still
  collapses to a single full-height motion canvas — visually
  identical to pre-Phase-2.
- **Builds re-run** after the 2.2 tune:
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests re-run** (Phase 1 + Phase 2, 24-case targeted):
  - **24 / 24 passed**, 0 failures, total 0.011 s.

---

## 2026-05-24 — Phase 2.1 ribbon layout restructure (still uncommitted)

Karl rejected the Phase-2 portrait side-ribbon placement during review.
This 2.1 pass restructures the lane so the ribbon sits **visually below
the motion canvas in both orientations** before commit.

- **Change shape (delta from the pre-2.1 Phase-2 working tree)**:
  - `ScratchLab/Views/ScratchMotionLane.swift` — `body` is now a
    `VStack(spacing: 0)` of `laneContent(motionViewport)` on top and a
    dedicated `ribbonStrip(width:now:)` Canvas below. The ribbon strip
    height is a new `ribbonStripHeight: CGFloat = 14` constant. The
    ribbon strip is only added when `content.faderEvents` is non-empty,
    so the no-events path collapses the VStack back to a single
    full-height motion canvas. The ribbon's viewport is
    `axis: .horizontal` with the SAME `actionLineFraction` and
    `secondsAhead` as the motion canvas — visible time window aligned
    with motion. The old in-lane `drawCrossfaderLayer(in:viewport:)`
    method and its call inside the motion Canvas closure are deleted.
  - `ScratchLab/Models/ScratchMotionRenderer.swift` — `ribbonCrossRange`
    now returns `(0, viewport.crossLength)` so the renderer fills the
    full cross extent of whatever viewport it is given (the dedicated
    strip canvas). The `thickness` parameter is kept on the signature
    for source compatibility but is no longer consulted. Updated
    docstring explains the Phase-2.1 rationale.
- **No changes to**: `LaneContent` model fields, the selector predicate
  (`shouldRenderRawTrace(...)`), `drawRawTrace`, fader-event capture,
  schema constants, resources, or the test file's assertions.
- **Time-alignment note for portrait**: the ribbon strip uses the
  motion's `actionLineFraction = 0.85`, so the ribbon's NOW position is
  at x = 85% from the left of the strip — past dominates the strip
  width. This keeps the ribbon's visible-time window exactly matched
  to the motion's; the quirk is that a portrait motion's time axis is
  vertical while the ribbon below it is horizontal, so the NOW indicators
  don't visually intersect (they're orthogonal). The ribbon is read as
  a separate horizontal timeline that shares the motion's visible time
  window. In landscape this works cleanly because both axes are already
  horizontal (NOW at x = 18% from leading edge in both).
- **No pixel-diff snapshot tests** (unchanged from Phase 2 limitation —
  no image-comparison library in the repo).
- **Attempted visual proof**:
  - First attempt: added three `ImageRenderer`-based visual-proof tests
    to `LaneRawTraceFallbackTests` (portrait-with-ribbon,
    landscape-with-ribbon, portrait-no-ribbon → PNG to
    `/tmp/scratchlab_phase21/`). Compilation failed because
    `ScratchMotionLane` is iOS-only (`Views/` group is not in the
    macOS test target's compilation unit, per
    `project_demo_timing_slice.md`). Reverted the tests.
  - Second attempt: built `ScratchLab.app` for the booted iPhone 17
    simulator (id `53B855D2-2933-4A9C-BB75-1AC5D866701E`),
    `simctl install` + `simctl launch`, captured launch screenshot at
    `/tmp/scratchlab_phase21_main.png`. The screenshot proves the app
    builds, installs, and launches cleanly. It does NOT demonstrate the
    new ribbon because the visible main-menu surface (`MainMenuView`)
    does not host `ScratchMotionLane`, and even reaching Practice →
    Baby → Auto-cut would render the no-events fallback (no fader
    events on any shipping call path).
- **Honest visual-proof gap**: producing a feature-demo screenshot
  showing the new ribbon strip below the motion canvas would require
  either:
  - A new iOS XCTest bundle (new pbxproj target — out of scope for a
    polish pass), or
  - Temporary debug-only synthetic fader-event injection in a Practice
    surface (touches Practice/coaching code — out of scope per SOUL.md
    "Do not change Practice/scoring/coaching unless explicitly asked"),
    or
  - An iOS SwiftUI Preview added to `ScratchMotionLane.swift` with
    sample fader events (renderable in Xcode's canvas only —
    cannot be captured non-interactively).
  Pick any of those and I can produce a real visual; until then, the
  ribbon-below-motion claim rests on the code structure (VStack split
  with the ribbon as the second child, only added when events present),
  the inline docstrings, and the existing 9 Phase-2 selector +
  structural tests passing.
- **Builds run** after the 2.1 restructure:
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'platform=iOS Simulator,id=...'`
    → **BUILD SUCCEEDED** (used for simulator install).
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run**: same 24-case suite as Phase 2 (15 Phase 1 + 9 Phase 2)
  → **24 / 24 passed**, 0 failures, total 0.016 s.

---

## 2026-05-24 — Raw platter-position timeline Phase 2 (renderer fork + crossfader ribbon)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has the slice's one new test file + four modified files. Nothing
  staged. No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (Phase 2 section). Three render-style decisions locked at the start
  of the slice: ribbon edge = bottom/trailing; trace style = single hue
  + velocity-modulated thickness; density floor = 10 samples/sec.
- **Files added** (one new, untracked at slice end):
  - `ScratchLabDesktopTests/LaneRawTraceFallbackTests.swift` — 9 XCTest
    cases: 2 back-compat invariants (`LaneContent(notation:)` and
    `LaneContent(reel:)` both produce nil `platterTimeline` + empty
    `faderEvents`), 5 selector predicate cases (no-timeline,
    dense+covers-80%, sparse, low-coverage, tunable floor), 2
    structural smoke tests (drawRawTrace + drawCrossfaderRibbon/Ticks
    via `ImageRenderer`).
- **Files modified** (four):
  - `ScratchLab/Models/TimingLane.swift` (+78 lines) — `LaneContent`
    gains two optional fields: `platterTimeline: PlatterPositionTimeline?`
    (default nil) and `faderEvents: [CaptureCore.DetectedNotationFaderEvent]`
    (default []). Custom designated init with defaults preserves both
    existing extension initialisers (`init(reel:)`, `init(notation:)`)
    byte-identically. New extension method
    `shouldRenderRawTrace(minimumSampleDensity: Double = 10.0)` gates
    the renderer's substrate selection — requires timeline non-nil,
    positive span, density ≥ floor, duration > 0, and span ≥
    `duration * 0.8` (the 80% coverage threshold lives in
    `minimumRawTraceCoverageFraction`).
  - `ScratchLab/Models/ScratchMotionRenderer.swift` (+192 lines) —
    `Style` gains `crossfaderRibbonColor` (default
    `.white.opacity(0.18)`) and `crossfaderTickColor` (default
    `.white.opacity(0.65)`). Three new pure static functions added;
    existing `draw(_:in:viewport:style:)` is unchanged.
    - `drawRawTrace(_:in:viewport:style:)` — single-hue polyline with
      `sqrt(|dp/dt| * 3.0)` thickness curve clamped to
      `[0.5, 1.8] * style.lineWidth`. Restricts to visible samples plus
      one lead-in / lead-out for edge continuity. Normalises through
      `timeline.positionRange` onto cross-axis 0…1.
    - `drawCrossfaderRibbon(_:in:viewport:style:)` — fills `.closed`
      segments with `style.crossfaderRibbonColor`. `.open` segments are
      transparent. `.transitioning(progress: target)` segments fill at
      opacity `(1 - target)` so a closing ramp fades in / an opening
      ramp fades out.
    - `drawCrossfaderTicks(_:in:viewport:style:)` — draws short
      perpendicular ticks at every `.cut`, `.pulse`, `.transformPulse`,
      and `.flareClick` event time.
    - `ribbonCrossRange(viewport:thickness:)` is a private helper that
      places both ribbon and ticks at the larger-cross-coordinate edge
      of the lane (visual BOTTOM in landscape; visual RIGHT in
      portrait — see "Ribbon edge convention deviation" below).
  - `ScratchLab/Views/ScratchMotionLane.swift` (+65 lines) — `init`
    now derives a `CrossfaderStateTimeline` from `content.faderEvents`
    alongside the existing `motionPath`. `drawMotionPath(in:viewport:)`
    branches at the top: if `content.shouldRenderRawTrace()` passes,
    calls `ScratchMotionRenderer.drawRawTrace(...)` and returns; else
    falls back to the existing tiled `MotionPath` rendering loop —
    pixel-identical when both new fields are nil/empty. New
    `drawCrossfaderLayer(in:viewport:)` is added to the Canvas closure
    between `drawMotionPath` and `drawUserEvents`; it returns early
    when `content.faderEvents.isEmpty`, so the no-events path is
    visually identical to pre-Phase-2.
  - `ScratchLab.xcodeproj/project.pbxproj` (+4 lines) — one new file
    ref + one new build file + group + Sources phase entry, all using
    prefix `LRT` (mirrors the Phase 1 `PPT` pattern).
- **Ribbon edge convention deviation flagged**: the locked Phase 2
  decision was "bottom / trailing edge", with an ASCII preview that
  showed the ribbon as a HORIZONTAL strip below the motion area in
  BOTH portrait and landscape. My implementation places the ribbon at
  the larger-cross-coordinate edge — which is the visual BOTTOM in
  landscape (correct, matches preview), but the visual RIGHT side in
  portrait (NOT the bottom that the ASCII showed). Reason: a true
  visual-bottom strip in portrait would require restructuring
  `ScratchMotionLane`'s layout into a VStack (motion canvas + ribbon
  canvas), which is a separate scope from "renderer-only Phase 2". The
  current implementation sits cleanly inside the existing 12%
  cross-axis margin (`crossInsetFraction = 0.12`) and never competes
  with the motion trace. If Karl prefers the visual-bottom-in-portrait
  variant, that's a layout-restructure follow-up (Phase 2.1). The
  inline doc on `ribbonCrossRange` documents this explicitly.
- **Constraints honoured**:
  - No edits to `CaptureCore.swift`, `PracticeReelTimeline.swift`,
    `SessionExportCoordinator.swift`, `HandDirectionTracker.swift`, or
    `MacCaptureEngine.swift`. The renderer *reads*
    `CaptureCore.DetectedNotationFaderEvent` as input (a Codable nested
    struct in the `CaptureCore` enum namespace) but does not modify it.
  - `scratchlab_session_export_v4` constant
    (`SessionExportCoordinator.swift:23`) — byte-stable, unchanged.
  - `scratchlab_detected_notation_v1` constant
    (`SessionExportCoordinator.swift:379`) — byte-stable, unchanged.
  - No `.mlmodel`, `.mlmodelc`, `.mlpackage` touched.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
    entitlements, or Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` left as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).
- **Builds run** (per `feedback_verification_scope.md`):
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**. (First attempt failed on the test file —
    `ScratchNotation.loadBabyScratchFromBundle()` returns optional,
    and SwiftUI `ImageRenderer` is main-actor-isolated. Fixed with
    `try XCTUnwrap(...)` + `@MainActor` on the test class. Second
    attempt clean.)
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run** (Phase 1 + Phase 2 classes, targeted to avoid
  `project_test_runner_hang.md`):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests
    -only-testing:ScratchLabDesktopTests/LaneRawTraceFallbackTests`
    → **TEST EXECUTE SUCCEEDED**. **24 / 24 passed**, 0 failures, 0
    unexpected. (15 Phase 1 + 9 Phase 2.) Total runtime 0.011 s.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLab/Models/ScratchMotionRenderer.swift
   M ScratchLab/Models/TimingLane.swift
   M ScratchLab/Views/ScratchMotionLane.swift
  ?? ScratchLabDesktopTests/LaneRawTraceFallbackTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 2 scope only — plist is pre-existing dirty,
  new file is untracked until staged):
  ```
  ScratchLab.xcodeproj/project.pbxproj           |   4 +
  ScratchLab/Models/ScratchMotionRenderer.swift  | 192 +++++++++++++++++++++
  ScratchLab/Models/TimingLane.swift             |  78 +++++++++
  ScratchLab/Views/ScratchMotionLane.swift       |  65 ++++++-
  ```
- **Limitation surfaced — no pixel snapshot tests.** SwiftUI
  `GraphicsContext` is opaque to XCTest; a true pixel-diff snapshot
  test would need an image-comparison library (none in the repo). The
  pixel-identical guarantee for the no-timeline fallback is therefore
  argued from code structure (the `drawMotionPath` branch routes
  through the identical `ScratchMotionRenderer.draw(motionPath:...)`
  call as pre-Phase-2 when both new fields are defaulted) rather than
  proven by image diff. The two structural smoke tests assert the new
  renderer entry points produce a non-nil rendered CGImage via
  `ImageRenderer`, but do not validate pixel content.
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 2: raw-trace renderer fork + crossfader ribbon (no producer yet)`.
  2. Approve the cross-axis-edge ribbon placement, or request the
     Phase 2.1 layout restructure for a true visual-bottom ribbon in
     portrait?
  3. Approve `next_prompt.md` rewrite pointing at Phase 3 (live
     producer)?

## 2026-05-24 — Raw platter-position timeline Phase 1 (models + tests)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has the slice's two new files + a pbxproj membership edit. Nothing
  staged. No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (approved, with the verification amendment that excludes
  `Tools/TrainModels` swift test from the gate). The Phase 1 coding
  prompt lives at `AI_HANDOFF/next_prompt.md` (committed in `2a5ba2f`,
  pushed to `origin/main`).
- **Files added** (two new, both untracked at slice end):
  - `ScratchLab/Models/PlatterPositionTimeline.swift` — defines
    `PlatterPositionSample` (Codable), `PlatterPositionTimeline`
    (Codable, with failing init enforcing sort + range invariants,
    linear interpolation, `positionRange`), and `CrossfaderStateTimeline`
    (NOT Codable — derived view over
    `CaptureCore.DetectedNotationFaderEvent[]`, lerping
    `.transitioning(progress:)` across event spans).
  - `ScratchLabDesktopTests/PlatterPositionTimelineTests.swift` — 15
    XCTest cases per the prompt: Codable round-trip, 3 invariant
    rejections, 4 interpolation cases, 2 `positionRange` cases, 5
    `CrossfaderStateTimeline` cases.
- **Files modified** (one): `ScratchLab.xcodeproj/project.pbxproj` —
  10 new entries mirroring the `TimingLane.swift` / `ScratchStrokeGeometry.swift`
  shape:
  - File ref `PPT0000000PPT001PPT00001` for the Swift file (+ ref
    `PPT0010000PPT001PPT00001` for the test file).
  - Build files for ScratchLab (iOS, suffix `00002`), ScratchLabDesktop
    (macOS, suffix `00001`), and the test build file
    (`PPT0011000PPT001PPT00001`) for ScratchLabDesktopTests.
  - Group entries: Models group (line 560) for the Swift file;
    ScratchLabDesktopTests group (line 423) for the test file.
  - Sources phase entries for all three targets at the expected line
    positions (901 / 978 / 1059).
- **Convention deviation flagged**: the prompt specified the test path
  as `ScratchLabDesktopTests/Models/PlatterPositionTimelineTests.swift`,
  but the existing `ScratchLabDesktopTests/` directory is FLAT (no
  `Models/` subgroup; 11 sibling test files live at the target root).
  Honoured the flat convention to keep the pbxproj edit minimal — the
  file ships at `ScratchLabDesktopTests/PlatterPositionTimelineTests.swift`.
  If Karl prefers a nested `Models/` subgroup, a follow-up slice can
  add it with a new PBXGroup entry; today the path is consistent with
  every other test file in the target.
- **Constraints honoured**:
  - No edits to `CaptureCore.swift`, `TimingLane.swift`,
    `ScratchStrokeGeometry.swift`, `ScratchMotionRenderer.swift`,
    `ScratchMotionLane.swift`, `PracticeReelTimeline.swift`,
    `SessionExportCoordinator.swift`, `HandDirectionTracker.swift`, or
    `MacCaptureEngine.swift`. The new file *reads*
    `CaptureCore.DetectedNotationFaderEvent` (a nested Codable struct
    on the `CaptureCore` enum namespace) but does not modify it.
  - `scratchlab_session_export_v4` constant
    (`SessionExportCoordinator.swift:23`) — byte-stable, verified.
  - `scratchlab_detected_notation_v1` constant
    (`SessionExportCoordinator.swift:379`) — byte-stable, verified.
  - No `.mlmodel`, `.mlmodelc`, `.mlpackage` touched.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
    entitlements, or Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` left as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).
- **Builds run** (per `feedback_verification_scope.md` —
  `Tools/TrainModels swift test` is explicitly NOT in the verification
  gate for app-target-only slices):
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run** (nice-to-have, narrowed to the new class to avoid the
  `project_test_runner_hang.md` test-host hang risk):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests`
    → **TEST EXECUTE SUCCEEDED**. 15 / 15 passed, 0 failures, 0
    unexpected. Total runtime 0.009 s (pure value-type tests).
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
  ?? ScratchLab/Models/PlatterPositionTimeline.swift
  ?? ScratchLabDesktopTests/PlatterPositionTimelineTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (only the pbxproj diff is in scope — the new files
  are untracked until staged; the plist is pre-existing dirty):
  ```
  ScratchLab.xcodeproj/project.pbxproj | 10 ++++++++++
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 1: PlatterPositionTimeline + CrossfaderStateTimeline models, tests only`.
  2. Approve the flat test-file location, or move to a new
     `ScratchLabDesktopTests/Models/` subgroup?
  3. Approve `next_prompt.md` rewrite pointing at Phase 2 (renderer
     fork)?

## 2026-05-24 — 2D Coach quarantine + integrated-trace decision

- **`cb33837` pushed to `origin/main`** (`Quarantine the 2D Coach Rig from the
  iOS Try-Demo surface`). Single-file change in
  `ScratchLab/Views/MainMenuView.swift`. iOS Simulator build and macOS
  ScratchLabDesktop build both passed before push.
- **iOS "Try Demo" 2D Coach is quarantined.** The `coachCard` mount was
  removed from `DemoModeView`'s VStack. The `coachCard` computed property,
  `ScratchCoachCardTheme`, `demoControlButton`, `ScratchCoachCardContent`,
  and the shared `ScratchCoachRigView` all remain defined — no coach code
  was deleted. `PracticeModeView` already did not mount the 2D card
  (test-enforced); macOS `MacAnalyzerView` untouched.
- **Geometry / integrated-trace work was intentionally stopped.**
  The SXRATCH-style continuous-trace fix in `ScratchStrokeGeometry` was
  scoped, simulated against `ScratchLab/Resources/CoachDemoAudio/baby_reel.json`,
  and **not applied**. The bundled reel stores classified directional cuts,
  not raw platter-angle samples — naive integration drifts strongly negative
  (Demo 1: 7 backwards vs 3 forwards, net Δ = −1.37; full reel net Δ = −1.94,
  range entirely below the lead-in rest). Symmetric normalize collapses Baby
  Scratch into the lower half of the lane; asymmetric normalize turns it
  into a downward staircase. Karl's call: stop, don't tune blindly. Revisit
  when raw platter-angle capture data exists. Plan file
  (`/Users/karlwatson/.claude/plans/fluffy-yawning-sunset.md`) captures the
  full analysis and three deferred options (A: sticks-only; B: spring-back
  holds; C: integrate with synthetic recovery).
- **`reference_frames/` and `reference_videos/` are local analysis
  artifacts.** They live untracked in the working tree at the repo root.
  They are the extracted SXRATCH-visualizer frames used to diagnose the
  notation-lane vs continuous-trace gap. **Do not commit them unless
  explicitly requested** — they are not bundled, not training data, and
  not user-facing assets.
- **Pre-existing dirty files preserved.** `xcuserdata/.../xcschememanagement.plist`
  remains modified-but-unstaged. Per session policy it stays out of every
  commit on this branch.

## Current task

Slice U - export / ASC safety audit for beta readiness (audit-only).

## Branch / worktree

`/Users/karlwatson/Downloads/ScratchLab-merged-check` - detached HEAD at PR #2 merge.

## Base commit

`26553fe Merge pull request #2 from mastak007/claude/slice-o-onset-diagnostics`

## Goal

Report whether the merged tree is safe to ship for beta along three axes:
1. Review audio onset preview is display-only (no leakage into snapshot / scoring / export).
2. No model or sensitive-resource leakage in the repo or app bundle.
3. User-facing copy contains no overclaiming ML language or banned brand strings.

No fixes implemented - Slice U is audit-only by spec.

## Files changed

None. Audit-only slice. Working tree is clean.

## What changed

Nothing in the codebase. Findings only:

### Audit 1 - Review onset preview safety (clean)

- `ScratchLab/ML/ReviewAudioOnsetPreview.swift:248` carries an explicit user-facing footer disclaimer: `"Diagnostics-only preview. Not part of saved or exported notation."`
- `ScratchLab/Models/CaptureCore.swift:104,112` declare `audioOnsetReviewSummary` and `audioOnsetReviewMarks` as `@Published private(set)` on the runtime diagnostics object. They are populated only by `recordAudioSamplesForOnsetDiagnostics` (lines 158-177) and read only by `ScratchLabDesktop/Views/MacAnalyzerView.swift:1459,1494` for display.
- `ScratchLab/Models/CaptureCore.swift:4702-4762` define `DetectedNotationSnapshot`; its fields are `recordMovementEvents`, `audioEvents`, `faderEvents`, `mixerMidiEvents`. None of them are populated from `audioOnsetReviewMarks` / `audioOnsetReviewSummary` / `ReviewAudioOnsetPreview` (confirmed via repo-wide grep).
- `ScratchLab/Services/SessionExportCoordinator.swift` contains zero references to `audioOnsetReview*`, `ReviewAudioOnsetPreview`, `ReviewAudioOnsetMarksBuilder`, `ReviewAudioOnsetSource`, `reviewMarks`, `timing_marks`, `onsetPreview`, `preview_marks`, or `review_preview`. Export schema version `scratchlab_session_export_v4` is unchanged.
- Captured `DetectedNotationSnapshot.audioEvents` remain the source of truth; preview only re-summarises them via `ReviewAudioOnsetMarksBuilder.summarizeTakeEvents` (`ReviewAudioOnsetPreview.swift:393-429`).
- Source label: `ReviewAudioOnsetPreview.swift:299-308` maps `.selectedTakeSavedEvents` -> `"selected take audio"`. The old wording `"selected take saved audio events"` does not appear anywhere user-facing (verified via grep - remaining occurrences are in code comments and test docstrings only).

### Audit 2 - Model / resource leakage (clean)

- No `.mlmodel`, `.mlmodelc`, `.mlpackage` files anywhere under the repo.
- No `.jsonl` cache files; no `action_windows*` or `action_features_cache*` directories.
- `ScratchLab.xcodeproj/project.pbxproj` contains zero `.mlmodel*` references, no `TASKS.md` / `DEV_LOG.md` / `SOUL.md` / `PROFILE.md` / `AI_HANDOFF*` membership.
- `ScratchLab/Resources/` and `ScratchLabDesktop/Resources/` contain only: Coach USDZ rigs, CoachInstructions JSON, CoachDemoMotion JSON, CoachDemoAudio WAV (`baby_noBeat.wav`, `chirpflare_noBeat.wav`), `Notation/baby_scratch.json`, `reference_beginner/*.wav`, `reference_champ/*.wav`, `reference_pro/*.wav`. No banned strings in bundled JSON (grep negative for `youtube|ortofon|makemkv|sourceMKV|QBERT|SXRATCH|/Users/`).
- The only shipped Swift mention of `/Users/`, `MakeMKV`, `QBERT`, `SXRATCH`, `processed_makemkv`, `sourceMKV` is the banned-token guard list in `ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift:13-23`. These are guard tokens compared against incoming metadata, never surfaced.
- `TASKS.md` and `DEV_LOG.md` reference paths under `/Users/karlwatson/Movies/CXL DATASET/processed_makemkv/...` but are repo-root docs, NOT bundle-membership files. They cannot ship in the app.

### Audit 3 - ASC / user-facing wording

- No occurrences of `machine learning`, `neural network`, `deep learning`, `detects exactly`, `real-time AI` in shipped Swift (`ScratchLab/`, `ScratchLabDesktop/`, excluding `*Tests*`).
- No user-facing occurrences of `YouTube`, `Ortofon`, `QBERT`, `SXRATCH`. `QBERT` / `SXRATCH` exist only in the banned-token guard list and in tests as negative-fixture inputs.
- `CXL` appears only as a Swift type-name prefix (`CXLDirection`, `CXLTimingClassification`, `CXLNotationCaptureRecorder`, `captureEngine.cxlIsRecording`, etc.) - no `Text(...)` / `Label(...)` / `navigationTitle` / alert with a literal `"CXL"` user string found.
- WARNING `ScratchLab/Views/AIBattleModeView.swift:25,29` ships user-facing `Text("AI BATTLE")` and `Text("Challenge an AI opponent")`. `ScratchLab/Models/GameState.swift:12` ships `case aiChallenge = "AI Challenge"`. These are a scripted game opponent (rookie/flash/cipher/nova/legend scripted characters, no ML inference), but the literal word "AI" can attract App Store / ASC review scrutiny under current AI-disclosure expectations.

## Findings grouped by severity

### Blocker

None.

### Should fix before beta

- **`AIBattleModeView.swift:25,29` + `GameState.swift:12`** - user-facing "AI BATTLE" / "Challenge an AI opponent" / "AI Challenge" copy. The feature is a scripted opponent, not ML, but ASC has been tightening copy review around any "AI" usage. Recommended: rename user-visible strings to neutral wording like `BATTLE`, `Rival Challenge`, or `Opponent Challenge`. The internal enum case (`aiChallenge`) and type names (`AICharacter`) can stay because they are not user-visible. Per PROFILE.md, "avoid `AI detects exactly`, `real-time AI coach`, `deep learning` in user-facing copy" - this is adjacent to that guidance and prudent to clear before TestFlight.

### Nice to fix

- `Tools/ScratchNotation/README.md` and `docs/training_dataset_plan.md` document the banned-string list verbatim. These docs do not ship, but if any future change adds them to the bundle they would carry the strings inline. Consider replacing the literal banned-string examples with `<redacted>` placeholders the next time those docs are touched.
- `TASKS.md` and `DEV_LOG.md` contain absolute paths under `/Users/karlwatson/Movies/CXL DATASET/...`. They are not bundled today (verified against `project.pbxproj`), but if anyone ever adds them to a target's resources by mistake they would leak. A `.bundle-exclude` test that asserts these docs are NOT in any Copy Bundle Resources phase would prevent regression. The existing `ScratchAnalyzerReferenceFoldersTests`, `LeakScanTests`, and `CaptureReliabilityPhase1Tests` cover scratch-type metadata and CoachInstructions resources, but I did not find a dedicated test asserting `TASKS.md` / `DEV_LOG.md` / `AI_HANDOFF*` are not in any bundle phase.

### Clean

- Review audio onset preview is genuinely display-only and never written into the snapshot, scoring, or export. Footer disclaimer `"Diagnostics-only preview. Not part of saved or exported notation."` is shown in the card.
- Source label reads `"selected take audio"` for the selected take, `"live diagnostics"` for live, `"no take audio available"` for unavailable.
- Export schema unchanged: `scratchlab_session_export_v4`.
- No Core ML artifacts in the repo or Xcode project.
- No JSONL caches, no action_windows folders.
- No YouTube / Ortofon / QBERT / SXRATCH user-facing strings.

## Tests / builds run

- `cd Tools/TrainModels && swift test` - **200 tests passed, 0 failures** (including ReviewAudioOnsetPreviewTests, ReviewAudioOnsetMarksBuilderTests, ReviewAudioOnsetSourceResolverTests, NotationCandidateDiagnosticsTests, sound trainer + ML library suites).
- `xcodebuild -scheme ScratchLabDesktop -destination 'platform=macOS' build` - **BUILD SUCCEEDED**.
- `xcodebuild -scheme ScratchLab -destination 'generic/platform=iOS' build` - **BUILD SUCCEEDED**.

## Tests / builds still needed

- Full `ScratchLabDesktop` XCTest plan (`./scripts/build.sh`) was not re-run in this slice - Slice U is audit-only and the executors already pre-merge ran the full suite per PR #2 history. Re-run on demand if any text-rename fix is later attempted.

## Git status

```
## HEAD (no branch)
```

Working tree clean. No staged or unstaged changes.

## Risks / warnings

- The "AI Battle" copy is the only audit finding that warrants action before TestFlight. It is small and local (3 string literals across 2 files) but renaming will likely cascade into screenshots and feature copy on the ASC listing.
- The dirty checkout at `/Users/karlwatson/Downloads/ScratchLab` was NOT touched - confirmed by working only in `ScratchLab-merged-check`.

## Exact decision needed from ChatGPT

1. Approve or veto the "AI Battle" copy rename as a small Slice U.1 follow-up?
2. Approve or veto adding a Copy Bundle Resources negative-assertion test (`TASKS.md` / `DEV_LOG.md` / `AI_HANDOFF*` must never appear in any target's resources)?

## Karl approval

Approved by Karl:
1. Proceed with Slice U.1 to rename user-facing "AI Battle" / "AI Challenge" copy to neutral wording.
2. Proceed with Slice U.2 to add the audit-only Copy Bundle Resources negative-assertion test.
3. Treat U.1 and U.2 as separate follow-up slices if practical.
4. Do not commit or push.

## Slice U approval summary (audit-only, this slice made no changes)

This sub-section restates the scope, impact, risks, and constraints attached to
Karl's approvals for Slices U.1 and U.2. No code, test, project, resource, or
export changes were made in the current Slice U pass - this is an audit-and-
documentation update only. Slices U.1 and U.2 remain future, separately gated
work and MUST NOT be started in this slice.

### (a) Slice U.1 - "AI BATTLE" / "AI Challenge" user-facing copy neutralization (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Approval covers user-facing string literals only.
- **Scope of impact (in-scope for U.1, NOT touched here)**:
  - `ScratchLab/Views/AIBattleModeView.swift:25` - `Text("AI BATTLE")`
  - `ScratchLab/Views/AIBattleModeView.swift:29` - `Text("Challenge an AI opponent")`
  - `ScratchLab/Models/GameState.swift:12` - `case aiChallenge = "AI Challenge"`
    (only the **raw String value** is user-visible; the enum case name
    `aiChallenge` is internal and stays).
  - Any additional adjacent user-visible literal containing the standalone
    token " AI " surfaced during the rename pass.
- **Out-of-scope for U.1**: internal Swift identifiers (`AICharacter`,
  `aiChallenge` enum case name, `AIBattleModeView` type name), file names,
  scripted-opponent logic, scoring, Practice/coaching, export schema,
  Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID, entitlements, Copy
  Bundle Resources, model bundling, model training.
- **Why neutralize**: the feature is a scripted opponent (rookie / flash /
  cipher / nova / legend characters with no ML inference). Per PROFILE.md,
  user-facing copy should avoid AI-overclaim language (`AI detects exactly`,
  `real-time AI coach`, `deep learning`). The literal "AI BATTLE" /
  "AI Challenge" wording is adjacent to that guidance and can attract App
  Store / ASC review scrutiny under current AI-disclosure expectations.
- **Risks of the rename (when Slice U.1 is later executed, not now)**:
  - ASC listing screenshots and marketing copy that already reference
    "AI Battle" / "AI Challenge" will need to be updated in lockstep, or
    they will diverge from in-app wording.
  - The `GameState.aiChallenge` enum's raw String value is a serialization
    surface - any persisted state (UserDefaults, snapshots, saved sessions,
    JSON exports) keyed by that raw value would break if the raw value is
    changed without a migration. U.1 must verify the raw value is NOT
    persisted, or must add a migration; this verification is itself part of
    U.1's pre-rename audit and is **not** done in this slice.
  - Any analytics / logging / test fixtures referencing the literal strings
    "AI BATTLE", "Challenge an AI opponent", or "AI Challenge" will need
    matching updates.
- **Risk mitigations to bake into U.1 when it runs**: keep the diff small
  and local; verify the raw enum value is not a persistence key before
  changing it; add a regression test asserting no user-visible " AI " token
  remains in shipped Swift; do not modify any scoring / Practice / coaching
  / export / Info.plist / PrivacyInfo / signing / Copy Bundle Resources
  surface.

### (b) Slice U.2 - Audit-only Copy Bundle Resources negative-assertion test (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Test is audit-only - it inspects `project.pbxproj`, it does not
  modify the project, the bundle, or any resource.
- **Files / patterns the test will check (in-scope for U.2, NOT executed here)**:
  - `TASKS.md`
  - `DEV_LOG.md`
  - `AI_HANDOFF.md`
  - `AI_HANDOFF/` (entire directory and any file under it, e.g.
    `AI_HANDOFF/next_prompt.md`, `AI_HANDOFF/LOOP_README.md`,
    `AI_HANDOFF/claude_once_output.md`, `AI_HANDOFF/gpt_review.md`,
    `AI_HANDOFF/next_claude_prompt.md`, `AI_HANDOFF/review_status.txt`)
  - `SOUL.md`
  - `PROFILE.md`
  - `docs/training_dataset_plan.md`
  - `Tools/ScratchNotation/README.md` (also documents banned-string list
    verbatim per Audit 2 findings; candidate for the same negative
    assertion).
- **Test coverage shape**: a new XCTest case in `ScratchLabDesktopTests`
  (or the closest existing equivalent target) that parses
  `ScratchLab.xcodeproj/project.pbxproj`, walks every
  `PBXResourcesBuildPhase` in every target, and fails if any of the
  forbidden file references above appear inside any Copy Bundle Resources
  phase. The test must be read-only against the project file. It
  complements existing `ScratchAnalyzerReferenceFoldersTests`,
  `LeakScanTests`, and `CaptureReliabilityPhase1Tests`, which cover
  scratch-type metadata and CoachInstructions resources but do NOT
  currently assert that handoff / planning docs are kept out of bundle
  phases.
- **Why this matters**: `TASKS.md` and `DEV_LOG.md` contain absolute paths
  under `/Users/karlwatson/Movies/CXL DATASET/processed_makemkv/...`.
  `Tools/ScratchNotation/README.md` and `docs/training_dataset_plan.md`
  document the banned-string list verbatim. None of these ship today
  (verified against `project.pbxproj` in this audit), but a future
  accidental "Add Files to Target" action would silently leak them.
- **Risks of adding the test (when Slice U.2 is later executed, not now)**:
  - Brittle parsing - naive substring matching against `project.pbxproj`
    could false-positive on path fragments. The test must scope matches to
    full file references inside `PBXResourcesBuildPhase` blocks for the
    shipping app targets only, not script-phase or test-target references.
  - If any of these files have **already** been mistakenly added to a Copy
    Bundle Resources phase, the test will fail on first run. That failure
    is the point, but it must be triaged as "remove the resource membership"
    and **never** as "weaken the test".

### (c) Slice U is audit-only - bundle / project / export surfaces are off-limits

- No changes to the app bundle, `ScratchLab.xcodeproj/project.pbxproj`,
  Copy Bundle Resources phases, Info.plist, PrivacyInfo.xcprivacy, signing,
  bundle ID, entitlements, or export schema (`scratchlab_session_export_v4`
  remains unchanged) are permitted in Slice U.
- Any such change requires an explicitly approved future slice (e.g. U.1
  for the copy rename, U.2 for the project-file inspection test) and must
  carry its own approval from Karl before execution.
- Slice U.2's test is itself read-only against the project file - even
  when U.2 ships, it does not mutate any bundle resource.

### (d) No changes were made in this Slice U pass

- No source files modified.
- No tests added or modified.
- No `ScratchLab.xcodeproj/project.pbxproj` changes.
- No resource additions, removals, renames, or membership changes.
- No export-schema, Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
  or entitlements changes.
- No commits, no pushes, no tags.
- The only change made in this slice is documentation: this approval
  summary was appended to `AI_HANDOFF.md`.

### (e) Constraints still active and remaining risks

- All constraints listed below in "Constraints still active" remain in
  force for Slice U and continue to apply to U.1 and U.2 except where
  U.1 or U.2 explicitly scopes a narrowly-defined exception (U.1: rename
  user-facing strings only; U.2: add a read-only XCTest case only).
- Remaining risks not yet retired by this slice:
  - The "AI BATTLE" / "AI Challenge" copy still ships in the audited tree
    and remains an ASC review risk until U.1 lands.
  - There is still no automated guard that handoff / planning / dataset
    docs cannot be added to a Copy Bundle Resources phase; regression risk
    remains until U.2 lands.
  - `Tools/ScratchNotation/README.md` and `docs/training_dataset_plan.md`
    still contain the banned-string list verbatim; safe today because they
    do not ship, but they would become a leak if ever added to bundle
    resources (this is exactly what U.2's test is intended to catch).
  - The dirty checkout at `/Users/karlwatson/Downloads/ScratchLab` was not
    touched and is not part of this audit. Any work there is out of scope.

## Next recommended command

If the rename is approved:

```
Slice U.1: Rename user-facing "AI" copy in ScratchLab/Views/AIBattleModeView.swift
and ScratchLab/Models/GameState.swift to neutral wording (e.g. "BATTLE",
"Rival Challenge"). Keep internal enum/type names (AICharacter, aiChallenge
case) unchanged. Add a ScratchLabDesktopTests assertion that the user-facing
copy does not contain " AI " as a standalone token. Do not change export
schema, scoring, or Practice/coaching.
```

If a bundle-membership guard is approved:

```
Slice U.2: Add an XCTest case in ScratchLabDesktopTests that scans
ScratchLab.xcodeproj/project.pbxproj for forbidden file references in any
PBXResourcesBuildPhase: TASKS.md, DEV_LOG.md, AI_HANDOFF.md, AI_HANDOFF/,
SOUL.md, PROFILE.md, docs/training_dataset_plan.md. Fail if any are found
inside a Copy Bundle Resources phase. Audit-only - do not modify the project.
```

## Constraints still active

- No model training.
- No model bundling.
- No export-schema changes.
- No scoring changes.
- No Practice/coaching changes.
- No signing / bundle ID / entitlements / Info.plist / PrivacyInfo.xcprivacy / Copy Bundle Resources changes.
- Do not touch the dirty checkout at `/Users/karlwatson/Downloads/ScratchLab`.
- Do not commit. Do not push.
- No `Co-Authored-By` trailers.

