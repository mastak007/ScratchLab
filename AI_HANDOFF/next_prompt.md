Read `CLAUDE.md`, then `SOUL.md` and `PROFILE.md`.
Read `AI_HANDOFF.md` — the top entry (2026-08-28) is current state; everything below it (branch `feature/v3.2-swiftui-20260815`, commit `7efbb70`) is historical and stale.
Run `git status --short --branch` and `git rev-parse HEAD origin/feature/ios-capture-camera-ux`.

## Current state (2026-08-28)

- Branch `feature/ios-capture-camera-ux`; repository baseline before this reconciliation was `baa06fc9`. Run `git rev-parse HEAD origin/feature/ios-capture-camera-ux` for the live state.
- MIDI Learn fixes (`ce12fe0e`, six tests) and Rane ONE MKII operator docs (`10f79db8`) are COMPLETE and pushed.
- 34 pre-existing modified files + 1 untracked `ScratchLabDesktopTests/CalibrationCameraOverlayTests.swift.plist` remain LOCAL and UNSTAGED — a large in-flight iOS Companion Camera / capture-UX effort plus the `RaneOneMKIIVerifiedLearnedMapping` registry / iOS coordinator wiring. `DEV_LOG.md` and `TASKS.md` also still carry unstaged pre-existing WIP entries.

## Rules

- Preserve every dirty file and hunk exactly. Do NOT clean, revert, stash, stage, or commit any pre-existing WIP without an explicit written scope.
- Do not commit or push unless explicitly approved. No `Co-Authored-By` trailer. No `project.pbxproj` edits without separate manual approval. Do not mutate Figma / Code Connect. New `.swift` files need explicit pbxproj refs.

## Product direction — RESOLVED 2026-08-29

ScratchLab remains multiplatform (macOS + iOS/iPadOS + watchOS). The 2026-08-12 "macOS-only" retirement was reversed in code by `1061dc33` (2026-08-15) and `37f81c06` (2026-08-22); `TASKS.md` / `DEV_LOG.md` / `AI_HANDOFF.md` were reconciled 2026-08-29 (docs only). No product-priority blocker remains.

`TASKS.md` still has no implementation-ready unchecked item (all `[x]` except the hardware-validation-gated capture-movement-loss closure at `TASKS.md:136`, a standing guard rule, and an optional non-Rane DVS check). The pre-existing 34-file iOS WIP is consistent with the multiplatform direction but remains unreviewed and unapproved — do not start any task against it without an explicit written per-slice scope.

## Verification gate (when work resumes, app-target slice)

iOS Debug build (`CODE_SIGNING_ALLOWED=NO`) + macOS build + macOS `build-for-testing` + `python3 scripts/test_capture_pipeline.py` (expect 47/47) + `git diff --check`.
`scripts/build.sh all` currently stops on five pre-existing dirty-WIP test failures (`testGuidedCaptureLandscapeHidesHelperTextDuringPreRoll`, `testGuidedCaptureSystemCheckScrollsOnSmallScreens`, `testLevelSelectSourceUsesSafeAreaAwareScrollableHeaderLayout`, `testPracticeSetupDoesNotRenderCoachCard`, `testRaneOneMkiiDebugPresetHasSetupNoteOtherPresetsDoNot`) — that is the current WIP baseline, not a regression.
