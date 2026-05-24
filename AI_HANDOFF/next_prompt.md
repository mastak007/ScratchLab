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

# Phase 4 — Bundled fixture + companion loader (deferred, gated)

**Pre-flight gates that must hold before starting Phase 4:**

1. Phase 3.1 (`MacCaptureEngine` wiring) is committed and pushed to
   `origin/main`. The combined 48-case test suite still passes
   (16 HandDirectionTracker + 15 Phase 1 + 9 Phase 2 + 8 Phase 3).
2. Karl has explicitly approved Phase 4 with a "go" message — not
   inferred from Phase 3.1 approval.
3. The fixture-content question is resolved. Karl's 2026-05-24
   preliminary decisions captured for resumption:
   - **Bundle membership**: NOT bundled — keep as a test fixture only.
     A future slice can promote it to a bundled resource if useful.
   - **Sample rate**: 30 Hz, matching the live producer.
   - **Source of the JSON content**: Karl will hand-author or
     commission the JSON externally and drop it in; this slice adds
     only the loader + tests + scaffolding. The previous Phase 4
     prompt's "manual angle extraction at ~30 Hz from a known-good
     reference video" path is rejected because (a) I have no
     computer-vision capability, and (b) the only available reference
     material (`reference_frames/`, `reference_videos/`) is local-
     analysis-only per `AI_HANDOFF.md` history and `SOUL.md`.

If any gate is unmet, **stop** and surface the missing gate. Do not
start work.

## Scope (Phase 4, rescoped per Karl's 2026-05-24 decisions)

- Add a small companion loader near `PracticeReelTimeline` (e.g.,
  `ScratchLab/Models/PlatterPositionTimelineResource.swift`) that
  decodes a JSON file matching `PlatterPositionTimeline`'s Codable
  shape and returns a `PlatterPositionTimeline?`. The loader must
  accept either a bundle URL or a raw `Data` blob so it works in
  both bundled and test-fixture-only modes.
- Place the test fixture at a NON-bundled location (e.g.,
  `ScratchLabDesktopTests/Fixtures/baby_platter.json` or inline as a
  Swift string in the test file) so it does NOT appear in any Copy
  Bundle Resources phase. Karl will provide or commission the JSON
  content; this slice ships an empty / placeholder fixture if Karl
  hasn't dropped one in yet.
- Add fixture-decode + integrity tests at
  `ScratchLabDesktopTests/PlatterPositionTimelineResourceTests.swift`
  (flat path, matches Phase 1/2/3 convention):
  - Fixture JSON decodes without error (when present).
  - When attached to a `LaneContent` of matching duration, the
    fixture satisfies `LaneContent.shouldRenderRawTrace()`.
  - Loader gracefully returns `nil` for malformed / missing input.

## Hard constraints

- **No Copy Bundle Resources changes.** Per Karl's decision, the
  fixture is non-bundled in Phase 4. A separate future slice can
  promote it if needed.
- `scratchlab_session_export_v4` and
  `scratchlab_detected_notation_v1` must remain byte-stable.
- The fixture content must NOT carry any banned tokens (see
  `ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift`'s
  guard list — `MakeMKV`, `QBERT`, `SXRATCH`, `processed_makemkv`,
  `sourceMKV`, etc.).
- Do not modify `MacCaptureEngine.swift`,
  `PlatterPositionRecorder.swift`, `HandDirectionTracker.swift`,
  `CaptureCore.swift`, or any rendering code.
- No changes to Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
  or entitlements.
- Do not stage `xcuserdata/.../xcschememanagement.plist`,
  `reference_frames/`, or `reference_videos/`.
- No `Co-Authored-By` trailer.
- Do not commit. Do not push. Wait for approval.

## Verification

Per `feedback_verification_scope.md`:

1. `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
   succeeds. (Re-run after Xcode/CoreSimulator restart if the
   Phase 3 iOS blockage persists.)
2. `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
3. `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
   succeeds.
4. Phase 1 + Phase 2 + Phase 3 + Phase 4 tests all pass via targeted
   `-only-testing` runs.

`Tools/TrainModels swift test` is NOT required (per
`feedback_verification_scope.md`).

## On completion

- Update `AI_HANDOFF.md` with: commit status, files added/modified,
  build outcomes, test outcomes, fixture-content status (received
  from Karl, or placeholder).
- Rewrite `AI_HANDOFF/next_prompt.md` to point at the captured-user
  overlay slice (per plan §13 ordering) — or, if Phase 4 was
  rejected mid-flight, summarise the rejection reason and stop.
- Report back with the exact `git status --short --branch` snapshot,
  the `git diff --stat`, and the verification command outputs.
