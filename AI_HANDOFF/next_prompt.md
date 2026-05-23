Read `AI_HANDOFF.md` first.
Read `SOUL.md` and `PROFILE.md`.
Read the approved plan at `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`.
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Phase 1 — Platter-position + crossfader-ribbon models, tests only

Approved plan: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
(amendment locked: TrainModels swift test is NOT a verification gate).

## What to add

Add ONE new Swift file at:

  `ScratchLab/Models/PlatterPositionTimeline.swift`

Add ONE new XCTest file at:

  `ScratchLabDesktopTests/Models/PlatterPositionTimelineTests.swift`

## Types in the new Swift file

1. `struct PlatterPositionSample: Equatable, Sendable, Codable`
   - `let time: TimeInterval`                  // seconds, take-relative
   - `let position: Double`                    // revolutions, unbounded, signed
   - `let confidence: Double`                  // 0…1 (1.0 = direct sensor reading; < 1 = interpolated / authored / extrapolated)

2. `struct PlatterPositionTimeline: Equatable, Sendable, Codable`
   - `enum Source: String, Equatable, Sendable, Codable { case liveCapture, bundledDemo, coachAuthored }`
   - `let source: Source`
   - `let startTime: TimeInterval`
   - `let endTime: TimeInterval`
   - `let samples: [PlatterPositionSample]`
   - Failing initialiser that enforces invariants:
     - `endTime >= startTime`
     - `samples` sorted by `time`, non-decreasing
     - if `samples` non-empty: `samples.first!.time >= startTime` and `samples.last!.time <= endTime`
     - Signature: `init?(source: Source, startTime: TimeInterval, endTime: TimeInterval, samples: [PlatterPositionSample])`
   - `func position(at time: TimeInterval) -> Double?`
     - Linear interpolation between bracketing samples.
     - Returns `nil` outside `[startTime, endTime]` or for empty samples.
   - `var positionRange: ClosedRange<Double>? { get }`
     - `min…max` over `samples`. Nil when empty.

3. `struct CrossfaderStateTimeline: Equatable, Sendable`
   - ```swift
     enum State: Equatable, Sendable {
         case open
         case closed
         case transitioning(progress: Double)   // 0 = closed, 1 = open
     }
     ```
   - `struct Segment: Equatable, Sendable { let startTime, endTime: TimeInterval; let state: State }`
   - `let segments: [Segment]`
   - `let coverage: ClosedRange<TimeInterval>?`
   - `init(from events: [CaptureCore.DetectedNotationFaderEvent], coverage: ClosedRange<TimeInterval>?)`
   - `func state(at time: TimeInterval) -> State`         // `.closed` outside coverage

`CrossfaderStateTimeline` is **NOT** `Codable` — it is a derived/view type, never persisted.

## Tests required (15 cases)

In `PlatterPositionTimelineTests`:

1.  Codable round-trip on a populated `PlatterPositionTimeline`, assert equality.
2.  Invariant — initialiser rejects unsorted samples (returns `nil`).
3.  Invariant — initialiser rejects samples whose `time` falls outside `[startTime, endTime]`.
4.  Invariant — initialiser rejects `endTime < startTime`.
5.  Interpolation — `position(at: samples[i].time)` returns `samples[i].position` exactly.
6.  Interpolation — midpoint between two samples returns the linear midpoint within `1e-9`.
7.  Interpolation — returns `nil` before `startTime` and after `endTime`.
8.  Interpolation — empty samples returns `nil` for any time.
9.  `positionRange` — populated returns `min…max`.
10. `positionRange` — empty returns `nil`.
11. `CrossfaderStateTimeline.init(from:coverage:)` — builds contiguous open/closed segments from a synthetic fader-event array with no gaps, no overlaps.
12. `CrossfaderStateTimeline.state(at:)` — returns the segment's state at any interior time.
13. `CrossfaderStateTimeline.state(at:)` — returns `.closed` outside `coverage`.
14. `CrossfaderStateTimeline.state(at:)` — given a `DetectedNotationFaderEvent` with `eventKind == .pulse`, `fromValue = 0`, `toValue = 1`, returns `.transitioning(progress:)` linearly across the event span.
15. `CrossfaderStateTimeline` with empty events yields zero segments; `state(at:)` always returns `.closed`.

No UI / snapshot tests in Phase 1 — there is no renderer change to snapshot.

## Hard constraints

- Do not import or modify any of:
  - `ScratchLab/Models/CaptureCore.swift` (other than *reading* `DetectedNotationFaderEvent` as input to the crossfader initialiser)
  - `ScratchLab/Models/TimingLane.swift`
  - `ScratchLab/Models/ScratchStrokeGeometry.swift`
  - `ScratchLab/Models/ScratchMotionRenderer.swift`
  - `ScratchLab/Views/ScratchMotionLane.swift`
  - `ScratchLab/Models/PracticeReelTimeline.swift`
  - `ScratchLab/Services/SessionExportCoordinator.swift`
  - `ScratchLabDesktop/Services/HandDirectionTracker.swift`
  - `ScratchLabDesktop/Services/MacCaptureEngine.swift`
- Do not change `scratchlab_session_export_v4` or `scratchlab_detected_notation_v1` — the new types are NOT persisted.
- Do not add the new files to Copy Bundle Resources, Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID, or entitlements.
- Project file membership (locked):
  - `ScratchLab/Models/PlatterPositionTimeline.swift` — add to **both** the `ScratchLab` target **and** the `ScratchLabDesktop` target. No other targets.
  - `ScratchLabDesktopTests/Models/PlatterPositionTimelineTests.swift` — add to the `ScratchLabDesktopTests` target **only**. No other targets.
  - Per `project_demo_timing_slice.md`, pbxproj uses explicit file refs — make the additions atomic and minimal, mirroring the membership shape of an existing Models file already in both `ScratchLab` and `ScratchLabDesktop`.
- Do not stage `xcuserdata/.../xcschememanagement.plist`.
- Do not touch `reference_frames/`, `reference_videos/`, or `Tools/ScratchAudioSpike/`.
- No `Co-Authored-By` trailer on any commit (per `feedback_no_coauthor_trailer.md`).
- Do not commit. Do not push. Wait for approval.

## Verification (TrainModels swift test is NOT required)

Per `feedback_verification_scope.md`, this slice only adds app model types and desktop tests. TrainModels is unrelated and is explicitly out of the verification gate.

Required:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` — succeeds.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` — succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` — succeeds (compiles the new desktop tests alongside the app).

Nice-to-have (only if practical in-session — be aware of `project_test_runner_hang.md` if `xcodebuild test` hangs at test-host launch):

4. Run `PlatterPositionTimelineTests` cases in the desktop test plan and report pass/fail counts.

Expected `git diff --stat` outcome:

- Exactly two **new** files:
  - `ScratchLab/Models/PlatterPositionTimeline.swift`
  - `ScratchLabDesktopTests/Models/PlatterPositionTimelineTests.swift`
- One **modified** file: `ScratchLab.xcodeproj/project.pbxproj` (the file-membership additions). No other source files modified.
- `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`, `reference_videos/`, and any `Tools/ScratchAudioSpike/` contents remain **unstaged**.

Schema lock check (grep, must remain byte-stable):

- `scratchlab_session_export_v4` constant in `SessionExportCoordinator.swift:23` unchanged.
- `scratchlab_detected_notation_v1` constant in `SessionExportCoordinator.swift:379` unchanged.

## On completion

- Update `AI_HANDOFF.md` with: commit-status (uncommitted, awaiting approval), files added, build outcomes, test outcomes if run.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at the Phase 2 work (renderer fork) — or, if Phase 1 was rejected mid-flight, summarise the rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot, the `git diff --stat`, and the verification command outputs.
