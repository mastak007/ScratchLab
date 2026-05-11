# AI Handoff

## Current task

Slice U — export / ASC safety audit for beta readiness (audit-only).

## Branch / worktree

`/Users/karlwatson/Downloads/ScratchLab-merged-check` — detached HEAD at PR #2 merge.

## Base commit

`26553fe Merge pull request #2 from mastak007/claude/slice-o-onset-diagnostics`

## Goal

Report whether the merged tree is safe to ship for beta along three axes:
1. Review audio onset preview is display-only (no leakage into snapshot / scoring / export).
2. No model or sensitive-resource leakage in the repo or app bundle.
3. User-facing copy contains no overclaiming ML language or banned brand strings.

No fixes implemented — Slice U is audit-only by spec.

## Files changed

None. Audit-only slice. Working tree is clean.

## What changed

Nothing in the codebase. Findings only:

### Audit 1 — Review onset preview safety (clean)

- `ScratchLab/ML/ReviewAudioOnsetPreview.swift:248` carries an explicit user-facing footer disclaimer: `"Diagnostics-only preview. Not part of saved or exported notation."`
- `ScratchLab/Models/CaptureCore.swift:104,112` declare `audioOnsetReviewSummary` and `audioOnsetReviewMarks` as `@Published private(set)` on the runtime diagnostics object. They are populated only by `recordAudioSamplesForOnsetDiagnostics` (lines 158–177) and read only by `ScratchLabDesktop/Views/MacAnalyzerView.swift:1459,1494` for display.
- `ScratchLab/Models/CaptureCore.swift:4702–4762` define `DetectedNotationSnapshot`; its fields are `recordMovementEvents`, `audioEvents`, `faderEvents`, `mixerMidiEvents`. None of them are populated from `audioOnsetReviewMarks` / `audioOnsetReviewSummary` / `ReviewAudioOnsetPreview` (confirmed via repo-wide grep).
- `ScratchLab/Services/SessionExportCoordinator.swift` contains zero references to `audioOnsetReview*`, `ReviewAudioOnsetPreview`, `ReviewAudioOnsetMarksBuilder`, `ReviewAudioOnsetSource`, `reviewMarks`, `timing_marks`, `onsetPreview`, `preview_marks`, or `review_preview`. Export schema version `scratchlab_session_export_v4` is unchanged.
- Captured `DetectedNotationSnapshot.audioEvents` remain the source of truth; preview only re-summarises them via `ReviewAudioOnsetMarksBuilder.summarizeTakeEvents` (`ReviewAudioOnsetPreview.swift:393–429`).
- Source label: `ReviewAudioOnsetPreview.swift:299–308` maps `.selectedTakeSavedEvents` → `"selected take audio"`. The old wording `"selected take saved audio events"` does not appear anywhere user-facing (verified via grep — remaining occurrences are in code comments and test docstrings only).

### Audit 2 — Model / resource leakage (clean)

- No `.mlmodel`, `.mlmodelc`, `.mlpackage` files anywhere under the repo.
- No `.jsonl` cache files; no `action_windows*` or `action_features_cache*` directories.
- `ScratchLab.xcodeproj/project.pbxproj` contains zero `.mlmodel*` references, no `TASKS.md` / `DEV_LOG.md` / `SOUL.md` / `PROFILE.md` / `AI_HANDOFF*` membership.
- `ScratchLab/Resources/` and `ScratchLabDesktop/Resources/` contain only: Coach USDZ rigs, CoachInstructions JSON, CoachDemoMotion JSON, CoachDemoAudio WAV (`baby_noBeat.wav`, `chirpflare_noBeat.wav`), `Notation/baby_scratch.json`, `reference_beginner/*.wav`, `reference_champ/*.wav`, `reference_pro/*.wav`. No banned strings in bundled JSON (grep negative for `youtube|ortofon|makemkv|sourceMKV|QBERT|SXRATCH|/Users/`).
- The only shipped Swift mention of `/Users/`, `MakeMKV`, `QBERT`, `SXRATCH`, `processed_makemkv`, `sourceMKV` is the banned-token guard list in `ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift:13–23`. These are guard tokens compared against incoming metadata, never surfaced.
- `TASKS.md` and `DEV_LOG.md` reference paths under `/Users/karlwatson/Movies/CXL DATASET/processed_makemkv/...` but are repo-root docs, NOT bundle-membership files. They cannot ship in the app.

### Audit 3 — ASC / user-facing wording

- No occurrences of `machine learning`, `neural network`, `deep learning`, `detects exactly`, `real-time AI` in shipped Swift (`ScratchLab/`, `ScratchLabDesktop/`, excluding `*Tests*`).
- No user-facing occurrences of `YouTube`, `Ortofon`, `QBERT`, `SXRATCH`. `QBERT` / `SXRATCH` exist only in the banned-token guard list and in tests as negative-fixture inputs.
- `CXL` appears only as a Swift type-name prefix (`CXLDirection`, `CXLTimingClassification`, `CXLNotationCaptureRecorder`, `captureEngine.cxlIsRecording`, etc.) — no `Text(...)` / `Label(...)` / `navigationTitle` / alert with a literal `"CXL"` user string found.
- ⚠ `ScratchLab/Views/AIBattleModeView.swift:25,29` ships user-facing `Text("AI BATTLE")` and `Text("Challenge an AI opponent")`. `ScratchLab/Models/GameState.swift:12` ships `case aiChallenge = "AI Challenge"`. These are a scripted game opponent (rookie/flash/cipher/nova/legend scripted characters, no ML inference), but the literal word "AI" can attract App Store / ASC review scrutiny under current AI-disclosure expectations.

## Findings grouped by severity

### Blocker

None.

### Should fix before beta

- **`AIBattleModeView.swift:25,29` + `GameState.swift:12`** — user-facing "AI BATTLE" / "Challenge an AI opponent" / "AI Challenge" copy. The feature is a scripted opponent, not ML, but ASC has been tightening copy review around any "AI" usage. Recommended: rename user-visible strings to neutral wording like `BATTLE`, `Rival Challenge`, or `Opponent Challenge`. The internal enum case (`aiChallenge`) and type names (`AICharacter`) can stay because they are not user-visible. Per PROFILE.md, "avoid `AI detects exactly`, `real-time AI coach`, `deep learning` in user-facing copy" — this is adjacent to that guidance and prudent to clear before TestFlight.

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

- `cd Tools/TrainModels && swift test` — **200 tests passed, 0 failures** (including ReviewAudioOnsetPreviewTests, ReviewAudioOnsetMarksBuilderTests, ReviewAudioOnsetSourceResolverTests, NotationCandidateDiagnosticsTests, sound trainer + ML library suites).
- `xcodebuild -scheme ScratchLabDesktop -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- `xcodebuild -scheme ScratchLab -destination 'generic/platform=iOS' build` — **BUILD SUCCEEDED**.

## Tests / builds still needed

- Full `ScratchLabDesktop` XCTest plan (`./scripts/build.sh`) was not re-run in this slice — Slice U is audit-only and the executors already pre-merge ran the full suite per PR #2 history. Re-run on demand if any text-rename fix is later attempted.

## Git status

```
## HEAD (no branch)
```

Working tree clean. No staged or unstaged changes.

## Risks / warnings

- The "AI Battle" copy is the only audit finding that warrants action before TestFlight. It is small and local (3 string literals across 2 files) but renaming will likely cascade into screenshots and feature copy on the ASC listing.
- The dirty checkout at `/Users/karlwatson/Downloads/ScratchLab` was NOT touched — confirmed by working only in `ScratchLab-merged-check`.

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
export changes were made in the current Slice U pass — this is an audit-and-
documentation update only. Slices U.1 and U.2 remain future, separately gated
work and MUST NOT be started in this slice.

### (a) Slice U.1 — "AI BATTLE" / "AI Challenge" user-facing copy neutralization (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Approval covers user-facing string literals only.
- **Scope of impact (in-scope for U.1, NOT touched here)**:
  - `ScratchLab/Views/AIBattleModeView.swift:25` — `Text("AI BATTLE")`
  - `ScratchLab/Views/AIBattleModeView.swift:29` — `Text("Challenge an AI opponent")`
  - `ScratchLab/Models/GameState.swift:12` — `case aiChallenge = "AI Challenge"`
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
    surface — any persisted state (UserDefaults, snapshots, saved sessions,
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

### (b) Slice U.2 — Audit-only Copy Bundle Resources negative-assertion test (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Test is audit-only — it inspects `project.pbxproj`, it does not
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
  - Brittle parsing — naive substring matching against `project.pbxproj`
    could false-positive on path fragments. The test must scope matches to
    full file references inside `PBXResourcesBuildPhase` blocks for the
    shipping app targets only, not script-phase or test-target references.
  - If any of these files have **already** been mistakenly added to a Copy
    Bundle Resources phase, the test will fail on first run. That failure
    is the point, but it must be triaged as "remove the resource membership"
    and **never** as "weaken the test".

### (c) Slice U is audit-only — bundle / project / export surfaces are off-limits

- No changes to the app bundle, `ScratchLab.xcodeproj/project.pbxproj`,
  Copy Bundle Resources phases, Info.plist, PrivacyInfo.xcprivacy, signing,
  bundle ID, entitlements, or export schema (`scratchlab_session_export_v4`
  remains unchanged) are permitted in Slice U.
- Any such change requires an explicitly approved future slice (e.g. U.1
  for the copy rename, U.2 for the project-file inspection test) and must
  carry its own approval from Karl before execution.
- Slice U.2's test is itself read-only against the project file — even
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
inside a Copy Bundle Resources phase. Audit-only — do not modify the project.
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

