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

Phase 4 (companion loader + non-bundled fixture) remains **blocked**.

Karl has not yet provided or commissioned a real `baby_platter.json`
fixture. See the `AI_HANDOFF.md` "Phase 4 BLOCKED" entry for the
full rationale. The Phase 3 → 3.1 → 3.2 → 3.3 chain now ships
end-to-end on `origin/main` (once Phase 3.3 is committed), so the
producer side is fully wired and the Review UX no longer falsely
claims "no motion" when raw motion was captured. Phase 4's role is
exclusively to add a loader + tests for an externally-authored
fixture; nothing about the live capture path requires it.

## Hard "do not" list for any agent reading this

- Do **NOT** create a placeholder `baby_platter.json`.
- Do **NOT** synthesise a fixture from `baby_scratch.json` strokes,
  from `PracticeReelTimeline`, or from any other already-shipped
  material.
- Do **NOT** read, derive from, or in any way involve
  `reference_frames/` or `reference_videos/`. Those are local
  analysis artefacts, NOT permitted sources.
- Do **NOT** bundle fixture data into any Copy Bundle Resources
  phase, even "just to validate the loader path".
- Do **NOT** write the companion loader scaffolding in advance —
  the loader's shape depends on the real fixture's structure, and
  writing it speculatively risks locking in a contract that the
  real fixture won't fit.
- Do **NOT** modify the recorder, the engine wiring, the Phase 3.2
  DEBUG inspector card, the Phase 3.3 mixed-state copy, or any of
  the Phase 1 / Phase 2 / Phase 3 / Phase 3.1 code that's already
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
6. The Phase 3.3 mixed-state copy is still on `origin/main` (look
   for the most recent `Phase 3.3` commit on main).

If any item fails, **stop** and surface what's missing. Do not
start work.

## Manual smoke test still useful

Whether or not Phase 4 resumes, the most valuable verification
right now is exercising the Phase 3.3 mixed-state copy against the
exact take that prompted it:

1. Build and run `ScratchLabDesktop` on macOS.
2. Reproduce the take from the Phase 3.2 confirmation (or any take
   that produces raw motion samples + zero classified strokes).
3. Switch to the **Review** tab.
4. Inspect:
   - **Captured evidence card** (right-side stage) header: should
     read `Raw motion · no classified strokes` instead of
     `Audio-only take`.
   - **Captured evidence card** subtitle: should read `Raw platter
     motion was captured but couldn't be converted into notation.`
     and `Motion captured for diagnostics only.`
   - **Raw platter timeline (debug) card** (sidebar, DEBUG-only):
     unchanged — still shows Present / Sample count / Time range /
     Duration / Position range / Source.
   - **Sidebar decision summary / availability label**: should
     read `No classified strokes · Raw motion captured for
     diagnostics only` instead of `Audio-only take · No record
     movement detected.`
5. If the take instead has BOTH raw motion AND classified strokes
   → no copy should change; Review behaves identically to before
   Phase 3.3.
6. If the take has NO raw motion AND no classified strokes (true
   audio-only) → copy must remain `Audio-only take` / `Hand motion
   wasn't detected — review timing only.` unchanged.

## Scope clarifications (carried forward for when Phase 4 resumes)

- **Bundle membership**: NOT bundled.
- **Sample rate** (when authored): 30 Hz, matching the live producer.
- **Loader location**: `ScratchLab/Models/PlatterPositionTimelineResource.swift`
  (cross-platform module), accepting either a URL or a raw `Data`
  blob.
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

- Update `AI_HANDOFF.md` removing the Phase 4 BLOCKED top entry
  and replacing it with a `## YYYY-MM-DD — Phase 4 …` slice entry
  matching the prior phases' format.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at the captured-user
  overlay slice (per plan §13 ordering) — or, if Phase 4 was
  rejected mid-flight, summarise the rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
