Read `AI_HANDOFF.md` first.
Read `SOUL.md` and `PROFILE.md`.
Read the approved plan at `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md` (especially §9 Phase 3 — live producer).
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Phase 3 — Live producer (deferred, gated on Phase 2 commit + approval)

**Pre-flight gates that must hold before starting Phase 3:**

1. Phase 2 (renderer fork + crossfader ribbon in
   `ScratchMotionRenderer.swift`, `TimingLane.swift`,
   `ScratchMotionLane.swift`, plus
   `ScratchLabDesktopTests/LaneRawTraceFallbackTests.swift`) is
   committed and pushed to `origin/main`. The combined 24-case test
   suite passes.
2. Karl has explicitly approved Phase 3 with a "go" message — not
   inferred from Phase 2 approval.
3. The producer-side open decisions from the plan's §12 are answered:
   - Sample rate of the recorder (~30 Hz from `activeHandPoseInterval`,
     or a higher resampled rate)?
   - Buffer cap during recording (bounded ring buffer matching the
     audio envelope's 8192-frame pattern, OR unbounded with
     end-of-take drain)?
4. The Phase-2.1 ribbon-layout follow-up question is resolved (Karl
   either accepts the cross-axis-edge placement or schedules a
   layout-restructure slice).

If any gate is unmet, **stop** and surface the missing gate. Do not
start work.

## Scope (per the plan §9 Phase 3)

- Add a new `PlatterPositionRecorder` (or equivalent) at
  `ScratchLabDesktop/Services/PlatterPositionRecorder.swift` that
  consumes the same `(rawPoint, time)` samples
  `HandDirectionTracker.recordObservation(rawPoint:at:)` already
  receives. The recorder writes into an unbounded
  `[PlatterPositionSample]` buffer during recording.
- The recorder is a **sibling consumer**, not a wrapper of
  `HandDirectionTracker`. Its existence must not change the tracker's
  hysteresis behaviour, sample history capacity, or direction
  classification.
- The recorder integrates raw position deltas into unbounded
  revolutions (signed; forward positive). The tracker's existing
  `(CGPoint, CFTimeInterval)` input is the source. Confidence = 1.0
  for samples sourced directly from the tracker.
- At end-of-take, the recorder is drained into the in-memory
  `DetectedNotationSnapshot` sibling — **not** into the snapshot
  itself (the snapshot's Codable shape stays unchanged so the v4
  session export remains byte-stable). A parallel in-memory holder
  (e.g. a property on `CaptureCore.ScratchLabRuntimeDiagnostics` or a
  new `Phase3Diagnostics` namespace) carries the
  `PlatterPositionTimeline` until something downstream consumes it.
- A new test class
  `ScratchLabDesktopTests/PlatterPositionRecorderTests.swift` (flat
  path, matches Phase 1/2 convention) covers:
  - Recorder integrates a synthetic position sequence into the
    expected unbounded revolutions output.
  - Recorder buffer is drained to a valid `PlatterPositionTimeline`
    (timeline invariants from Phase 1 still hold).
  - Recorder does not modify the `HandDirectionTracker` instance it
    sits alongside (state-check before / after).

## Hard constraints

- `HandDirectionTracker` must NOT be modified. The recorder is a
  parallel consumer that observes the same upstream sample stream.
- `CaptureCore.DetectedNotationSnapshot` Codable shape must NOT be
  modified. No new fields on the snapshot itself.
- `scratchlab_session_export_v4` and
  `scratchlab_detected_notation_v1` constants must remain
  byte-stable. Phase 3 does NOT persist the raw timeline (still
  in-memory only).
- No changes to Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
  entitlements, or Copy Bundle Resources.
- Do not stage `xcuserdata/.../xcschememanagement.plist`,
  `reference_frames/`, or `reference_videos/`.
- No `Co-Authored-By` trailer.
- Do not commit. Do not push. Wait for approval.

## Verification

Per `feedback_verification_scope.md`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
   succeeds.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
4. Phase 1 + Phase 2 + Phase 3 tests all pass via targeted
   `-only-testing` runs (mind `project_test_runner_hang.md`).

`Tools/TrainModels swift test` is NOT required (per
`feedback_verification_scope.md`).

## On completion

- Update `AI_HANDOFF.md` with: commit status (uncommitted, awaiting
  approval), files added/modified, build outcomes, test outcomes,
  any new producer-side tuning notes.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at Phase 4 (bundled
  fixture + companion producer) — or, if Phase 3 was rejected
  mid-flight, summarise the rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
