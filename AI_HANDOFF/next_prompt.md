Read `AI_HANDOFF.md` first.
Read `SOUL.md` and `PROFILE.md`.
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Current state (2026-08-11)

The target-vs-performed batch (visualization + coaching + scoring +
practice expansion) is COMMITTED locally on
`feature/notation-canonical-model-20260811` and NOT pushed. See the top
entry of `AI_HANDOFF.md` for the full slice record, verification table,
and the Phase-5 debt audit.

## Awaiting Karl's decisions

1. **Push approval** for the local commit on this branch.
2. **Category-D deletion**: `ScratchLabDesktop/Services/ScratchNotationTimeline.swift`
   has zero production consumers (only its own test file). Removing it
   needs a `project.pbxproj` diff, which requires Karl's separate manual
   approval — do NOT delete it without that approval.
3. **New canonical techniques**: every comparison surface is
   registry-driven; the only way to expand technique support is
   authoring a new evidenced `BeatPattern` into
   `ScratchNotation.canonicalBeatPatterns` (same evidence bar as
   baby_scratch — never guessed from `PatternSignature`/coach tips).

## Standing rules that still apply to the comparison surfaces

- Do **NOT** wire `ScratchMotionLane.userEvents` to a live source on
  iOS: Practice has no per-stroke capture source (camera is
  preview-only; mic analysis yields IOI scalars, not per-stroke
  alignment). `ScratchComparisonOverlay` is the prepared feed if/when a
  real capture source exists on iOS.
- Do **NOT** re-author bundled notation resources; the 76-stroke `baby`
  demo timeline is a demo performance, not the technique definition.

---

# DO NOT START Stage-D travel-lane Phase 4 (carried forward, still blocked)

Phase 4 (companion loader + non-bundled fixture) remains **blocked**.

Karl has not yet provided or commissioned a real `baby_platter.json`
fixture. See the `AI_HANDOFF.md` "Phase 4 BLOCKED" entry for the
full rationale. The Phase 3 → 3.1 → 3.2 → 3.3 chain ships end-to-end
on `origin/main`, so the producer side is fully wired. Phase 4's role
is exclusively to add a loader + tests for an externally-authored
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

## Scope clarifications (carried forward for when Phase 4 resumes)

- **Bundle membership**: NOT bundled.
- **Sample rate** (when authored): 30 Hz, matching the live producer.
- **Loader location**: `ScratchLab/Models/PlatterPositionTimelineResource.swift`
  (cross-platform module), accepting either a URL or a raw `Data`
  blob.
- **Test location**:
  `ScratchLabDesktopTests/PlatterPositionTimelineResourceTests.swift`
  (flat path, matches Phase 1/2/3 convention).

## Verification for any future app-target slice

Per `feedback_verification_scope.md`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
   succeeds (add `CODE_SIGNING_ALLOWED=NO`; Watch-target provisioning
   mismatch is pre-existing).
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
4. Full test bundle via the `xcrun xctest` dylib-symlink recipe (bundle
   lives at `ScratchLab.app/Contents/PlugIns/ScratchLabDesktopTests.xctest`);
   swift-testing suites must be all-green; XCTest bundled-resource
   failures are environmental in that mode.

`Tools/TrainModels swift test` is NOT required.
