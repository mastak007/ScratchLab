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

# DO NOT START PHASE 4

Phase 4 (companion loader + non-bundled fixture) is **blocked**.

Karl has not yet provided or commissioned a real `baby_platter.json`
fixture, and the slice was explicitly paused on 2026-05-24 to wait
for one. See `AI_HANDOFF.md`'s top entry for the full rationale.

## Hard "do not" list for any agent reading this

- Do **NOT** create a placeholder `baby_platter.json`.
- Do **NOT** synthesise a fixture from the bundled
  `baby_scratch.json` strokes, from `PracticeReelTimeline`, or from
  any other already-shipped material.
- Do **NOT** read, derive from, or in any way involve
  `reference_frames/` or `reference_videos/`. Those are local
  analysis artefacts, NOT permitted sources.
- Do **NOT** bundle fixture data into any Copy Bundle Resources
  phase, even "just to validate the loader path".
- Do **NOT** write the companion loader scaffolding in advance —
  the loader's shape depends on the real fixture's structure, and
  writing it speculatively risks locking in a contract that the
  real fixture won't fit.
- Do **NOT** modify the recorder, the engine wiring, or any of the
  Phase 1 / Phase 2 / Phase 3 / Phase 3.1 code that's already
  committed on `origin/main`.

## What to do if Karl says "resume Phase 4"

Before doing any work, confirm ALL of the following hold:

1. A real, non-empty `baby_platter.json` is present in the working
   tree at a non-bundled path (e.g.,
   `ScratchLabDesktopTests/Fixtures/baby_platter.json`).
2. Karl explicitly says "go" / "start" / "resume" Phase 4.
3. The fixture's content matches the `PlatterPositionTimeline`
   Codable shape (`source`, `startTime`, `endTime`, `samples` with
   `{time, position, confidence}` per sample).
4. The fixture's filename and contents contain none of the banned
   tokens in
   `ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift`'s
   guard list (`MakeMKV`, `QBERT`, `SXRATCH`, `processed_makemkv`,
   `sourceMKV`, etc.).
5. The Phase 3.1 `MacCaptureEngine` wiring is still on
   `origin/main` (`git log --oneline | grep -q '^7e3286d'` or
   equivalent).

If any item fails, **stop** and surface what's missing. Do not
start work.

## Most useful manual smoke test available right now

Until the fixture lands, the next useful verification is end-to-end
on the wiring Phase 3.1 added (commit `7e3286d`):

1. Build and run `ScratchLabDesktop` on macOS.
2. Start a routine recording via the Mac Analyzer surface.
3. Move the tracked hand in front of the camera so
   `HandDirectionTracker.recordObservation(...)` receives non-
   trivial samples.
4. Stop the recording cleanly (so
   `fileOutput(...didFinishRecordingTo:)` fires and
   `finalizeRoutineRecording` runs).
5. Inspect `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
   (via debugger, Xcode preview, or a temporary `print`):
   - Expected: a non-nil `PlatterPositionTimeline` with
     `samples.count > 0`, `endTime > startTime`, and a
     `positionRange` that spans a non-trivial range when the hand
     actually moved.
   - If nil after a real hand movement: the wiring did not fire —
     investigate the observe call site in `processVideoSampleBuffer`
     and the `platterPositionRecorder.isRecording` gate.

That test does not need any new code from Claude. Karl runs it
manually; report findings back when the smoke test has been
exercised.

## Scope clarifications (carried forward for when Phase 4 resumes)

- **Bundle membership**: NOT bundled. The fixture lives at a
  test-only path; no Copy Bundle Resources phase touches it.
- **Sample rate** (when the fixture is authored): 30 Hz, matching
  the live producer.
- **Loader location**: `ScratchLab/Models/PlatterPositionTimelineResource.swift`
  (cross-platform module — both iOS and macOS targets), accepting
  either a URL or a raw `Data` blob.
- **Test location**:
  `ScratchLabDesktopTests/PlatterPositionTimelineResourceTests.swift`
  (flat path, matches Phase 1/2/3 convention).

## Verification (when Phase 4 eventually runs)

Per `feedback_verification_scope.md`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
   succeeds.
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
4. All prior phases' tests (Phase 1 + Phase 2 + Phase 3) still pass
   plus the new Phase 4 loader tests.

`Tools/TrainModels swift test` is NOT required.

## On completion (when Phase 4 eventually completes)

- Update `AI_HANDOFF.md` removing the "Phase 4 BLOCKED" top entry
  and replacing it with a `## 2026-05-24 — Phase 4 …` slice entry
  matching the prior phases' format.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at the captured-user
  overlay slice (per plan §13 ordering).
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
