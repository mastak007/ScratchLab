Read `AI_HANDOFF.md` first.
Read `SOUL.md` and `PROFILE.md`.
Read the approved plan at `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md` (especially §9 Phase 4 — bundled fixture + companion producer).
Do not assume memory.
Report `git status --short --branch`.
Identify any pre-existing dirty files and do not stage them.
Do not commit unless explicitly approved.
Do not push unless explicitly approved.
No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).

---

# Phase 4 — Bundled-demo producer + first fixture (deferred, gated on Phase 3 commit + approval)

**Pre-flight gates that must hold before starting Phase 4:**

1. Phase 3 (`ScratchLabDesktop/Services/PlatterPositionRecorder.swift`
   + `ScratchLabDesktopTests/PlatterPositionRecorderTests.swift`) is
   committed and pushed to `origin/main`. The combined 32-case test
   suite passes (15 Phase 1 + 9 Phase 2 + 8 Phase 3).
2. Karl has explicitly approved Phase 4 with a "go" message — not
   inferred from Phase 3 approval.
3. The fixture-side open decisions are answered:
   - Which reference video drives the fixture? (Default candidate:
     the SXRATCH reference frames already in `reference_frames/` from
     the `fluffy-yawning-sunset.md` analysis — but those are local
     analysis artefacts NOT bundled into the app.)
   - Sample rate for the authored fixture (30 Hz to match the live
     producer, or higher for a smoother reference)?
   - Bundle membership: `ScratchLab/Resources/CoachDemoMotion/baby_platter.json`
     mounted in both iOS + macOS app Resources groups, or a separate
     coach-only resource path?
4. The Phase 3 wiring follow-up — mounting `PlatterPositionRecorder`
   inside `MacCaptureEngine` so live takes actually produce a raw
   timeline — has either landed OR been explicitly deferred.

If any gate is unmet, **stop** and surface the missing gate. Do not
start work.

## Scope (per the plan §9 Phase 4)

- Author one bundled raw-platter fixture at
  `ScratchLab/Resources/CoachDemoMotion/baby_platter.json` — manual
  angle extraction at ~30 Hz from a known-good reference video. Use
  `PlatterPositionTimeline.Source.bundledDemo` (or
  `.coachAuthored` if a hand-curated subset is preferred — call this
  out in the fixture's docstring/header).
- Add a small companion loader alongside `PracticeReelTimeline` (e.g.,
  `PlatterPositionTimelineResource` or extend `PracticeReelTimeline`
  with a sibling `platterTimeline` accessor) that decodes the fixture
  and surfaces it to a future Demo-mode wiring slice.
- Add fixture-decode + integrity tests at
  `ScratchLabDesktopTests/BabyPlatterFixtureTests.swift` (flat path,
  matches Phase 1/2/3 convention):
  - Fixture JSON decodes without error.
  - Sample count ≥ `LaneContent.defaultMinimumSampleDensity` × span
    (so `shouldRenderRawTrace()` would pass when the fixture is
    attached to a LaneContent).
  - Sample positions form a non-trivial trajectory (positionRange
    span > some small epsilon — fixture has actual motion).
- Bundle the fixture in the iOS + macOS app targets via the same Copy
  Bundle Resources pattern already used for `baby_reel.json` and
  `baby_scratch.json`.

## Hard constraints

- The fixture MUST be authored from a permitted source. Per `SOUL.md`:
  "Do not use YouTube/Ortofon material for training." The fixture is
  not training data per se, but to stay clear of the banned-string
  guard (`ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift`)
  it must not carry any banned tokens in its JSON or filename.
- `scratchlab_session_export_v4` and
  `scratchlab_detected_notation_v1` must remain byte-stable. Phase 4
  does NOT persist anything new into the export; it adds a bundled
  resource only.
- The fixture is bundled but must NOT appear under model-bundling
  paths (`.mlmodel`, `.mlmodelc`, `.mlpackage`).
- No changes to Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
  or entitlements.
- Do not stage `xcuserdata/.../xcschememanagement.plist`,
  `reference_frames/`, or `reference_videos/`.
- No `Co-Authored-By` trailer.
- Do not commit. Do not push. Wait for approval.

## Verification

Per `feedback_verification_scope.md`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
   succeeds. (Re-run after CoreSimulator service recovery if
   Phase 3's iOS build blockage is still active.)
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
4. Phase 1 + Phase 2 + Phase 3 + Phase 4 tests all pass via targeted
   `-only-testing` runs.

`Tools/TrainModels swift test` is NOT required (per
`feedback_verification_scope.md`).

## On completion

- Update `AI_HANDOFF.md` with: commit status (uncommitted, awaiting
  approval), files added, build outcomes, test outcomes, fixture-
  authoring methodology notes.
- Rewrite `AI_HANDOFF/next_prompt.md` to point at the captured-user
  overlay slice (per plan §13 ordering) — or, if Phase 4 was rejected
  mid-flight, summarise the rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
