Read `AI_HANDOFF.md` first.
Read `SOUL.md` and `PROFILE.md`.
Read the approved plan at `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md` (especially §7 — renderer selection logic).
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Phase 2 — Renderer fork (deferred, gated on Phase 1 commit + approval)

**Pre-flight gates that must hold before starting Phase 2:**

1. Phase 1 (`PlatterPositionTimeline.swift` +
   `PlatterPositionTimelineTests.swift`) is committed and pushed to
   `origin/main`. The 15-case test suite passes.
2. Karl has explicitly approved Phase 2 with a "go" message — not
   inferred from Phase 1 approval.
3. The render-style open decisions from the plan's §12 are answered:
   - Crossfader ribbon edge (top / bottom / inset baseline)?
   - Raw-trace stroke style (single hue + velocity width, OR
     forward/backward dual hue matching
     `ScratchMotionRenderer.Style.backwardColor`)?
   - `minimumSampleDensity` floor (Phase 1 placeholder: ~10
     samples/second).

If any gate is unmet, **stop** and surface the missing gate. Do not
start work.

## Scope (per the plan §9 Phase 2)

- `ScratchLab/Models/TimingLane.swift` — add optional
  `platterTimeline: PlatterPositionTimeline?` to `LaneContent`, **and**
  an optional slice of `[CaptureCore.DetectedNotationFaderEvent]` for
  the crossfader ribbon adapter. Both default to `nil` so every
  existing call site continues to compile and behave identically.
- `ScratchLab/Models/ScratchMotionRenderer.swift` — add a new entry
  point `drawRawTrace(_ timeline:, viewport:, style:)` that draws a
  single continuous line from the raw `(t, position)` stream,
  normalising through `positionRange` onto the lane's cross-axis 0…1.
  Pure function — no state, no side effects beyond the
  `GraphicsContext`.
- `ScratchLab/Views/ScratchMotionLane.swift` — implement the selector
  from §7:
  ```
  if let timeline = content.platterTimeline,
     timeline.samples.count >= minimumSampleDensity,
     timeline.endTime - timeline.startTime >= content.duration * 0.8 {
      ScratchMotionRenderer.drawRawTrace(timeline, viewport: viewport, style: ...)
  } else {
      ScratchMotionRenderer.draw(ScratchStrokeGeometry.motionPath(for: content),
                                 in: context, viewport: viewport, style: ...)
  }
  ```
- Materialise `CrossfaderStateTimeline` inside the lane from the
  optional fader-event slice and render the open/closed ribbon plus
  cut/pulse/flare ticks at the lane's edge.

## Hard constraints

- Existing classified-stroke render paths must remain pixel-identical
  when `platterTimeline == nil`. Lock this with snapshot tests against
  a `LaneContent` built without a raw timeline.
- Do not modify `CaptureCore.swift`, `PracticeReelTimeline.swift`,
  `SessionExportCoordinator.swift`, `HandDirectionTracker.swift`, or
  `MacCaptureEngine.swift`. Phase 2 is renderer-only.
- Do not change `scratchlab_session_export_v4` or
  `scratchlab_detected_notation_v1`. Phase 2 does not persist the new
  data — it only renders an in-memory timeline.
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
4. New snapshot tests assert pixel-identical lane output for the
   no-timeline path, and a sanity-shape assertion for the raw-trace
   path.
5. Phase 1's `PlatterPositionTimelineTests` (15 cases) still pass
   without modification.

`Tools/TrainModels swift test` is NOT required (per
`feedback_verification_scope.md`).

## On completion

- Update `AI_HANDOFF.md` with: commit status (uncommitted, awaiting
  approval), files added/modified, build outcomes, test outcomes,
  selector tuning notes.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at Phase 3 (live
  producer) — or, if Phase 2 was rejected mid-flight, summarise the
  rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
