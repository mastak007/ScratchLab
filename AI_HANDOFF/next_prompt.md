# Current continuation — Read-only restored-camera-start candidate review

This section supersedes earlier continuation instructions below. No hardware acceptance or commit is authorized.

```text
Read-only candidate review only. Do not edit, stage, commit, merge, push, rebuild, rerun tests, launch an interactive app, terminate/relaunch PID 35367, change cameras, record, calibrate, export, approve, install, publish or train.

Candidate: /Users/karlwatson/Downloads/ScratchLab-TTM-CameraRestore
Branch: fix/reference-authoring-restored-camera-start
Exact unchanged HEAD/base: ae4d1ca9ab81f1e43f92259e1b40f65fd6e38e8d
Canonical source: /Users/karlwatson/Downloads/ScratchLab-TTM-Reconstruct (must remain clean and unchanged)
Protected live process: PID 35367, /private/tmp/scratchlab-hardware-20260907d/Products/Debug/ScratchLab.app/Contents/MacOS/ScratchLab
Evidence: /private/tmp/scratchlab-camera-restore-20260907a/

Read AGENTS.md, SOUL.md, PROFILE.md and the current workflow records. Verify the base, branch, empty index, zero untracked files, exact seven-file candidate and ancestry through Prompt A cb4adc5, Prompt B 9bb82d1, Prompt C ae4d1ca and camera repair 63e2898. Inspect the complete diff against that base and final-source-sha256.json/candidate.diff/final-review-receipt.json.

Review the ReferenceAuthoringView task-to-activateCaptureInput-to-MacCaptureEngine.start boundary. Confirm direct entry and restored view activation request startup independently of liveInputEnabled, the existing per-engine synchronous isRunning guard owns idempotency, new view instances share it, fresh engines get their own request, and no route-owned stop was added. Confirm the DEBUG seam is nil in normal use and substitutes external startup work only after the real guard. Confirm saved-camera handling, permissions, discovery, authoritative session ownership and queued PreviewAttachment generation/stale/teardown behavior remain unchanged. No recording, MIDI, calibration, Watch, export, approval, publication, training or live-notation change is allowed.

Review eight deterministic route tests and all 25 camera-preview regressions: 33 discovered/passed per configuration, 66 total executions, zero failed/skipped/runtime warnings in test.xcresult/test-summary.json. Inspect prepare-command.json, test-command.json, compile-command.json and identity-verified.json; host ID is com.machelpnz.scratchlab.camerarestore.20260907a.ScratchLabDesktop, test bundle ID is the same prefix ending ScratchLabDesktopTests. Host signature proves App Sandbox; tests run inside that host. Container absence was proven before execution. All products/caches/results use explicit isolated paths. macOS Debug compile passed; iOS, Watch, Release and full scripts/build.sh gates were intentionally not run. The initial test compile error and sandboxed signature-verification failure were corrected/resolved before tests; retained initial evidence is not passing evidence.

Review before.json, after.json and after-comparison.json for zero additions/removals/changes in production, hardware container/output, protected preview evidence and shared products, and unchanged canonical/all other existing worktrees. Inspect final-review-receipt.json for eleven unchanged protected configuration files, empty index, zero untracked files and diff-check success. Report exact findings and limitations; do not claim hardware camera-restoration acceptance. Return approve-for-separately-authorized-checkpoint-review or request-changes, with concrete file/line evidence. This review authorizes no checkpoint or hardware action.

Remaining Phase 1 hardware checks are separately authorized work: a fresh isolated candidate, five route entry/exit cycles including navigation during camera configuration/start/stop, safe camera-device change, resizing, window close/reopen, and saved-camera restoration with liveInputEnabled false after normal quit/relaunch. On a beachball, stop interaction and obtain three ten-second samples from the verified PID before any separately authorized termination. Recording stays prohibited until preview acceptance passes and Karl explicitly authorizes it.
```

---

# Current continuation — Checkpoint Prompt C, then Prompt D (hardware acceptance)

Prompt B is COMMITTED as `9bb82d1`. Prompt C is complete and software-verified in `/Users/karlwatson/Downloads/ScratchLab-TTM-Reconstruct`, branch `feature/ttm-crossfader-takestart-reconstruct`, base `9bb82d1`: nine modified files (six production + three existing test files) at +1,075 / −23, plus the four workflow records. Evidence is macOS build, macOS build-for-testing and unsigned generic iOS build, with 328 + 318 focused test executions and zero failures. Do not rerun those gates. Proposed subject: `fix(notation): declare the platter coordinate contract and state Review limits`.

Prompt C summary. `ScratchNotation.GestureRecord.CoordinateSpace` gained `normalizedTakeLocalDisplacement`; `CaptureCore.PlatterNotationCoordinates` is the named contract each boundary states, always defaulting to the non-claiming basis and failing closed rather than inventing a calibration. Finalized reference takes declare NORMALIZED (their evidence carries no steps-per-revolution reference); live declares CALIBRATED from `LivePerformedNotationTracker.platterCoordinates`. Live and finalized agree on time, grid, direction and hold structure and draw the same shape after each is rescaled onto its own span. The Baby-only audio detector is labelled LIMITED — not a disagreement — on Tear-selected takes and never overwrites the selected technique. Review overload is reduced by grouping and lazy disclosure only. No threshold, gate, export schema or approval/training rule changed.

Prompt D is the first hardware step and is still NOT authorized by this file. Before it, a fresh build with a UNIQUE bundle id and its own container is required, following the `com.machelpnz.scratchlab.previewsmoke.*` precedent — `~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app` is a mutable, worktree-agnostic path and remains unauthorized as an isolated hardware candidate. It historically carried the production bundle id `com.machelpnz.scratchlab`, resolving to the container holding Takes 001–008; the first Prompt C isolation attempt supplied `-derivedDataPath` without explicit `SYMROOT`/`OBJROOT`, and Xcode overwrote that shared app with its currently verified bundle id `com.machelpnz.scratchlab.promptcverify.20260906`.

Prompt D PRECONDITIONS. Every one of these must hold before any Prompt D recording instruction below is executed. They are not advisory.

1. **Prompt C must be checkpointed first.** Prompt D does not begin while this candidate is uncommitted.
2. **A uniquely identified preview-smoke bundle and its own separate container must be used**, following the `com.machelpnz.scratchlab.previewsmoke.*` precedent. `~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app` remains unauthorized because the shared path is mutable and worktree-agnostic. It historically carried `com.machelpnz.scratchlab` and resolved to the production container holding Takes 001–008; the first Prompt C isolation attempt overwrote it with `com.machelpnz.scratchlab.promptcverify.20260906`, its currently verified bundle id, because `-derivedDataPath` alone did not isolate products. Explicit `SYMROOT`/`OBJROOT` were used for the subsequent isolated rerun. Note that an app-hosted XCTest run under the production bundle id also writes to that production container — Prompt C's focused run 2 refreshed 27 derived `AuditSummaries/relayedWatch` JSON files that way.
3. **The five-cycle preview acceptance gate must pass, in full, BEFORE any recording:**
   - enter and leave Advanced → CXL Reference Authoring — Hardware Test five times;
   - navigate away during camera configuration, start and stop, then return;
   - exercise a safe camera-device change;
   - resize the window;
   - close and reopen the window;
   - verify restoration after a separately authorized normal quit and relaunch.
4. **If any beachball occurs, stop interacting and collect three ten-second samples from the verified PID before any termination.** Verify the PID and its path first.
5. **Recheck production evidence hashes and confirm Take 009 is absent from protected session `41949897-5458-449d-9280-65508a4f6600`.** Unrelated historical Take 009 artifacts exist in other sessions and are not this check.
6. **Record nothing until the preview gate passes AND Karl separately authorizes recording.** Live-camera and window-restoration hardware acceptance is still PENDING (see the camera checkpoint entry below); passing the preview gate does not by itself authorize a take.

Exact hardware-acceptance prompt for Prompt D, once every precondition above holds, Karl authorizes it and an isolated build exists:

```text
Open the isolated ScratchLabDesktop build (unique bundle id, own container) on the Rane ONE MKII rig with the paired Watch and camera connected. In the DEBUG Reference Authoring screen:

1. Select Tear, set deck and open end to match the physical wiring, apply the setup, and confirm the saved Ch16 CC8 calibration is adopted automatically with no sweep requested. Do not press Recalibrate.
2. With the crossfader PARKED OPEN and untouched, record one take of four Tear repetitions. Do not wiggle the fader before or after pressing Record.
3. While recording, read the line under "YOUR MOTION — LIVE (TEAR STRUCTURE)". Report VERBATIM whether it says the unit is calibrated platter revolutions or this take's own normalised displacement, and whether the chart shows same-direction subdivisions separated by horizontal holds or still alternating diagonals.
4. Stop and finalize. Under "CANONICAL TEAR STRUCTURE — FINALIZED TAKE", report the "Platter coordinates:" line VERBATIM. It must say normalised and NOT calibrated revolutions. Report whether the live and finalized charts show the same gesture count, the same hold placement and the same direction per gesture.
5. Report the take's scratchTypeID, the mapped crossfader sample count, whether the sidecar carries a crossfaderTakeStartState with provenance preTakeSnapshot and a NEGATIVE observedTakeRelativeTime, and what approvalBlockReason says about the fader state.
6. Report the "Advisory auto-detection:" line VERBATIM. On a Tear take it must read LIMITED and must not present Baby Scratch as a mismatch. Confirm the selected technique still reads Tear.
7. Report the review group headlines and their counts, then open each group and confirm the total gesture count across all groups equals the "gesture" count in the aggregate row, with no gesture missing.
8. Report every gesture drawn as MOTION UNKNOWN or FADER UNKNOWN and the reason lines given.
9. Press Save Capture..., save the ZIP, and confirm export succeeded with no repetition selected and approval still blocked.

Do not approve, publish, install, commit or push anything. Report exact numbers and exact strings.
```

If the parked-fader path yields no `preTakeSnapshot` record, capture the sidecar JSON and its `unknownReason` before changing code: the correlation fails closed and the reason string names which identity did not line up.

---

# Current continuation — Checkpoint Prompt B, then Prompt C (coordinate contract and Review truth)

Prompt B MUST BE CHECKPOINTED FIRST. Its candidate is complete and software-verified in `/Users/karlwatson/Downloads/ScratchLab-TTM-Reconstruct`, branch `feature/ttm-crossfader-takestart-reconstruct`, base `cb4adc5512d1af5fa3f2a95824f10e187f0e6a1e`: nine modified files — the five-file code boundary at +326/−9 plus DEV_LOG.md, AI_HANDOFF.md, AI_HANDOFF/next_prompt.md and TASKS.md. Evidence is 150 focused executions with zero failures, plus macOS build-for-testing, iOS build and macOS build. Do not rerun those gates. Proposed subject: `fix(capture): preserve parked fader state and calibration status`.

Prompt C source brief. The batch file `C_COORDINATE_AND_REVIEW_TRUTH.md` was NOT readable in the executing environment, so its scope is restated here from this repository's own recorded remaining defects rather than from an invented path. If Karl supplies the brief, read it first and let it govern.

Prompt C purpose — coordinate contract and Review truth. Two defects are already recorded here. First, reference-take platter coordinates are span-normalised, so a finalized reference take cannot be fed to the segmenter without fabricating a calibration; the coordinate contract must be made explicit rather than inferred. Second, the real live caller at `ReferenceAuthoringView.swift:224` supplies movement events without platter provenance, so live/finalized parity has NOT been established — the existing synthetic projection parity test injects provenance and does not exercise that production wiring. DEV_LOG also records that "Coordinate-contract, parked-fader generation, calibration copy and detector advisory defects from the audit remain separate unauthorized slices." Review must state what it actually measured, and unknown must stay unknown.

Prompt C constraints. One slice, small testable diffs, deterministic tests for every behaviour change. No fabricated calibration and no calibration synthesised from a fader response curve. Do not rewrite historical evidence or raw captured events. Do not change the export schema, Practice/scoring/coaching, signing, bundle ids, entitlements, Info.plist, PrivacyInfo.xcprivacy or bundled resources. Preserve any pre-existing dirty files, and leave `~/Downloads/ScratchLab-TTM` untouched at `863e420`. Verification is Debug only — iOS build, macOS build and macOS build-for-testing with focused `-only-testing:` selectors; Release tests are impossible in this project.

NO HARDWARE RECORDING IS PERMITTED UNTIL PROMPT D. Through Prompt C do not launch an app, record a take, calibrate, unplug or replug a controller, deploy, export, approve, install, publish or train. The shared product at `~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app` is not isolated — it carries the production bundle id and container — and must not be used or described as an isolated hardware candidate; Prompt D needs a fresh build with a unique bundle id and its own container.

---

# 2026-09-06 — Camera preview/session deadlock repair checkpoint

This record accompanies Karl's single authorized checkpoint `fix(camera): serialize preview association on the capture session queue` on `fix/camera-preview-session-deadlock`, parent `863e420619ddaefd2dc6b4b13b2a697f634994a1`. Exactly five macOS production files, MacCameraPreviewViewTests.swift and four workflow documents belong to it. After the commit, verify the clean worktree/index and exact parent/files. Earlier no-commit statements below describe prior stages and do not authorize any further commit. No push, merge, deployment, interactive launch, recording, approval, publication, installation, training or Tear resumption is authorized.

The repeated main-thread blocking boundary is proven: SwiftUI/AppKit preview teardown synchronously assigned previewLayer.session while the capture-session queue committed configuration and waited inside AVFoundation movie-output graph teardown. The private AVFoundation lock owner/callback target is NOT proven. The new owner-bound PreviewAttachment serializes asynchronous attach/detach on the existing engine sessionQueue. MainActor retains presentation work; dismantle performs no AVFoundation access. Per-layer generations and separate replacement layers prevent stale work from detaching another preview. Pending work retains the layer/session without retaining the view; final queued cleanup releases association. One authoritative session remains and preview code does not start, stop or reconfigure capture. No capture, Watch, Tear, export, approval or training semantics changed.

Source/test SHA-256 values match the exact verified candidate in `/private/tmp/scratchlab-preview-deadlock-repair-20260906/final-source-sha256.json`. No test or build was rerun for checkpointing; only these workflow records changed after verification. Corrected preview suite: 25/25 in each existing configuration. Eleven other unchanged suites: 625 passed + 2 fixture-dependent skips per configuration. Combined final coverage: 1,300 passes, four skips, zero unresolved failures. Initial broad-run lifetime-test failures remain documented; its weak-reference assertion was retained and now follows explicit Core Animation transaction completion. Final build-for-testing, macOS Debug and unsigned universal Release passed; arm64 + x86_64 and absence of the DEBUG hardware route were verified. No iOS/watchOS source membership or project/scheme/configuration change.

Live-camera and window-restoration hardware acceptance remains PENDING. Two broad-run main-thread warnings remain. One passing source-read test took 56.722 seconds (0.014 seconds in the other configuration); the delay remains unexplained and no live stack was captured before the test host exited. Software tests do not establish physical AVFoundation acceptance. PID 11022 was terminated only after Karl explicitly authorized SIGTERM. No Tear recording is authorized yet.

Checkpoint audit artifacts are in `/private/tmp/scratchlab-preview-checkpoint-20260906-175411/`; original repair results and complete logs/xcresults remain in `/private/tmp/scratchlab-preview-deadlock-repair-20260906/`. Preservation compares all 68,170 production-store files, 14 saved Take 007/008 hashes, all 661 feature TTM tracked-file hashes/status/diff/index and eleven protected project/configuration files. The feature worktree retains exactly its two original dirty files: project.pbxproj and CrossfaderCalibrationStore.swift. Target-session Take 009 must remain absent. Hooks are inspected and never bypassed. Post-commit verification and the exact next preparation prompt are saved outside the repository so they do not dirty this checkpoint.

Bundle identity clarification from checkpoint inspection: the verified Debug and Release repair artifacts are 1.0.1 (21), matching the unchanged desktop CURRENT_PROJECT_VERSION = 21. The original hung isolated build was 1.0.1 (23). No project/build-number change belongs to this repair. The next clean smoke build must verify its actual identity and keep the unchanged value 21; the earlier OWNERSHIP-AND-RETEST.md instruction expecting 23 is superseded by this clarification and the new preparation prompt.

Next scope, only when Karl requests it: prepare a fresh isolated preview-only smoke host and stop BEFORE launch. Do not reuse production data, the populated XCTest container, or the original hung build. Hardware navigation and restoration require a later explicit instruction; recording remains separately prohibited even after preview acceptance. Read the matching DEV_LOG entry and the checkpoint's PREVIEW-SMOKE-PREPARATION-PROMPT.md before that preparation.

---

## Current continuation - Physical Tear hardware verification (checkpoint 2 candidate prepared, 2026-09-06)

Both checkpoints now exist: checkpoint 1 is committed as `997bc33` (the derived-structure classifier that repaired the non-building HEAD); checkpoint 2 is prepared as an UNCOMMITTED isolated candidate at `/private/tmp/scratchlab-cp2-tear-authoring.sh87xI/worktree` on `checkpoint/tear-authoring-raw-export`. Read `AI_HANDOFF.md`'s top entry and the 2026-09-06 `DEV_LOG.md` entry before doing anything.

Nothing below has ever run against real hardware. Take 007 user-observed screenshots exposed the problem (their finalized-take paths end in `41949897-...._take007_routine`); every test so far uses synthetic fixtures, and no physical artifact was parsed or modified.

EVIDENCE LOCATION. The authoritative physical-capture store for the sandboxed macOS app is
`~/Library/Containers/com.machelpnz.scratchlab/Data/Library/Application Support/ScratchLab/`.
It holds Takes 001-008. Take 007 is the chatter evidence (83 movement events, 29,699 mixer MIDI, 38 crossfader samples, watchSync failed). Take 008 is a separate real artifact with 55 movement events, 19,097 mixer MIDI events, zero mapped crossfader samples and linked Watch capture `786056BA-4C08-4277-9422-43FE0BF88E2D`. A legacy NON-container store at `~/Library/Application Support/ScratchLab/` also exists; do not conflate the two, and do not treat the non-container 202-file manifest as protecting the real evidence.

Exact next prompt:

```text
Open the macOS ScratchLabDesktop app on the Rane ONE MKII rig with the paired Watch and camera connected, running the checkpoint-2 build. In the DEBUG Reference Authoring screen:

1. Select Tear, set deck and open end to match the physical wiring, apply the setup, and confirm the saved Ch16 CC8 calibration is adopted automatically with no sweep requested. Do not press Recalibrate.
2. With the crossfader PARKED OPEN and untouched, record one take of four Tear repetitions. Do not wiggle the fader before or after pressing Record.
3. While recording, report whether the live chart shows same-direction subdivisions separated by horizontal holds, or still alternating diagonals.
4. Stop and finalize. Report the take's scratchTypeID, the mapped crossfader sample count, whether the sidecar carries a crossfaderTakeStartState with provenance preTakeSnapshot and a NEGATIVE observedTakeRelativeTime, and what approvalBlockReason says about the fader state.
5. Compare the finalized canonical chart against the live one and the video. Report any gesture drawn as MOTION UNKNOWN and the reason lines given.
6. Press Save Capture..., save the ZIP, and confirm export succeeded with no repetition selected and approval still blocked.

Do not approve, publish, install, commit or push anything. Report exact numbers.
```

If the parked-fader path yields no `preTakeSnapshot` record, capture the sidecar JSON and its `unknownReason` before changing code: the correlation fails closed and the reason string names which identity did not line up.

---
## Current continuation - Prompt 5 checkpoint; Prompt 6 preflight only

This record accompanies the single authorized checkpoint `feat(notation): add authored canonical tear templates`, parent `c17bdb9def7566414dfb7e5d444964bd87d8db12`, on `feature/ttm-tear-notation-alignment` in `/Users/karlwatson/Downloads/ScratchLab-TTM`. The user's checkpoint instruction explicitly permits this one commit after isolation and gates are proved, superseding the earlier no-commit text for this checkpoint only. Implementation began clean; checkpoint baseline contains exactly six isolated slice files and an empty index. Every complete diff was reviewed; all six file hashes matched the saved end-of-slice audit before checkpoint documentation updates. No unrelated pre-existing dirty work or mixed hunks; no other worktree's source/data accessed. After successful commit, expect a clean worktree/index. No push or next implementation slice authorized.

The 18 DEBUG-only ScratchLab-authored 1/2/3-tear targets cover forward/backward/forward-to-backward, equal and unequal moving ratios, stable IDs, beat-domain GestureRecords, explicit bounded holds and open fader. One beat per direction, 1/16-beat holds and equal travel per slice are teaching choices. Production catalog, curriculum flare-orbit semantics, learner progression, references, capture, detector, renderer and export are unchanged. No ScratchBook GPL source/code/data or formula language.

Checkpoint verification confirmed unchanged source rather than rerunning it: macOS arm64 `build-for-testing` passed (`build-final.xcresult`); exact 17 focused selectors under `ScratchLabDesktopTests` passed 155 declarations / 420 expanded executions, zero failures/skips/runtime warnings (`focused-complete.xcresult`). Both test-plan configurations include all eight new tests / 44 expanded cases. Full serial `scripts/build.sh all` exited 0: Python 82; native 8,266 passes / 112 expected skips / zero failures; two main-thread runtime warnings; iOS/macOS/watchOS builds passed (iOS/watchOS unsigned). Unsigned universal macOS Release passed, x86_64 + arm64, with internal template markers absent. Authoritative bundles/summaries and commands remain under `build/prompt5`; checkpoint re-read summaries exactly match originals (`checkpoint-focused-summary.json`, `checkpoint-full-summary.json`). See `checkpoint-commands.txt` and latest DEV_LOG for full commands, destinations and selectors.

All 11 protected project/scheme/test-plan/plist/privacy/entitlement files match the parent, including `project.pbxproj` and both schemes; no protected-file approval needed. Source/test hashes still match their verified build. Audit: `checkpoint-audit.json`; pre-checkpoint complete diff: `checkpoint-before-docs.diff`. Initial sandbox and missing-test-bundle bootstrap failures remain preserved; final success bundles are identified above. A future test-without-building run after a standalone build needs build-for-testing first to restore the embedded test bundle.

Explicit preservation: no raw capture was deleted or rewritten; no recording or bundled reference was made valid, canonical, approved or training-eligible; no detector inference was presented as human ground truth; no ScratchBook GPL source/code/data was copied; no unrelated work is included in this checkpoint. Remaining limits: authored internal teaching examples, no physical/GPU acceptance, and two pre-existing full-suite runtime warnings. No deployment, hardware capture, training or push.

## Prompt 6 — read-only preflight and specification check only.

Work only in `/Users/karlwatson/Downloads/ScratchLab-TTM`. Read `AGENTS.md`, `SOUL.md`, `PROFILE.md`, `AI_CONTEXT.md`, relevant `TASKS.md`/`DEV_LOG.md` entries and both handoff files. Run `git status --short --branch` and `git log -1`; verify the Prompt 5 checkpoint subject `feat(notation): add authored canonical tear templates` and parent `c17bdb9def7566414dfb7e5d444964bd87d8db12`. Report any dirty files without changing them. Review the exact verification evidence and remaining limits. Locate an explicit user-supplied Prompt 6 implementation brief; if none is present, report that it is missing and stop after the read-only report. Do not infer scope from the backlog. No implementation, protected-file edits, capture, detector, export, progression, reference approval/eligibility, training, deployment, commit or push is authorized by this preflight prompt.

---

# Current continuation - Prompt 4 checkpoint; Prompt 5 preflight only

This record accompanies the single authorized checkpoint `feat(notation): render canonical tear motion and fader evidence`, parent `366f4c250f30db445210809f93062dd0898d892e`, on `feature/ttm-tear-notation-alignment`. After successful commit, expect a clean worktree/index. The latest checkpoint instruction supersedes the implementation turn's no-commit text for this one commit only. No push or next implementation slice is authorized.

The canonical renderer implementation and 23 deterministic tests are complete. Final macOS arm64 test build and focused 18 suites passed: 180 declarations / 398 expanded executions, zero failures/skips/runtime warnings, both configurations. Full serial `scripts/build.sh all` passed: Python 82; native 8,178 passes / 112 skips / 0 failures, two main-thread runtime warnings; iOS, macOS and watchOS builds passed. At checkpoint, all seven source/test hashes match those results, all eleven complete diffs are isolated, and all eleven protected project/configuration files match the parent. Bundles were re-read and match the saved summaries; no source changes or redundant test reruns. Exact commands, bundles, summaries and audit proofs remain in ignored `build/prompt4`; see the latest DEV_LOG entry. Initial failed evidence remains preserved. Canonical producer wiring, physical CXL and GPU bitmap verification remain outside this slice.

## Prompt 5 — read-only preflight and specification check only

Work only in `/Users/karlwatson/Downloads/ScratchLab-TTM`. Read `AGENTS.md`, `SOUL.md`, `PROFILE.md`, `AI_CONTEXT.md`, the relevant `TASKS.md`/`DEV_LOG.md` entries and both handoff files. Run `git status --short --branch` and `git log -1`; verify the Prompt 4 checkpoint and report any dirty files without changing them. Review Prompt 4's exact verification evidence and remaining risks. Locate an explicit user-supplied Prompt 5 implementation brief; if none is present, report that it is missing and stop after the read-only report. Do not infer Prompt 5's scope. No implementation, detector/capture/export/training/navigation changes, protected-file edits, commit or push are authorized by this preflight prompt.

---

## Current continuation - Prompt 3 checkpoint; Prompt 4 preflight only

This record accompanies the single authorized checkpoint `feat(notation): segment calibrated platter motion for tear candidates`, parent `0521b1ef4ee4ee77f21fa52a1da4188f92e18a50`, on `feature/ttm-tear-notation-alignment`. It supersedes earlier no-commit text for this checkpoint only. After successful commit, expect a clean worktree/index. No push or next implementation slice is authorized.

All six complete diffs were reviewed and contain only this slice. The implementation began from a clean worktree; the index was empty at checkpoint start. Source/test hashes match the verified build and focused results. All 11 protected project/scheme/test-plan/plist/privacy/entitlement files match the parent. The checkpoint changes only four required workflow records after verification; no source/test code changed. Evidence: `build/prompt3/checkpoint-audit.json` and `checkpoint-commands.txt`.

Verified without rerunning unchanged code: macOS `build-for-testing` PASS; the exact 17 selectors on `ScratchLabDesktopTests`, `platform=macOS,arch=arm64`, passed 147 declarations / 398 expanded executions in both configurations, zero failures/skips/runtime warnings. Full `scripts/build.sh all` PASS: 82 Python tests; 8,132 native passes / 112 skips / 0 failures, two main-thread runtime warnings; iOS, macOS and watchOS builds passed (iOS/watchOS unsigned). Bundles: `build-fixed.xcresult`, `focused.xcresult`, `full-tests.xcresult` under `build/prompt3`. The full gate is additional evidence, not a replacement for the focused selectors.

No raw capture was deleted or rewritten; no existing recording or bundled reference became valid, canonical, approved or training-eligible; no detector inference was presented as human ground truth; no ScratchBook GPL source/code/data was copied; no unrelated work belongs to the commit. Calibration remains synthetic and no app consumer, UI/capture/export wiring, fader decision input or scratch naming was added. Physical CXL parameters and false-positive limits remain documented in DEV_LOG.

Exact next safe numbered prompt:

```text
Prompt 4 — read-only preflight and specification check only.
Work only in /Users/karlwatson/Downloads/ScratchLab-TTM. Do not access another working tree.
Read AGENTS.md, SOUL.md, PROFILE.md, AI_CONTEXT.md, TASKS.md, DEV_LOG.md and the current handoff.
Verify branch feature/ttm-tear-notation-alignment, a clean worktree/index, and HEAD subject "feat(notation): segment calibrated platter motion for tear candidates" with parent 0521b1ef4ee4ee77f21fa52a1da4188f92e18a50. Stop on mismatch.
Preserve Prompt 1/2 canonical semantics, Prompt 3 segmenter behavior and Baby Scratch behavior.
Report preflight results only. The Prompt 4 implementation brief has not been provided; do not infer one from the backlog.
Do not edit, implement, commit, push, deploy, record, approve a reference, alter eligibility or enable training.
```

## Current continuation - Prompt 2 checkpoint; Prompt 3 preflight only

Supersedes older blocks below. The Prompt 2 checkpoint is the commit containing this entry, subject `feat(notation): add lossless canonical tear gesture records`, parent `57398919d508d1b94c206510aac12efed83a6478`. The checkpoint request authorizes exactly that commit and no push. After successful commit, expect a clean worktree/index.

Exact next safe numbered prompt:

```text
Prompt 3 — preflight and specification check only.
Work only in /Users/karlwatson/Downloads/ScratchLab-TTM. Do not access any other worktree.
Read AGENTS.md, SOUL.md, PROFILE.md, AI_CONTEXT.md, TASKS.md, and the latest DEV_LOG/AI_HANDOFF entries.
Verify branch feature/ttm-tear-notation-alignment, a clean worktree and index, and that HEAD is the Prompt 2 checkpoint commit with parent 57398919d508d1b94c206510aac12efed83a6478 and subject "feat(notation): add lossless canonical tear gesture records". Stop on any mismatch.
Read the full architect-approved Prompt 3 specification if supplied. If it is absent, report that the specification is missing and stop; do not infer implementation requirements from the backlog.
Preserve Prompt 1 and Prompt 2 semantics and Baby Scratch behavior. Report preflight results only. Do not edit, implement, commit, push, deploy, record, approve a reference, or enable training.
```

The Prompt 3 implementation brief is not available in the current conversation/continuation; the preflight above deliberately grants no implementation scope. Prompt 2 focused verification is already proven for unchanged code: 124 tests / 286 expanded runs across both configurations, zero failures/skips, with exact commands and evidence in DEV_LOG and `build/prompt2`. The full batch gate remains deferred.

## Current continuation - Prompt 2 complete; stop pending a new instruction

This supersedes older continuation blocks below. Work only in `/Users/karlwatson/Downloads/ScratchLab-TTM`; never access another worktree. Branch `feature/ttm-tear-notation-alignment`, HEAD `57398919d508d1b94c206510aac12efed83a6478`; Prompt 1 committed, Prompt 2 complete and uncommitted, index empty.

1. Read repository instructions and newest DEV_LOG/AI_HANDOFF. Expect six intentional dirty files: `ScratchLab/Models/CaptureCore.swift`, `ScratchLabDesktopTests/ScratchNotationCanonicalModelTests.swift`, `TASKS.md`, `DEV_LOG.md`, `AI_HANDOFF.md`, `AI_HANDOFF/next_prompt.md`. Preserve them.
2. Prompt 2 adds the standalone canonical `GestureRecord` data model only. Existing Prompt 1/Baby behavior and all consumers remain untouched. Duration ratios explicitly exclude holds; absent fader spans remain unknown; curves remain sampled data; IDs survive edits and Codable.
3. Focused verification already passed: final macOS test build plus 124 tests in 15 suites / 286 expanded executions, zero failures/skips, both configurations. Evidence under `build/prompt2`, exact command and selectors in DEV_LOG. Do not rerun without a reason.
4. Full batch/platform gates remain deferred. No additional slice, commit, staging, push, deployment, capture, approval, publication or training is authorized. Await the next explicit instruction.

## Current continuation - TTM Prompt 1 committed; Prompt 2 not started

Supersedes the continuation blocks below. Worktree `/Users/karlwatson/Downloads/ScratchLab-TTM`, branch `feature/ttm-tear-notation-alignment`, Prompt 1 parent `3316fe0`.

1. Re-read the repository instructions and the newest `DEV_LOG.md` / `AI_HANDOFF.md` entries. Confirm the branch, HEAD, an empty index and a clean worktree before editing anything. Never write to the primary worktree at `/Users/karlwatson/Downloads/ScratchLab`.
2. Prompt 1 landed the canonical tear semantics layer only: `ScratchNotationMotionState`, `ScratchNotationFaderClickKind`, `ScratchNotationEvidenceSource`, `ScratchNotationEvidence`, `ScratchNotationMotionLabel`, `ScratchNotationCorrelatedState`, the `ScratchMovementKind` bridge, and `ScratchNotation.BeatSpan` / `PlatterMotionSegment` / `FaderInterval` / `FaderClick` / `PlatterGesture` / `GesturePattern`, plus `BeatPattern.gesturePattern()` and `babyScratchGesturePattern`. All of it is in `ScratchLab/Models/CaptureCore.swift`; the tests are appended to `ScratchLabDesktopTests/ScratchNotationCanonicalModelTests.swift`.
3. Known gaps deliberately left for later prompts, none of which are authorized yet: nothing consumes `GesturePattern` (no adapter, renderer, capture path, detector or export); there is no capture-side producer turning a decoded platter timeline into motion segments, including the zero-velocity threshold that separates `.stationary` from `.unknown`; `canonicalBeatPatterns` still holds only `babyScratchCycle`, so `baby_scratch` remains the only safe-to-author technique; `BeatPattern.gesturePattern()` reads an authored inter-stroke gap as `.stationary` because the authored schema cannot express a release; there is no `FaderClick` derivation from `FaderEvent` edge pairs, since deciding "short enough to be a click" is a threshold policy needing evidence; `GesturePattern` is tempo-free by type and carries no `speedClassification`.
4. Remaining verification for this batch, to run ONCE against the complete TTM branch and not per slice: one serial `PATH=../bin:$PATH ./scripts/build.sh all`, plus the explicit macOS Debug and unsigned universal macOS Release legs if any later slice introduces conditional compilation, and `git diff --check`.
5. Do not push, merge, cherry-pick, rebase or integrate this branch. Integration is Karl's decision and is not authorized here.
6. Do not deploy, launch the ordinary app, record a take, approve, install or publish a reference, or enable training.
7. Do not start Prompt 2 without an explicit instruction naming it.

## Current continuation - all six boundaries committed; final gate is the remaining step

Supersedes the continuation blocks below. Candidate `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`, base `add70a08668e512c95e467871613f577a30523f1`.

1. Re-read the repository instructions and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, indexes and HEADs. Never write to the primary worktree.
2. Remaining verification, run once against the complete six-commit branch: serial `PATH=../bin:$PATH ./scripts/build.sh all`; an explicit macOS Debug build; an explicit unsigned universal macOS Release build with `ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO`; proof that `referenceAuthoringHardwareTest` is present in the Debug binary and absent from the Release binary; and `git diff --check`.
3. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake, and only when every other test passes, all platform builds pass and no differing signature appears. Any other failure is blocking: stop and report.
4. Integration is Karl's decision and is not authorized here. Do not push, merge, cherry-pick, rebase or integrate the branch into the primary.
5. Do not deploy, launch the ordinary app, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear.
6. TTM Prompt 1's hard prerequisite, the CaptureCore calibration checkpoint, is commit `579ace6`. `CaptureCore.swift` has no remaining uncommitted primary hunks.

## Current continuation - Boundaries 1 to 5 committed; Boundary 6 is last

Supersedes the continuation blocks below. Candidate `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`.

1. Re-read the repository instructions and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, indexes and HEADs. Never write to the primary worktree.
2. Boundary 6 only: `feat(reference): add debug authoring workflow and live notation`. Extract `ReferenceAuthoringViewModel.swift`, `ReferenceAuthoringView.swift`, `ReferenceAuthoringViewModelTests.swift`, the `LivePerformedNotationTracker.swift` changes, the `LivePerformedNotationTrackerTests.swift` changes and the `MacCameraPreviewViewTests.swift` changes.
3. `MacAnalyzerView.swift` DEBUG-route hunks: 521, 535, 549 and 3744, which are all four hunks that file has. `CaptureReliabilityPhase1Tests.swift` hunk 12009 adds `CaptureRecoveryPhase2CoreTests/testMacReferenceAuthoringHardwareRouteIsDebugOnly`.
4. `project.pbxproj`, D-owned new-side lines: hunk 587 lines 621-623; hunk 1047 lines 1103-1105; hunk 1091 line 1150; hunk 1544 line 1610; hunk 1556 line 1623; hunk 1577 lines 1645-1652; hunk 1993 lines 2098-2099; hunk 2407 line 2543. Rebuild from the pristine base with the union of Boundary 3, 4, 5 and 6 membership. That completes the file; the six `CURRENT_PROJECT_VERSION` hunks stay excluded and the build number stays 21.
5. Preserve: the route exists only in DEBUG with the exact label `CXL Reference Authoring — Hardware Test`; the live `MacCaptureEngine` is injected; opening the screen starts no capture and persists nothing; blocking bridge work stays off the main actor; leaving cancels polling safely; Watch pending/error polling stays bounded; the camera preview observes the engine session but never creates, starts or stops it; the tracker lifecycle survives mid-take re-entry; authoring recording state, not a speculative engine flag, controls tracker attribution; notation card `minHeight` stays 180; the camera preview keeps 16:9 with `maxHeight` 360; idle layout reserves notation height; the DEBUG diagnostics row shows raw, matched, moves, span and age; only the diagnostics ROW is compiled out of Release - do not claim the underlying tracker diagnostics computation is DEBUG-only; no coordinate, decoder, motor-phase-origin or renderer y-scale semantics change; and no TTM/Tear implementation.
6. Verify with `ReferenceAuthoringViewModelTests`, `LivePerformedNotationTrackerTests`, `MacCameraPreviewViewTests`, `ScratchNotationPanelTests`, `ReferenceAuthoringTests`, `ReferenceAuthoringSessionTests`, `ReferenceAuthoringCaptureBridgeTests`, `CrossfaderCalibrationTests` and the exact DEBUG-route selector.
7. Then, once, against the complete six-commit branch: serial `scripts/build.sh all`; an explicit macOS Debug build; an explicit unsigned universal macOS Release build; proof that the route symbol or case is present in Debug and absent from Release; and `git diff --check`.
8. Use `apply-hunks.rb`; never `git apply --unidiff-zero`. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake. Any other failure, extraction ambiguity, preservation mismatch or unexpected dependency is blocking.
9. Do not push, merge, deploy, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear.

## Current continuation - Boundaries 1 to 4 committed; Boundary 5 is next

Supersedes the continuation blocks below. Candidate `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`.

1. Re-read the repository instructions and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, indexes and HEADs. Never write to the primary worktree.
2. Boundary 5 only: `feat(reference): correlate capture and Watch evidence before approval`. Extract `ReferenceAuthoringSession.swift`, `ReferenceAuthoringCaptureBridge.swift`, `ReferenceAuthoringSessionTests.swift` and `ReferenceAuthoringCaptureBridgeTests.swift`.
3. Engine hunks, C-owned: 650, 3029, 3808, 4753, 4761, 4764, 4768, 4782, 4787, 4820, 4821, 4825, 4829, 4833, 4837, 4841, 4845, 4849, 4881, 4983, 4989, 6457, 6478, 6520, 6538, 6709, 6733, 6735, 11832; plus the C-owned portions of 10790 (new 11140-11150 learned-mapping snapshot and new 11175-11252 live CC observability) and 10812 (new 11291-11298 unconditional live observation call). Rebuild the engine from the pristine base with the union of Boundary 1, 3 and 5 hunks.
4. `CaptureReliabilityPhase1Tests.swift`: hunks 3202 and 3204 (multiline-signature assertion) and 14151 (four take-scoped MIDI tests). Do not re-extract the inherited 290-line receipt tests at 22196. Old-side coordinates 3202/3204/14151 are still valid because the file is identical to the primary base through line 22196 and every later addition has been appended at the end.
5. `project.pbxproj`, C-owned new-side lines: hunk 587 lines 616-620; hunk 1047 lines 1099-1102; hunk 1091 lines 1151-1152; hunk 1580 line 1656; hunk 1993 lines 2100-2101; hunk 2220 line 2342; hunk 2407 lines 2544-2545. Line 1887 must be inserted content-anchored inside the existing `Reference` group, not at its old anchor.
6. Preserve the safety semantics: reserve identity before Watch start; require Watch acknowledgement before Mac recording; correlated stop and finalization use the same take identity; the engine retains sole stop authority; Watch evidence states stay truthful; pending transfer and identity mismatch both remain blocking; approval revalidates domain state and cannot be bypassed by a direct call; nothing installs, publishes or enables training; no timeout extension substitutes for a missing transfer. D5 session reuse stays documented and unfixed unless it is an unavoidable correctness dependency, in which case stop for Karl.
7. Verify with `ReferenceAuthoringSessionTests`, `ReferenceAuthoringCaptureBridgeTests`, `MacWatchStopDispatchTests`, `RoutineFinalizationWatchMergeTests`, the receipt-staging regressions, the microphone source assertion and the four exact take-scoped MIDI selectors, plus affected platform builds only.
8. Use `apply-hunks.rb`; never `git apply --unidiff-zero`. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake. Any other failure, extraction ambiguity, preservation mismatch or unexpected dependency is blocking.
9. Do not push, merge, deploy, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear.

## Current continuation - Boundaries 1 to 3 committed; Boundary 4 is next

Supersedes the continuation blocks below. Candidate `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`. The CaptureCore checkpoint is reached.

1. Re-read the repository instructions and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, indexes and HEADs. Never write to the primary worktree.
2. Boundary 4 only: `feat(reference): add authoring evidence and package foundation`. Copy whole from the primary: `ReferenceTechnique.swift`, `ReferenceTake.swift`, `ReferenceValidation.swift`, `ReferenceRegistry.swift`, `ReferencePackage.swift`, `CallAndResponseSchedule.swift`, `LegacyReferenceInventory.swift`, `ReferenceCapturePreflight.swift`, `ScratchLab/Services/ReferencePackageIO.swift` and `ScratchLabDesktopTests/ReferenceAuthoringTests.swift`.
3. Do NOT include `ReferenceAuthoringSession.swift`, the capture bridge, the view model or view, the DEBUG route, live notation, or any ledger/observability engine change.
4. Boundary 4 `project.pbxproj` lines, new-side: hunk 587 lines 596-613 and 615; hunk 1047 lines 1088-1096 and 1098; hunk 1091 line 1153; hunk 1384 line 1448; hunk 1496 line 1561; hunk 1795 lines 1884-1886 and 1888-1899 (skipping 1887, which is Boundary 5); hunk 1993 lines 2102-2110; hunk 2220 lines 2343-2351; hunk 2407 line 2546.
5. Keep validation truthful: cut-requiring techniques require crossfader evidence, Baby and open-fader techniques require proven continuously-open evidence, unknown open state blocks, no detector result becomes human ground truth, withdrawn or invalid references stay unavailable, and package write does not install, publish or enable training.
6. Add or complete package-I/O write, read and verify round-trip coverage using isolated temporary storage only. Append new tests at the end of `CaptureReliabilityPhase1Tests.swift`; do not edit the audited `ReferenceAuthoringTests.swift`.
7. Verify with `ReferenceAuthoringTests`, `CrossfaderCalibrationTests` and the new round-trip tests, plus the affected platform builds only. The full serial gate, explicit Debug and universal Release builds and the DEBUG-route exclusion proof run once after Boundary 6.
8. Use `apply-hunks.rb`; never `git apply --unidiff-zero`. When a file was already changed by an earlier boundary, rebuild it from the pristine base with the union of all owned hunks.
9. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake. Any other failure, extraction ambiguity, preservation mismatch or unexpected dependency is blocking.
10. Do not push, merge, deploy, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear.

## Current continuation - Boundaries 1 and 2 committed; Boundary 3 is next

Supersedes the continuation blocks below. Candidate `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`.

1. Re-read the repository instructions and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, indexes and HEADs. Never write to the primary worktree.
2. Boundary 3 only: `feat(capture): preserve calibrated crossfader evidence`. This is the hard CaptureCore checkpoint required before TTM Prompt 1. Extract the four calibration sources under `ScratchLab/Models/ControllerInput/Calibration/`, all eight `CaptureCore.swift` hunks (8588, 8595, 8606, 8616, 8828, 8851, 8875, 8896), the calibration-owned engine hunks `4252,4439,10790:11102-11139+11151-11174,10811,10812:11279-11290,10945`, the whole `CrossfaderCalibrationTests.swift`, and calibration-only `project.pbxproj` membership.
3. Exclude the ledger, live-observability and reference-authoring engine code, the learned-mapping snapshot at new 11140-11150, the live CC observability at new 11175-11252, the unconditional live observation call at new 11291-11298, and all six `CURRENT_PROJECT_VERSION` 21 to 22 hunks. `project.pbxproj` membership lines are interleaved and must be split at line level, not hunk level.
4. Close the three still-open coverage gaps: `RawMixerMIDIEvent` calibrated-field Codable round trip, all-calibrated derivation through `CaptureCore.deriveDetectedNotationFaderEvents`, and mixed calibrated/un-calibrated fallback to `normalizedValue`. Append them at the end of `CaptureReliabilityPhase1Tests.swift`; do not edit the audited `CrossfaderCalibrationTests.swift`. The other six named gaps are already covered.
5. Verify with `CrossfaderCalibrationTests` plus the mapped-fader and round-trip tests in `CaptureReliabilityPhase1CoreTests`, then the serial gate, then platform builds and universal macOS Release.
6. Use `apply-hunks.rb`; never `git apply --unidiff-zero`. Reuse the wrapper, sandbox profile and host `com.machelpnz.scratchlab.refauth-iymlzu`.
7. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake, and only when everything else passes with no differing signature. Do not modify, skip or quarantine it. Any other failure or preservation mismatch is blocking.
8. Do not push, merge, deploy, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear.

## Current continuation - Boundary 1 committed; Boundary 2 is next

This entry supersedes the historical continuation blocks retained below. Candidate: `/private/tmp/scratchlab-refauth-baseline.iYmLZU/worktree`, branch `checkpoint/reference-authoring-baseline`, base `add70a08668e512c95e467871613f577a30523f1`. Boundary 1 of six is committed; the receipt repair is inherited from the base.

1. Re-read `AGENTS.md`, `SOUL.md`, `PROFILE.md`, `AI_CONTEXT.md`, `TASKS.md` and this candidate's newest `DEV_LOG.md`/`AI_HANDOFF.md` entries. Inspect both worktrees, both indexes and HEADs first. Never write to the primary worktree.
2. Next scope is Boundary 2 only: `refactor(export): add reusable artifact error descriptions`. Extract solely `ScratchLab/Services/SessionExportCoordinator.swift` hunk old 911, the self-contained insertion at new lines 912-1029 defining `SessionExportArtifactRejection` and `SessionExportFailureText`. The other 21 export hunks stay excluded; do not import call-site or error-propagation changes.
3. The helper has no existing test reference anywhere in the primary, so focused direct coverage must be added. Add it at the end of `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`, which already has target membership, so no `project.pbxproj` change is required. Append only; inserting before line 22196 would break old-side coordinates for later boundaries. Do not weaken existing tests.
4. Verify with the relevant `CaptureReliabilityPhase1CoreTests` export regressions, `SessionExportRoundTripTests` and the new helper tests, then the serial `scripts/build.sh all` gate, then explicit unsigned universal macOS Release if conditional compilation is involved.
5. Use `apply-hunks.rb` for extraction, never `git apply --unidiff-zero`. Reuse the existing wrapper, sandbox profile and host `com.machelpnz.scratchlab.refauth-iymlzu`; never a production identity.
6. Only `MIDILearnEngineTests/testCalibrationIsolatedBetweenDevices` failing with `Optional(0)` vs `Optional(5)` at `MIDILearnEngineTests.swift:561` is an authorized known flake, and only when every other test passes, all platform builds pass and no differing signature appears. Do not modify, skip or quarantine it. Any other failure, crash, preservation mismatch or unexpected dependency is blocking: stop and report.
7. Before committing, re-verify all 661 primary files, all 93 protected evidence files, empty indexes, unchanged primary HEAD/branch, intact receipt branch, unchanged protected settings and build number 21, and `git diff --check`. Stage exactly the authorized paths, inspect the complete staged diff, and stop on any extra hunk or path.
8. Do not push, merge, cherry-pick, deploy, launch the ordinary app, record Take 007, approve, install or publish a reference, enable training, or begin TTM/Tear. Boundaries 3 to 6 follow sequentially under the same rules.

## Current continuation - Receipt-only candidate verified; await explicit commit approval

This entry governs the isolated candidate and supersedes the historical continuation blocks retained below. Candidate: /private/tmp/scratchlab-receipt-candidate.Bs1CNx/worktree, detached at d3ecf2a69bde57f7d6ac681b6dbdd37347c83e97. Do not follow older unrelated tasks as current authority.

1. Re-read repository instructions and the current receipt candidate entry in AI_HANDOFF.md and DEV_LOG.md; inspect both worktrees and indexes.
2. Stay inside the audited two-service/290-line-test boundary. No project, scheme, build-number or new membership changes; stop for any outside dependency.
3. Next safe scope is read-only final receipt-commit review, not another implementation or automatic test run. Preserve original full.xcresult/full-build-gate.log: the configuration-1 failure was a Dock-mediated external SIGTERM; initiating actor and preceding UI unresponsiveness are unresolved. No assertion, exception, test timeout or host memory kill was established. Do not delete/relabel that failed run or pull earlier export work into this candidate.
4. Reuse verified unchanged-code results: focused 244 passed; five controlled exact-selector executions each 1 passed / 0 failed / 0 skipped; fresh full-sigterm-validation gate exit 0, Python 82 passed, native 7,320 passed / 110 skipped / 0 failed expanded executions. iOS, standalone macOS and watchOS builds all ran and passed. Two main-thread warnings remain. All commands/bundles and historical failure are recorded in DEV_LOG. Take 006 hardware evidence remains dirty-primary build 22, not this undeployed build-21 candidate.
5. Verify the exact seven-file diff, protected files, both empty indexes and primary/evidence checksums before presenting the proposed subject "fix(watch): stage received motion files before async import". Candidate is software-ready, but this prompt does NOT authorize staging, branching, committing or pushing. Obtain Karl's explicit approval for any such next action. Do not begin TTM/Tear against the still-mixed primary worktree. If further tests are explicitly authorized, rebuild and verify the unique sandboxed test host first: the final standalone Mac build left a normal-identity product, which must not be launched as a test host.
6. Preserve Takes 001-006, all historical metadata mutations and both old phone motion files. No restoration, Take 007, recording, TTM implementation, reference approval/publication/installation or training action is authorized.

## Current continuation - Watch stop is DONE; decide what to commit

Do not re-open the watch stop path or the overrun measurement. Both are fixed and hardware-verified: `session_2026_09_04_ppop_baby_scratch_95_bpm` validates PASS with zero warnings, `watchStopOutcome: stopped`, overrun 0 s, and the whole handshake inside one second.

The tree has ~20 modified files and **nothing is committed**. First action is to agree with Karl what to commit and on which branch (currently `feature/ios-capture-camera-ux`). The 2026-09-04 DEV_LOG entries list every file and why it changed. Do not commit or push without explicit approval, and no `Co-Authored-By` trailers.

If a fresh capture ever regresses: the root cause last time was the relay minting a fresh `commandID` instead of forwarding the Mac's, so no reply matched the awaited command. Check the ID being awaited before theorising about latency. `watchStopRelayReceivedAt` now distinguishes "the phone never heard it" (no receipt) from "the watch never answered" (receipt present).

Open, in priority order:
1. `TimecodeRealtimeIngressRingTests.testConcurrentSPSCStressAccountsForEveryAttempt` is flaky and makes `scripts/build.sh` non-deterministic. Either the SPSC ring drops a published slot under contention (a real defect) or the test's accounting is wrong under load. Determine which before trusting the gate.
2. `ScratchLabWatch` has no `PrivacyInfo.xcprivacy`. Needs a file reference plus a Copy Bundle Resources entry in `project.pbxproj` - separate approval. Not a blocker today: no required-reason API is used in that target.
3. The remaining ASC items are all manual App Store Connect checks, listed in the audit section of the 2026-09-04 records - versioning against the existing app record, signing/profiles, the privacy questionnaire matching the empty `NSPrivacyCollectedDataTypes`, export compliance, watch app listing and screenshots, background-audio justification, and Mac App Store vs Developer ID distribution.

## Current continuation - Watch stop is fixed and hardware-confirmed; chase the relay ack latency next

Do not re-open the stop path. Session `1ce25396-…` proved it works: the Watch stopped in the same second the Mac asked (stop dispatched 03:39:30Z, Watch `endedAt` 03:39:30Z), and Karl confirmed he did not touch the Watch. The fail-closed ownership rule in `CaptureWatchStopPolicy.startMayHaveLeftWatchRecording(_:)` is what made that happen, because the start handshake had come back `failed`.

The open defect is **acknowledgement latency in the Mac -> iPhone -> Watch relay, roughly 5 s each way**. The Watch acknowledged the start at 03:39:15Z and it had not reached the Mac by 03:39:17Z; the Watch stopped at 03:39:30Z and the ack had not arrived by 03:39:35Z. Consequences per take: a spurious `watchSyncState: failed`, a spurious `watchStopOutcome: timedOut`, and about 3 s of needless watch lead-in caused by the Mac blocking on the start await.

Find where the time goes **before** changing any timeout. Widening `CaptureWatchStopPolicy` bounds without knowing the cause would hide the defect rather than fix it, and would also widen the validator's overrun thresholds, which are derived from it. Measure, do not assume: WCSession reachability when the Watch screen sleeps mid-take (likely, and the standard answer is an `HKWorkoutSession` to keep the app alive - that is a real design decision, not a tweak); the iPhone relay's SwiftUI `onChange` dispatch of `pendingWatchControlCommand`; and MultipeerConnectivity send latency Mac to iPhone. Instrument each boundary and get one measured run before proposing a fix.

Also worth one fresh export: the four alignment instants (`takeStartedAt`, `takeStopRequestedAt`, `watchCaptureStartedAt`, `watchCaptureEndedAt`) were added after the last capture, so no archive carries them yet. A new take should validate PASS with a lead-in warning and no overrun line.

Unchanged and still outstanding: the flaky `TimecodeRealtimeIngressRingTests.testConcurrentSPSCStressAccountsForEveryAttempt` makes `scripts/build.sh` non-deterministic, and the two App Store Connect Info.plist blockers (`CFBundleVersion` literal `20`, missing `NSAudioCaptureUsageDescription`) still need Karl's approval before anyone edits them.

## Current continuation - Mac Stop -> Watch stop landed in code; hardware proof is the next action

The Mac's Watch stop is fixed in source and unit-covered but **not proven on hardware**. Do not start new capture work until the physical run below is recorded.

What changed: `MacCaptureEngine` now owns the Watch stop instead of the Stop button. It grants ownership only on an acknowledged start with a complete `TakeIdentity`, dispatches exactly once per take keyed `sessionID:takeID`, and asks from every terminal path - `stopRoutineRecording`, `finalizeRoutineRecording` (which covers AVFoundation ending the take itself at `maxRecordedDuration`), `cancelPendingRoutineReservation`, and every abandoned-start guard. `CompanionCameraReceiver.requestWatchCaptureStop` is now `async` with acknowledgement, a 2.0 s timeout and one retry (`CaptureWatchStopPolicy`, 4.0 s ceiling). The Watch's handler is one `resolveControlCommand` driven by the pure `WatchMotionStopCommandResolver`: idempotent, and it refuses a stop naming a session or take it is not recording. Outcomes export as `watchStopOutcome` / `watchStopDetail` / `watchMotionTransferState`; `watch_source` and `watchSyncState` were not overloaded. `validate_session.py` now fails a Watch capture running more than 4.0 s past the take audio (warns past 2.0 s).

Do this next, in order:

1. Record one fresh Mac + Watch take. Press Stop on the **Mac only** - do not touch the Watch.
2. Export it and report, verbatim: the take audio duration; the Watch CSV's largest `elapsed_time`; the difference between them; `stopReason`, `watchSyncState`, `watchStopOutcome`, `watchStopDetail`, `watchMotionTransferState` from `manifests/session_metadata.json`; `watch_source` from the canonical manifest; and `validate_session.py`'s status with its full warning and error lists.
3. Pass requires: the Watch stopped on its own, the overrun is under 4.0 s, `watchStopOutcome` is `stopped`, `watchMotionTransferState` is `completed`, and the validator passes with no watch-overrun line.
4. Then once each, as separate takes: stop with the Watch out of range (expect `unreachable` or `timedOut` **and** a visible degraded status on the Mac - silent success is a failure), and cancel a count-in (expect the Watch to stop on its own).

Do not hand-edit any archive. If a run fails, keep the raw Watch CSV intact as evidence - the validator reports the overrun, it never truncates it.

Also outstanding, not actioned: the App Store Connect audit found two confirmed repository blockers, both Info.plist edits that `SOUL.md` puts behind explicit approval. `ScratchLabDesktop/Info.plist` hardcodes `CFBundleVersion` to `20` while `CURRENT_PROJECT_VERSION` is `21` for every target (iOS and macOS share bundle ID `com.machelpnz.scratchlab`, so they are one ASC record); the fix is `$(CURRENT_PROJECT_VERSION)`. And the same file has no `NSAudioCaptureUsageDescription`, which the `AudioHardwareCreateProcessTap` Direct Capture path in `MacCaptureEngine.swift:5105` needs. Ask Karl before touching either.

## Current continuation - use only canonical macOS app; physical waveform/Review smoke next

Use only `/Users/karlwatson/Downloads/ScratchLab/build/CodexProducts-macos-launch/Debug/ScratchLab.app`; it contains the current Review restoration, RANE-over-auto-mic Debug selection, mapped fader notation, and macOS AHHH sample-position waveform. Do not open another DerivedData or `CodexProducts-*` app.

Canonical UI verification already proves persisted session `0d2274b5-4b32-434b-ab18-ec931cae8e91` take 2 restores Baby Scratch and 33 strokes in Review. The macOS Capture preview now renders Figma component set `457:3817` at the camera bottom. Its PCM waveform is immutable per load, while the cyan playhead uses signed/unwrapped DVS or MIDI accumulation through the existing `PlatterSamplePositionProjection`; audio rendering/scheduling and the 5 ms cue tolerance were not changed. Figma documents iOS/macOS parity.

Focused RANE selection/Review restoration tests passed 3/3 twice. Waveform contract/projection tests passed 26/26 twice. The canonical macOS build succeeded and was visually checked in unloaded state. Next perform one physical RANE take: load AHHH, confirm the waveform appears, scratch across cue into `BEFORE START` and past the sample into `PAST END`, confirm audible/cyan alignment without wrapping, then stop, verify newest-take platter/crossfader/upfader notation in Review, and export. Record exact pass/fail evidence before any further production edit.

## Current continuation - Review latest-take and upfader notation fix validated; physical retest next

Physical session `8ad16543-5165-41e8-993d-1d00c1ce5fd8` retained healthy notation: take 1 has 33 movement events; take 2 has 71. The live Review window showed stale Take 1 while take 2 was newest. Take 2 captured 561 mapped crossfader CC8 events and derived 18 fader events, but its 125 CC28 channel-1 events were raw/unmapped despite a complete saved RANE mapping. Two ScratchLab binaries were running, including stale `build/CodexProducts-ios-save-tests`.

Source now rescans completed captures whenever Review is entered, persists crossfader/left-upfader/right-upfader identities from the active mapping, and derives each mapped fader stream independently into truthful Review notation. New tests passed 2/2 twice; surrounding regressions passed 49/49 per configured repetition; macOS, iOS Simulator with embedded Watch, and Watch Simulator builds succeeded. Existing sidecars were not mutated.

Next action is one fresh physical take after closing every ScratchLab process and launching only the validated product. Move platter, crossfader, and right upfader through clear on/off cuts. Review must select the new take, show platter notation, and show crossfader and `rightUpfader` evidence. Preserve the old sidecars as failure evidence.

## Prior continuation - standalone-only audio and export reliability validated; physical RC next

Karl explicitly removed the `External Serato` product choice because it confused users. Source now exposes standalone local AHHH only, defaults to `scratchLabStandalone`, migrates the legacy persisted `externalSerato` raw value, and removes ownership selectors/copy on iOS and macOS. Earlier handoff entries requiring External Serato smoke are historical and superseded. Preserve audio scheduling, RANE routing, signed/unwrapped sample-position projection, and the 5 ms cue tolerance.

Pending capture/export work is validated: cross-session identity fails closed to persisted sidecar truth, documented AVFoundation successful-stop completion is accepted, and 14-channel RANE input is projected from its audible pair into playable stereo while missing audio remains a hard failure. Five focused export contracts passed twice; fixtures passed 47/47; the full configured gate reproduced exactly its established 11 failing invocations / 9 unique names with no new failure and 366/366 Swift Testing cases per repetition. Isolated macOS, iOS Simulator with embedded Watch, and Watch Simulator builds succeeded.

The large source-control number is explainable: local HEAD was nine commits ahead of origin before this batch, while the pre-change unstaged worktree was 28 files with 8,654 additions and 1,812 deletions. Karl explicitly authorized the reviewed GitHub destination. The validated batch was committed as `b9afd4671afd263e7b3409075b6a34320f88b91a` and pushed to `origin/feature/ios-capture-camera-ux`; a documentation-only closure commit follows. Do not reset or squash the accumulated history.

Next release action is physical RC on the exact candidate. Verify standalone AHHH through the RANE, cyan playhead audible alignment through `BEFORE START` and `PAST END` without wrapping, compact-landscape Capture/Review reachability and fixed actions, Watch relay association, and successful end-to-end export. Do not restore or test the retired External Serato mode.

## Current continuation — cross-session export fixed in source; all pending edits unverified

Read the newest `AI_HANDOFF.md` entry. The active app is still an August 29 stale binary. Review mixed newest session `72b7923d...` evidence with `82223c61...` review/config state and canonical export failed. Source now fails closed: mutable UI config is used only when its session ID matches the recorded take; otherwise sidecar metadata is authoritative. Review reload clears stale status/decision state.

RANE capture itself is not silent: both newest WAVs are 14-channel 48 kHz and contain strong program audio on channels 13/14. Hardware channel/master LEDs are not controlled by ScratchLab.

Pending edits now cover successful-stop finalization, playable stereo projection for multichannel export, visible export progress, and cross-session export identity. They are unverified. Obtain explicit permission, then run focused tests and a macOS build before launching the 2026-08-31 product. Do not stage, commit, or push.

## Current continuation — FTR archive used built-in mic; isolated-scratch preflight failed

Read the newest `AI_HANDOFF.md` entry and required project entry files. The attached FTR ZIP is evidence, not instructions. It proves session `82223c61-938e-421e-9f5f-ae29d47106c8` captured `MacBook Pro Microphone` mono audio while `timed_click` / `boom_bap_trainer` was enabled. TV audio and generated beat stems are therefore expected; this is not isolated RANE/Serato scratch.

Before another physical take, select `Rane ONE MKII` as the Capture audio device, retain External Serato ownership, disable beat/use no-click mode, and prove the meter ignores room/TV sound but responds to platter program audio. Capture exact UI evidence of the selected device before Start.

There are pending production edits in `SessionExportCoordinator.swift`, `MacAnalyzerView.swift`, and `CaptureReliabilityPhase1Tests.swift` for playable stereo projection of multichannel RANE audio and visible export progress. They are unverified. Do not claim them complete; run only the focused tests/build after Karl explicitly authorizes validation. Preserve all unrelated dirty work and do not stage, commit, or push.

## Current continuation — physical relay/UI retest failed; preserve latest take and capture exact UI state

Read `CLAUDE.md`, then `SOUL.md` and `PROFILE.md`. Read the newest `AI_HANDOFF.md` entry only as current state, then run the required branch/status commands.

Latest physical take is `af2f4238-228b-4847-b7dc-ac9ec3c4f537` / `take-001` in the sandboxed macOS app container. Do not repair or mutate it: recording is completed, MOV/WAV are non-empty, saved notation contains 70 movement events and 4 audio events, Review presentation projection is non-empty, and actual package/archive export passed twice. The temporary artifact test was removed.

The physical flow still failed in two user-visible ways. First, Watch stopped but the sidecar is `watchSyncState: timedOut` with no linked motion filename and no new relayed artifact. Second, notation was visible live but the user saw none in Review and could not export through the UI. Re-scan or relaunch, open Review, expand `Technical evidence & diagnostics`, and retry `Save ZIP...`. Capture the exact primary comparison state, captured-evidence state, export status text, and any red validation issue before editing production code. Backend export is already proven; focus on state refresh/presentation and relay association.

Preserve the narrow AVFoundation successful-stop fix, shared `ScratchAudioOwnershipMode`, and signed/unwrapped `PlatterSamplePositionProjection` behavior. Do not stage, commit, or push without explicit approval.

## Current continuation — macOS stop/export fixed; recovered take verified; Watch relay retest next

Read `CLAUDE.md`, then `SOUL.md` and `PROFILE.md`. Read the latest entry in `AI_HANDOFF.md`; older entries are reference only. Run `git status --short --branch` and `git rev-parse HEAD origin/feature/ios-capture-camera-ux` before work.

The macOS normal-stop export defect is fixed narrowly in `ScratchLabDesktop/Services/MacCaptureEngine.swift`: accept only an AVFoundation completion error with `AVErrorRecordingSuccessfullyFinishedKey == true` as a successful stop; all other errors remain fatal. Three permanent focused tests in `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift` passed 3/3 twice. The affected take `0c813395-28b1-42d6-9061-e2399c312a1f` was media-validated, audit-preservingly recovered, and passed actual package/archive creation twice with 4,833,280 scratch-audio frames exported. Do not broaden or undo this behavior.

Next action is one short physical Mac-led Watch relay take, not more production code. Keep ScratchLab open on iPhone with relay connected and Watch reachable. Start only from macOS and confirm Watch acknowledgment. Stop only from macOS: the Watch should stop automatically; manual Watch Stop is recovery only. Confirm the new sidecar has linked motion and a successful Watch sync state, then export. If it fails, capture exact Mac/iPhone/Watch UI state and the new sidecar before considering code changes.

Preserve `ScratchAudioOwnershipMode`: External Serato is the safe default and blocks/unloads all local AHHH routes while capture still writes truthful export audio; ScratchLab Standalone retains local AHHH. Preserve `PlatterSamplePositionProjection` as signed/unwrapped UI-only projection with 5 ms cue tolerance; renderer/audio scheduling remain authoritative. A7/A8/A9 and remaining physical RC checks are still open. Do not stage, commit, or push without explicit approval.

## Current continuation — macOS mapping resolved; A7 unconfirmed; RC matrix INCOMPLETE (Cases 4-8)

### 2026-08-30 (latest) — macOS upfaders + hot cues working; A8/A9 open; A7 still unconfirmed

**If macOS upfaders/hot cues stop working again: re-select the MIDI source first.** Refresh MIDI, then explicitly pick "Rane ONE MKII". It is a load/selection problem, not a mapping problem — the verified 11-control mapping persists correctly to disk. Symptom check: `midiMappingDeviceSummary` reading "No saved mapping for this device yet" or "1 control mapped" while the on-disk file has 11.

**Why the crossfader misleads:** it persists separately via the legacy `crossfaderCCMapping` / `persistedCrossfaderMapping` path, so it keeps working even when `currentMIDIDeviceMapping` is nil and every upfader/hot-cue dispatch is dead.

#### New open anomalies (neither fixed)
- **A8** — `MIDILearnedMappingStore.fileURL(for:)` accepts an empty device identifier, producing a file literally named `.json` (`deviceIdentifier: ""`, `deviceName: "Not Connected"`, crossfader only). It loads as if it were a real device. Fix: reject empty identifiers on both save and load.
- **A9** — `MIDILearnedMappingStore.save` uses `try?` on encode and write, so a failed save reports success. Contrast `loadOrThrow`, which surfaces errors on purpose.

#### A7 — still OPEN, likely explained but unconfirmed
A7 (RANE not playing AHHH; CH 3/4 silent) was reported while the macOS build had **no Audio-ownership picker at all** — that control is uncommitted work absent from `HEAD` (`git log -S "scratch-audio-ownership"` finds no commit adding it). With no way to leave `defaultMode = .externalSerato`, which blocks and unloads every local AHHH route, silence was correct behaviour. The picker renders after a full relaunch. **Karl has not confirmed AHHH is audible yet — ask him before closing A7.** Path: Advanced -> MIDI & fader -> "MIDI Monitor" card -> expand "Mixer & Hot-Cue Mapping" -> "Audio ownership" picker; set "ScratchLab AHHH", then press "Apply mapping + load AHHH".

### 2026-08-30 (later) — START HERE: A7 RANE AHHH silent; macOS ring fills camera view

**Branch** `feature/ios-capture-camera-ux`, **HEAD `7761c09f`**. Nothing committed, staged, or pushed. Five files modified this session on top of 25 pre-existing dirty files:
`CaptureCore.swift`, `iOSMIDIManager.swift`, `CaptureReliabilityPhase1Tests.swift`, `CameraNotationOverlayCalibration.swift`, `CameraNotationOverlayTests.swift`.
Do not commit, stage, push, clean, or revert without Karl's explicit approval. Preserve the other dirty files and the untracked `ScratchLabDesktopTests/CalibrationCameraOverlayTests.swift.plist`.

#### 1. A7 — RANE not playing AHHH (OPEN, highest priority)
Karl: "rane not playing ahh now". **Regression against Case 3**, which passed earlier the same day (AHHH audible, smooth, right-upfader controlled, crossfader cutting).

His 14 ch @ 48 kHz / 72192-frame analysis, tool verdict "no pair looks like program audio":
- CH 1/2, 3/4, 5/6 at a noise floor (-98 to -115 dBFS RMS) — **CH 3/4 is the established AHHH right-deck route and is silent**.
- CH 7/8, 9/10, 11/12 true `-inf`.
- CH 13/14 the only signal: R -4.8 dBFS RMS / **-0.0 dBFS peak**; L flagged `dcHeavy`, DC **-0.14937**.

**Work these in order, and do not assume a code defect before step 3 is answered:**
1. Ask Karl **which app** — iOS or macOS? He had just relaunched the rebuilt macOS app.
2. Ask whether the **AHHH sample is loaded** — the surface says `"Standalone audio enabled — load AHHH to arm the platter."` when it is not.
3. Ask what **`ScratchAudioOwnershipMode`** reads. If **External Serato**, silent AHHH is **correct by design** — that mode blocks and unloads every local AHHH route, and a relaunch landing on the safe default fully explains the symptom. Rule this in or out before investigating anything else.
4. Establish whether the measurement is **input-side or output-side**.
5. Separately explain the **DC offset -0.14937** on CH 13 L. Anomalous regardless of the AHHH question; do not fold it into A7's root cause without evidence.

Assessed as **not plausibly caused by this session's changes** — reasoning, not proof, so keep it in scope if evidence points back:
- `deriveDetectedNotationFaderEvents` (segmentation + 0.25/0.25 cut gate) is a pure notation derivation, no audio path.
- `CameraNotationOverlayCalibration` is a macOS UI default.
- `iOSMIDIManager` `.upfader` is the only edit near audio. Re-inspected after the report: the new capture block sits strictly between the `left/rightUpfaderMIDIValue` assignment and the gain routing; `playbackEngine.setRightUpfaderGain(...)` branches are byte-for-byte unchanged; `setCrossfaderPosition` untouched.

#### 2. macOS notation ring — done, needs Karl's eye
`platterRadius` default 0.35 -> 0.5 fills the camera view. **Karl must press Reset** in the calibration controls — his persisted `scratchlab.mac.cameraOverlay.platterRadius` overrides the new default, so without Reset it looks unchanged. At exactly 0.5 the ring touches the shorter edges and the guide stroke's outer half may read as clipped; **0.48** is the one-number fix if he dislikes it.

#### 3. Hardware confirmations still never given by Karl
- **iOS build 2760** on `K`: do ~3/4 of closes now draw ticks, and **does any tick appear where he did NOT cut**? That false-positive question is the one that matters — the cut gate was deliberately widened.
- **macOS** (rebuilt 16:36 and 20:12): a fresh take should show ~44 fader events / ~31 drawn, up from 0.
- **Upfader capture**: next iOS export should carry CC28 with `mappedControl: "leftUpfader"/"rightUpfader"`.

#### 4. Physical RC matrix — INCOMPLETE, do not mark complete
Case 1 PASS (selected on entry, not first-run default). Case 2 NOT TESTED (Serato does not run on iOS; needs Serato on a Mac via the RANE's second USB port with ownership held on External Serato for the whole take). Case 3 PASS by control authority, **but A7 now contradicts it — re-run Case 3**. Cases 4-8 NOT OBSERVED; resume at Case 4 (External re-select must **silence AND unload**; record those as two separate results).

#### 5. Requested, not started
macOS AHHH sample playhead display matching iOS (Karl's steer: **Figma first, then wire code**); upfader notation lane (capture + canonical model + renderer — architect slice, conflicts with the "renderer unchanged" invariant).

#### 6. Open anomalies
**A1** 8 s speaker pop, ScratchLab-owned (stops only on force-quit), root cause uninvestigated. **A2** `audioEvents: []` iOS-only. **A3** `audio_source` hardcoded `"serato"`. **A4** wrong doc comment on `ScratchAudioOwnershipMode`. **A7** above.

#### Rules and recipes
- Never infer a pass from launch, logs, screenshots, or source. Record Karl's exact words.
- Invariants: External Serato is the safe default and blocks/unloads every local AHHH route; Standalone retains local AHHH; `PlatterSamplePositionProjection` stays a pure signed/unwrapped UI projection with 5 ms cue tolerance; renderer and audio scheduling unchanged.
- Tests: `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`, symlink `ScratchLab.debug.dylib` into `ScratchLabDesktopTests.xctest/Contents/Frameworks/`, then `xcrun xctest -XCTest ScratchLabDesktopTests.<Class>/<test>`. Class membership is not obvious from line order — confirm with `nm` on the test binary. Running without the app host makes ~78 bundle-resource tests fail; capture a baseline before editing so regressions are separable.

### 2026-08-30 — RC smoke halted at Case 4; crossfader notation fixed, macOS rebuilt, verification pending

**Branch** `feature/ios-capture-camera-ux`, **HEAD `7761c09f`**. Nothing committed, staged, or pushed. Three files modified by this session on top of 25 pre-existing dirty files:
- `ScratchLab/Models/CaptureCore.swift` — monotonic-run segmentation in `deriveDetectedNotationFaderEvents`; cut gate 0.35/0.15 -> 0.25/0.25.
- `ScratchLab/MIDI/iOSMIDIManager.swift` — `capturedUpfaderMIDIEvents` evidence capture.
- `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift` — 4 new tests.

Do not commit, stage, push, clean, or revert without Karl's explicit approval. Preserve the other 24 dirty files and the untracked `ScratchLabDesktopTests/CalibrationCameraOverlayTests.swift.plist`.

#### Start here — hardware confirmation still outstanding
Both fixes are deployed but **not yet judged by Karl on hardware**.
1. **iOS** — build sequence **2760** is installed and launched on iPhone `K`. Ask Karl to cut, then report: do roughly three-quarters of closes now draw ticks, and **does any tick appear where he did not cut**? That false-positive question is the one that matters, because the cut gate was deliberately widened.
2. **macOS** — app rebuilt 2026-08-30 16:36. It must be **quit and relaunched**; the take Karl sent at 16:30 predates it. A fresh macOS take should yield ~44 fader events with ~31 drawing (predicted from his own raw data, which currently shows 1599 crossfader events and 0 fader events).
3. **Upfader capture** — the next iOS export should contain CC28 with `mappedControl: "leftUpfader"/"rightUpfader"`. It was entirely absent before.

#### Then resume the physical RC matrix — it is INCOMPLETE
Case 1 PASS, Case 2 NOT TESTED, Case 3 PASS (meters unavailable as evidence), **Cases 4-8 NOT OBSERVED**. Do not mark the matrix complete. Resume at:
- **Case 4** — while local AHHH is armed/playing, switching to External Serato must **immediately silence AND unload** it. Record silence and unload as two separate results; silenced-but-still-loaded is a partial pass at best.
- **Cases 5-6** — cyan playhead stays audibly aligned crossing the cue into BEFORE START, then enters PAST END without wrapping.
- **Cases 7-8** — Capture and Review through compact landscape widths; Review details scroll while Keep / Keep and Next / Retry / Discard stay fixed and reachable.
Case 2 needs Serato on a Mac via the RANE's second USB port, with ownership held on External Serato for the whole take. Serato does not run on iOS.

#### Rules that held this session and still apply
- Never infer a pass from launch, logs, screenshots, or source. Record Karl's exact words.
- `ScratchAudioOwnershipMode.externalSerato` is the safe default and must block/unload every local AHHH route.
- `PlatterSamplePositionProjection` stays a pure signed/unwrapped UI projection with the 5 ms cue tolerance.
- Renderer and audio scheduling remain authoritative and unchanged. The cut-gate fix deliberately did NOT touch `ScratchMotionRenderer`.
- Test-run recipe: `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`, symlink `ScratchLab.debug.dylib` into `ScratchLabDesktopTests.xctest/Contents/Frameworks/`, then `xcrun xctest -XCTest ScratchLabDesktopTests.<Class>/<test>`. Class membership is not obvious from line order — confirm with `nm` on the test binary.

#### Requested by Karl, not started
- macOS notation should fill the entire camera view (layout).
- macOS AHHH sample playhead display, matching iOS — Karl's steer is **Figma first, then wire code**.
- Upfader notation lane — spans capture + canonical model + renderer; architect slice, needs ChatGPT design.

#### Open anomalies (banked, none fixed)
**A1** 8 s speaker pop, ScratchLab-owned (stops only on force-quit), root cause uninvestigated. **A2** `audioEvents: []` on iOS only. **A3** `audio_source` hardcoded to `"serato"`. **A4** wrong doc comment on `ScratchAudioOwnershipMode`.

### 2026-08-30 — Physical RC smoke command reached launch twice

`./scripts/run-on-phone.sh 1F80398A-96C8-537A-B0EE-821E186918B9` now reaches full iOS build + install + launch on unlocked iPhone `K`.
- Retry evidence after Karl confirmed the phone was unlocked: exit `0` in about 8 seconds; `** BUILD SUCCEEDED **`; `com.machelpnz.scratchlab` installed at `file:///private/var/containers/Bundle/Application/EC170B5E-8286-466B-82C3-49C437724A1D/ScratchLab.app/` with database UUID `91F773FB-990B-4254-A7D6-CDD841AE068C`, sequence `2744`; application launch reported successful.
- The retry is a second build/install/launch pass only; the audible RANE and compact-landscape checks below still require exact manual pass/fail observations.
- Evidence:
  - Build success: `** BUILD SUCCEEDED **`
  - App lifecycle: `Installing com.machelpnz.scratchlab...` then `Launched application with com.machelpnz.scratchlab bundle identifier.`
- No automatic in-script functional checks exist; required RC behavior checks remain manual with RANE:
  - External Serato no-local AHHH
  - Standalone local AHHH load/play
  - External re-select silences armed sample
  - Cyan playhead behavior across `BEFORE START` / `PAST END` without wrap
  - Capture + Review compact landscape scroll/fixed action validation

### 2026-08-30 — Physical RC smoke run blocked by phone lock

`./scripts/run-on-phone.sh 1F80398A-96C8-537A-B0EE-821E186918B9` was started for the required on-device smoke.
- Result: **FAILED before install** (`Phone is locked. Unlock it and rerun.`)
- Lock evidence: `xcrun devicectl device info lockState --device 1F80398A-96C8-537A-B0EE-821E186918B9` returned `passcodeRequired: true`.
- No production smoke checks executed yet (build/install/action checks blocked).
- Remaining pass/fail cases still pending: External Serato zero local AHHH, Standalone local AHHH load/play, External re-select silences armed sample, cyan playhead boundary behavior, landscape Capture/Review actions fixed + scroll behavior, and exported artifact checks on unlocked hardware.


Read `CLAUDE.md`, then `SOUL.md` and `PROFILE.md`.
Read `AI_HANDOFF.md` — the top entry (2026-08-30) is current state; older branch histories below it are reference material only.
Run `git status --short --branch` and `git rev-parse HEAD origin/feature/ios-capture-camera-ux`.

Slices G and H are complete and checked in `TASKS.md`. Preserve shared `ScratchAudioOwnershipMode`: External Serato is the safe default and must block/unload every local AHHH route while capture still writes a truthful export audio artifact; ScratchLab Standalone retains local AHHH. Preserve `PlatterSamplePositionProjection` as the pure signed/unwrapped UI projection with the established 5 ms cue tolerance; renderer/audio scheduling remain authoritative and unchanged.

The next release-critical batch is **physical RC smoke only**; do not edit production code unless the smoke exposes a reproducible defect. On iPhone `K` with RANE connected: verify External Serato produces no local AHHH, Standalone loads/plays local AHHH, switching back to External silences an already armed sample, and the cyan playhead stays audibly aligned while crossing cue into `BEFORE START` and beyond the sample into `PAST END` without wrapping. Rotate Capture and Review through compact landscape widths; Export and every existing action must remain reachable, Review details must scroll, and Keep / Keep and Next / Retry / Discard must remain fixed. Record exact pass/fail evidence in all four workflow records.

Slice H verification: focused 26/26 twice; relevant regressions 60/60 twice; isolated iOS Simulator with Watch and explicit macOS builds succeeded; fixtures 47/47; full configured gate matched exactly 11 failing invocations / 9 unique names with no Slice H failure and 366/366 Swift Testing cases; protected hashes unchanged; `git diff --check` clean before record updates. Figma file `AgrnQXwRvkAKlORTQ2U25z` contains Before Start `493:262` and Past End `493:277` variants in component set `457:3817`. Nothing staged, committed, or pushed.

After this smoke, two release batches remain: final cross-platform RC audit/manual screenshots, then archive/distribution validation for the exact candidate. The unchecked capture-movement trace task is DEBUG-only evidence collection and is not an ASC blocker unless Karl elevates it.

---

Historical continuation material follows; its earlier statement that Slice G is next is superseded by the section above.

## Current state: production iOS saved-take notation/playback/detail COMPLETE

The first unchecked task is now **Capture-integrity Slice G: explicit audio-ownership mode (external Serato silent / standalone local AHHH)**. Work on exactly that one slice if authorized. Do not reopen the completed saved-take task and do not start Slice H.

The completed iOS surface uses the existing Slice F kept-session ledger as its sole source of saved takes. `GuidedCaptureSavedTakeDetail.load` resolves current-container artifact references, validates the real non-empty movie and sidecar plus their session/take/filename/completed associations, then derives display strokes with `CaptureCore.gestureRelativeRecordMovementEventsForPresentation`. Session Setup and Session Complete both expose `Review Saved Take(s)`; detail uses native `VideoPlayer` and the shared `ScratchPhraseChartView`; validation failure is visible and retryable without detaching the take. Preserve these invariants and do not introduce a second persistence layer, detector, or iOS-specific notation projection.

Task verification is complete: three focused tests passed twice; kept-ledger/export and shared-presentation regressions passed; isolated iOS Simulator, generic iOS device with Watch, and macOS test builds succeeded; fixtures 47/47; `git diff --check` clean. The configured Xcode full gate is currently blocked by an Xcode 27 sandboxed app-host hang when existing source-contract tests read repository files. A direct xctest fallback is resource/timing-incompatible and must not be treated as drift from the 11-failure / 9-name configured baseline.

## Capture-integrity Slice F: COMPLETE and PHYSICALLY APPROVED (2026-08-30; current, uncommitted)

The confirmed root cause below is now fixed in code. HEAD is still `7761c09f43`; nothing was reset, amended, staged, committed, or pushed; the four protected files and every other pre-existing dirty hunk are untouched. Changed: `ScratchLab/Models/CaptureCore.swift`, `ScratchLab/Views/CompanionCameraView.swift`, `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`, and the workflow records.

**Slice F is checked complete.** Karl explicitly approved closure after the current-build device retry, correct cancellation state, inspected restored multi-take export, and his operator-reported subsequent kept-take export.

What the fix is: the ledger's four take locations are `CaptureArtifactReference` — `.containerRelative(root:path:)` for app-owned artifacts, `.absolute` only for paths ScratchLab does not own — and resolving one to a `URL` requires a `CaptureContainerLocator` built for the container the app is running in now. JSON keys are unchanged; legacy absolute-URL ledgers still decode. `GuidedCaptureLedgerRebase` repairs a legacy ledger once at load by INTERPRETING each legacy path (locate its container-root segment; the remainder must already be a capture directory that artifact kind owns plus one file name) and proving the single candidate against the recovered sidecar — session ID, take ID, take number, sidecar file name, `mediaFileName`, the audio file's media-sibling basename, `linkedMotionFileName` — before accepting. Notation is generated from the sidecar, so proving the sidecar proves it. All four locations of a take move together or none do, through the store's existing atomic write-and-verify transaction.

Invariants to preserve. Do not turn the rebase into a directory scan or a basename match. Do not remove any rejection: path traversal, a doubly-named container root, a location outside its kind's directories, an unreadable sidecar, a wrong-session/take/number sidecar, an unnamed media/audio/Watch file, a genuinely missing file, and two takes resolving onto one file each keep the take unrepaired with a named reason in `lastRebaseReport`, leave the ledger byte-identical, and let Export keep reporting the real failure so it stays retryable. Do not let the repair adopt an unkept capture that merely completed. Keep persisting fail-closed (`containerOwnedAbsoluteSourceURL`) while loading still accepts absolute paths — that asymmetry is what lets a legacy ledger survive to be repaired. Do not weaken any export validator and do not fabricate a path or file.

Preserved from the prior turn — do not undo: staged BYTES are compared against the same documents re-encoded through the canonical encoder (`testSubSecondCreatedAtIsPreservedAndStagedMetadataIsCanonicalBytes` fails if that becomes a value comparison or `createdAt` is floored); `SessionExportValidationReason` / `SessionExportValidationFailure` still name the staged check that fired; retry/cancel semantics and the fail-closed platter-motion-without-recorded-movement check are unchanged.

Verification already done: 18/18 focused twice via `xcodebuild test-without-building` with per-method `-only-testing:` selectors (9 new + 9 existing kept-ledger/export), with teeth proved by mutation — 8 of the 9 new tests failed against a temporary restoration of the pre-fix behaviour, and the traversal test failed against a disabled path-safety check. `CaptureRecoveryPhase2CoreTests` 58/58, `ScratchLabNotationAndExportTests` 29/29, `CaptureMotionEvidenceTests` 13/13, `CaptureFinalizationMachineTests` 28/28, `GuidedCaptureReviewStateTests` 10/10, `SessionExportRoundTripTests` 1/1. Isolated iOS Simulator + macOS builds and macOS `build-for-testing` green; fixtures 47/47; `git diff --check` clean; full configured gate 3,166 tests / 49 skipped / 11 assertion failures across the established 9 unique names, plus 366/366 Swift Testing, in both configurations.

**Physical evidence.** An isolated signed build was upgrade-installed on iPhone `K` without erasing its container. The preserved `b5a93fd7-…` ledger migrated on load from stale absolute URLs to current-container relative references for the three kept takes 002/003/004. Retry Export reached the share sheet. The saved ZIP was inspected read-only: every kept take appears exactly once; source and packaged media/audio hashes agree; sidecars, notation, Watch evidence, manifests, metadata, review/replay, and take log validate; 17/17 manifest hashes match; no packaged file is zero bytes. Take 001 was completed but not kept and is correctly absent. Karl reports cancellation is correctly distinguished from failure and a later newly kept take remained exportable; the latter is operator evidence without a supplied second ZIP, accepted at Karl's explicit direction.

**Next task:** Production iOS saved-take notation, playback, and take-detail surface — the first unchecked implementation-ready item in `TASKS.md`. Keep it production/non-DEBUG, reuse the shared gesture-relative presentation, and do not reopen Slice F.

## Capture-integrity Slice F: the physical failure this fix addresses (2026-08-30; superseded by the section above)

Physical verification on iPhone `K` FAILED. No production code was changed in that turn; `DEV_LOG.md` / `TASKS.md` / `AI_HANDOFF.md` / this file were updated with the result. HEAD is still `7761c09f43`; the pre-existing dirty tree and the four protected files are untouched and unstaged; nothing committed or pushed.

Do not read either Slice F section below (the `createdAt` fix, or the earlier "COMPLETE" record) as a physical result. Slice F stays unchecked in `TASKS.md`.

Observed on device, no new take recorded:
1. The kept session did not present its takes as usable after the upgrade install/relaunch.
2. Retry Export did not reach the share sheet. On the freshly installed build it reports per take: "Take 002 video is missing. Retake it before export.", "Take take-002 is missing b5a93fd7-…_take002_camA.json.", "Take 002 audio is missing. Retake it before export.", "Take 003 video is missing. Retake it before export." The pre-existing build showed the opaque "This session has inconsistent metadata." for the same condition.

Confirmed root cause: `~/Library/Application Support/ScratchLab/guided-capture-kept-sessions.json` persists each take's `sourceMediaURL` / `sourceSidecarURL` / `sourceAudioURL` / `sourceWatchMotionURL` as absolute `file://` URLs containing the app Data-container UUID `B116F53B-B4D3-4C1F-805D-40722E98025D`. The device's current Data container has a different UUID, so those paths dangle. The media itself is intact — capture sidecars store only relative filenames, so local recovery still resolves the files. `CompanionCameraView` builds `SessionExportTake` from `keptTake.sourceMediaURL` / `sourceAudioURL` / `sourceSidecarURL` with no rebasing, and `SessionArchiveBuilder.packageValidationIssues` then fails `checkFileReady` / `fileExists` on the dead URLs. `packageValidationReport` maps "missing" to `SessionExportError.missingRequiredFiles`, so `validateStagedPackage` and the new `SessionExportValidationReason` path are never reached for this session — the sub-second-`createdAt` staged-bytes fix is neither implicated nor disproven.

Installed binary confirmed current: `ScratchLab.app/ScratchLab.debug.dylib` (built 09:16 from source last modified 08:56) contains all seven `SessionExportValidationReason` raw values, the "Export blocked: manifests/session_metadata.json did not match…" detail string, `guided-capture-kept-sessions.json`, and `sourceMediaURL`.

Not established: exactly when the Data-container UUID changed. Today's `devicectl` upgrade install preserved container contents (so it most likely changed at an earlier install cycle). Device logs and/or the original failing archive would settle whether the first "inconsistent metadata" failure was this same stale-path condition.

**Next action for Slice F is code, not another physical run.** Make `GuidedCaptureKeptSessionStore` / `GuidedCaptureKeptSession` resolve take artifacts against the current app container — store container-relative paths (or security-scoped bookmarks) and rebase on load — instead of persisting absolute Data-container URLs. Do not weaken the export validators to paper over missing files. Preserve the existing failed session's captures and the ledger. After the fix: rebuild with isolated paths, install as an upgrade, reopen the existing failed session, Retry Export must reach the share sheet, cancel once and confirm cancellation (not failure), then record and Keep a second take, export, and inspect the archive to prove both distinct takes are present exactly once. The separately scoped production iOS saved-take notation/playback/detail task remains open and must not be folded into F.

Preserved from the prior (still-unverified) `createdAt` fix — do not undo it while fixing the ledger: staged BYTES are compared against the same documents re-encoded through the canonical encoder; `testSubSecondCreatedAtIsPreservedAndStagedMetadataIsCanonicalBytes` fails if it is turned back into a value comparison or if `createdAt` is floored/mutated. `SessionExportValidationReason` / `SessionExportValidationFailure` name the staged check that fired via the existing `validationReport`; `SessionExportError`, its user message, and retry/cancel semantics are unchanged. Keep the fail-closed platter-motion-without-recorded-movement check strict.

## Capture-integrity Slice F: earlier COMPLETE record (2026-08-30; superseded by the section above)

Slice F adds one durable kept-session ledger and one fail-closed export boundary. Both Keep actions persist before showing success; ready/setup/completion retain an Export / Share route; later takes append to the same session; retry preserves staged media; cancellation is not failure; stale or impossible completion cannot fabricate Exported. Archive validation proves source and packaged media, audio, sidecars, notation, Watch/motion, all metadata/manifests/review/replay/log files, optional mixes/stems, and uniqueness across takes. Do not weaken strict local-session discovery back to `compactMap`/`try?`, and do not delete staged captures from Retry.

The final focused set passed 16/16 twice, including Slice F, affected export regressions, and legacy metadata-group compatibility. Isolated iOS Simulator/macOS builds and fixtures 47/47 passed. The final isolated broad gate retained exactly the established 11 assertion failures / 9 unique names, with no Slice F/export failure. Nothing staged, committed, or pushed. The next separately scoped product task remains production iOS saved-take notation/playback/detail; do not fold it back into F.

## Capture-integrity Slice E: COMPLETE (2026-08-30; current, uncommitted)

Started from committed HEAD `c0bb3babc1`; no prior commit was amended/reset/rebased. The dirty worktree remains intentional. Do not alter or stage `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, or `CalibrationCameraOverlayTests.swift.plist` without new scope.

Finalization is now one bounded, take-ID-scoped state machine. `CaptureFinalizationMachine` in `CaptureCore.swift` owns the single typed `CaptureFinalizationState`, scoped to `CaptureFinalizationTakeKey(sessionID:takeNumber:)`; it is pure and clock-free and returns an ordered effect list the view performs. `CaptureFinalizationBudget` states the 15s worst case (12s wait + exactly one 3s retry). `CaptureFinalizationDeadlineScheduler` is the only timer, and scheduling replaces the previous one.

This replaced six independent mechanisms; do not reintroduce any of them. The view's `finalizationWatchdog` task, the hardcoded `12_000_000_000` / `3_000_000_000` sleeps, and the store's `lastHandledRecordingID` are deleted. Do not add a second watchdog or a second "is saving" flag. Do not move the summary gate back to the end of `handleFinishedRecording` — it must refuse duplicate and foreign summaries BEFORE any side effect, which is what stopped a duplicate callback from re-persisting notation and falsely reporting the rendered AHHH audio missing. Do not branch on `CaptureStopSource`: the phone and Watch Stops must keep producing byte-identical effects, and the value is provenance only. Do not let `preserveStagedMedia` follow `presentRecoverableFailure`. Keep `mediaContainsAudio` returning `Bool?` with `nil` on timeout — returning `false` would downgrade a good take to `missingAudio` whenever an `AVAsset` open is merely slow. Keep the machine in `CaptureCore.swift`, which is in both targets and Foundation-only; a new file would need separate `project.pbxproj` approval and the iOS-only view file is unreachable from the macOS test target.

Verification is complete: `CaptureFinalizationMachineTests` 28/28 twice, Slice E source guards 7/7, `CaptureRecoveryPhase2CoreTests` 58/58 twice, the combined review/evidence/decoder/routing set 123/123 twice, the notation/export set 45 executed / 1 skipped / 0 failures twice, isolated iOS Simulator + iOS device (embedded Watch) + macOS `build-for-testing` green, fixtures 47/47, `git diff --check` clean.

Physical check PASSED on iPhone `K` (2026-08-30) against a signed build of the current source with the embedded Watch app. (1) Save Take froze the elapsed readout immediately and Review appeared. (2) Stop pressed inside the start race produced the iOS `Ready to keep` Review screen with Keep / Retry / Discard, and the take was kept and exported — this is the **deferred-stop branch (a)**, i.e. `stopRequestedWhileRecordingStarts` delivered the retained request from `didStartRecordingTo`. It is NOT the preservation-timeout branch; `preserveStagedMedia` → `presentRecoverableFailure` never ran and the 15s bound was never reached. Do not restate it as a timeout. (3) A single Watch tap started and a single Watch tap stopped the take with the phone's Capture screen foreground and the Watch showing Transfer Connected.

The supplied iOS export (session `b5a93fd7`) is healthy and complete: one 11s take, `recordingStatus: completed`, no error, 35 movement events, 9,572 mixer MIDI events, confidence 0.948, `watchSyncState: acknowledged`, real Watch CSV in the archive, full `take_allocated` → `recording_completed` → `notation_snapshot` → `watch_linked` audit trail.

**Production iOS saved-take notation/playback/detail remains OUTSTANDING** and is its own unchecked task in `TASKS.md`. A saved take cannot be reopened or played back on iOS: `TakeReviewView` renders no notation, `Take Detail` is macOS-only, and both iOS saved-notation surfaces are `#if DEBUG`. Do not implement it inside Slice D or Slice E, and do not drop the requirement.

Slice D's own physical approval is now RECORDED as passed (2026-08-30) — see the Slice D section below. Its checks were, by platform: **iOS** — live signed playhead (`BEFORE START` / `PAST END` without wrapping, playhead matching audible AHHH). **macOS** — live free-spin → catch → unequal push/pull → reversal, and saved Review plus Take Detail notation parity. The saved-surface check is macOS-only because those are the only production surfaces that render saved notation.

The next unchecked implementation-ready item is Slice F, discoverable export after every Keep action. Do not start it until the D/E commit separation is approved and performed — the working tree currently carries pre-existing WIP plus Slices B, C, D and E together, so a further slice on top makes the separation harder, not easier.

## Capture-integrity Slice D: COMPLETE (2026-08-29; superseded as "current" by Slice E above)

Started from committed HEAD `c0bb3babc1`; no prior commit was amended/reset/rebased. The dirty worktree remains intentional. Do not alter or stage `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, or `CalibrationCameraOverlayTests.swift.plist` without new scope.

Gesture notation and raw sample travel now have explicit separate semantics. `PlatterCoordinateSemantics.gestureRelativeNotation` rebases every decoder-committed movement run locally while retaining signed direction, timestamps, displacement/speed, and real excursion. `samplePosition` remains exact signed/unwrapped travel from the hot-cue origin for audio and the waveform playhead. All live/saved iOS and macOS notation paths use the shared presentation semantics. Do not reintroduce accumulated motor phase into notation or clamp/wrap the waveform to make the graph look flatter.

Replacement iOS/macOS hardware captures exposed a display-only follow-up: ordinary 0.08–0.22-revolution scratches were too small under the former one-revolution scale and macOS 118-point canvas. Controller notation now uses a fixed quarter-revolution full-scale projection shared across renderers, and macOS live notation fills the camera stage. Thus 0.10 / 0.20 / 0.25 revolution displays as 40% / 80% / 100% lane travel. At or above 0.25 revolution the display intentionally reaches the rail, but the physical event/export remains exact and unbounded. Do not replace this fixed frame with per-take auto-fit, which would retroactively move committed strokes. Camera endpoint dots must continue to apply a reduced radius only once.

The existing controller decoder remains the only scratch boundary/noise authority. Canonical `recordMovementEvents` still feed scoring/export unchanged; raw fusion-dropped or fusion-split events are presentation-only. Preserve the iOS decoder-boundary anchor and motor-release lookbehind, which keep work bounded without mutating a visible committed stroke or losing the first reversal. Preserve direct saved mini-rendering; round-tripping these strokes through `ScratchNotation.detectedPreview` loses direction and unequal excursion.

Verification is complete: focused 147/147 twice, relevant regressions + saved-Review 88/88 twice, fixtures 47/47, and isolated macOS plus generic iOS Simulator/embedded-Watch builds green. Both broad configured passes ran 3,111 XCTest cases / 49 skipped with exactly the established 11 assertion failures / identical 9-name set; all 366 Swift Testing cases passed in each. **Physical approval RECORDED (Karl, 2026-08-30): all three refreshed checks passed.** macOS free-spin did not accumulate into the next gesture's baseline; catch, unequal push/pull, and reversal direction displayed correctly with completed strokes remaining fixed; macOS saved Review and Take Detail preserved stroke order, direction, timing, and relative excursion; iOS playhead crossed `BEFORE START` and `PAST END` without wrapping and stayed synchronized with audible AHHH. The macOS export corroborates this but is not itself the approval.

Slice E is now implemented (see the section above). Do not reopen D without new physical/test evidence.

## Standalone test isolation: COMPLETE (2026-08-29; uncommitted)

`PlatterTestSampleLoadTests` now resolves `dvs_ahhh` from an explicitly injected app-bundle resource root. `MIDILearnEngineTests` now injects a unique `UserDefaults` suite that is cleared before and after each test; production defaults remain unchanged. Both suites pass standalone twice and inside the full desktop plan. The full gate remains at the 11-failure / 9-unique-name baseline, with neither suite failing. Do not reopen this slice unless new evidence appears.

## RANE right-deck routing: FIXED and physically approved (2026-08-29; current, uncommitted)

**Settled hardware truth — do not re-derive or re-test from scratch.** RANE ONE MKII exposes **10** USB output channels. **1/2 = left deck, 3/4 = right deck, 13/14 = master** (never route deck playback there). Karl physically approved: AHHH on the right deck, only the right meter, right upfader/crossfader control, master normal, DVS unaffected.

Root cause was a hardcoded `>= 14` channel gate against a 10-output device, so the channel map was never installed and playback fell to the first pair (1/2, left deck). The pair index `2` was correct all along. **`AVAudioSession` is not at fault** — it grants 10/10; `options=8` is `.defaultToSpeaker` alone and does not block multichannel USB. Do not change category/mode/options.

Invariants to preserve: `minimumRequiredOutputChannels` stays **derived** from the pair, never a device size; the engine must keep reading back the applied map and verifying it before playback; a recognized RANE that cannot reach the right deck must keep **throwing and refusing to play** — reinstating a stereo fallback recreates the original bug; non-RANE routes stay ordinary stereo; DVS input stays 3/4 in its independent namespace.

`RanePlaybackRoutingPolicy` lives in `DVSHardwareProfile.swift` specifically because that file is in **both** targets and Foundation-only — the engine is iOS-target-only and unreachable from the macOS test target. Do not move it without checking target membership.

**Do not reintroduce source-string routing tests.** The old one asserted `"let raneOutputPairStartIndex = 2"` and passed throughout the entire bug.

**Test-isolation cleanup is complete.** See the current section above.

Full-gate baseline is now **11 failures / 9 unique names** (post resource-restore). Compare against that, not the older 15/13.

## Capture-integrity batch: Slices A+B+C+D landed, E–H open (2026-08-29)

**Slice D (current, uncommitted).** Gesture notation is locally rebased per decoder movement run; sample position remains raw signed/unwrapped travel from hot cue. Live and saved iOS/macOS presentation uses the shared projection, with fixed quarter-revolution full-scale controller display geometry and a full-height macOS live stage. Scoring, export evidence, and audio scheduling remain canonical/unchanged. Display saturation at or above 0.25 revolution is presentation-only and awaits explicit physical approval.

Keep these invariants: decoder reversal/run boundaries and noise gates stay the only scratch detector; completed presentation strokes are immutable; fusion-dropped decoder-valid runs remain presentation-only; the waveform/playback path keeps raw signed unwrapped travel and can show `BEFORE START` / `PAST END`; and no notation fix may alter scoring/export evidence or audio scheduling.

**Resource deletions were restored**, dropping the full-gate baseline to **11 failures / 9 unique names**. Use that as the comparison point, not the older 15/13.

**Historical test-isolation fragility is resolved.** Do not schedule another cleanup without a new reproduction.

## Capture-integrity batch: Slices A+B landed (2026-08-29; superseded by the section above)

Karl's ten-requirement capture-integrity prompt was decomposed into eight slices (A–H) recorded at the top of `TASKS.md`. **Slices A and B are implemented.** Slice A is in Codex checkpoint `089965f4`; Slice B is uncommitted in the working tree. Do not attempt the remaining slices as one batch — the repository still carries a pre-existing dirty WIP baseline, and a single combined diff makes new regressions indistinguishable from it.

**Slice B (current, uncommitted).** Every review label is now a projection of one `GuidedCaptureReviewState` (typed `CaptureReviewReadiness` + `CaptureMotionStatus`). Do not reintroduce `operatorMessage` / `syncStatus` / `motionStatusTitle` / `motionPresent` as independently stored properties on `CaptureReview`, and do not "de-duplicate" `syncStatus` restating the motion wording — that repetition is what guarantees the two labels cannot contradict each other. `"Motion pending"` is gone and two exhaustive-input tests assert it is unreachable. A shared `CaptureMotionEvidencePresenter` renders the Platter/Fader/Watch rows; DVS stays out until a real feed exists.

**Next slice is C (crossfader evidence persistence).** `iOSMIDIManager.receive`'s `.crossfader` case only appends to `capturedCrossfaderMIDIEvents` when `currentMapping?.control(for: .crossfader)` is non-nil, so an unmapped controller persists zero events while Capture Hardware Setup still displays the `"Raw ch 15 · CC 8"` fallback string as though it were configured. Verify against the learned mapping rather than hardcoding a second one, bound events to the take window, and check sidecar/review/export parity. Slice B already presents the count truthfully, so C only has to make the capture real.

**A physical check is still outstanding from Slice A:** one short RANE take with no Watch paired, confirming Review reports motion present and the export validates. Slice B additionally changed user-visible copy — a motionless take now reads `Retake recommended` — which is worth confirming on device at the same time.

Slice A added a shared, domain-only `CaptureMotionEvidence` + `CaptureMotionEvidenceResolver` in `CaptureCore`, and all three motion-presence sites (`CompanionCameraView.handleFinishedRecording`, that file's export-package builder, and `SessionExportCoordinator`'s recovery builder) now resolve through it from the same persisted `sidecar.detectedNotation`. Controller platter movement counts as motion with no Watch paired; a forward-only powered platter does not, because the discriminator is a decoded reversal reusing the existing decoder noise gates. Fader events never substitute for platter movement. DVS is `.unsupported` and must stay that way until a genuine timecode feed exists at take finalization — do not let it report presence.

Export validation is now source-aware through the additive optional `SessionExportTake.motionSources`; `nil` deliberately preserves the historical Watch-only behaviour for legacy callers and fixtures. There is no on-disk export-schema change. Do not "simplify" `claimsWatchBackedMotion` / `claimsMotionWithoutAnySource` back into a bare `motionPresent == true` check — that reinstates the gate that hard-throws on controller-only takes.

**Next action is a physical check, not more code:** one short RANE take with no Watch paired, confirming Review reports motion present and the exported package validates. After that, Slice B is the natural continuation — remove the hardcoded `"Ready to keep"` literal (two sites in `CompanionCameraView.swift`) and collapse `GuidedCaptureReviewStateResolver`'s two-strings-for-one-false-input shape, which is why a motionless take can still show `Motion pending` and `Motion Missing` together.

**AHHH/Serato direction, decided 2026-08-29:** Karl chose to add an explicit audio-ownership mode (external Serato = ScratchLab silent; standalone = current local AHHH retained) rather than delete local AHHH. This supersedes — it does not erase — the "restore local AHHH" gate recorded further down this file. Do not remove the existing Load AHHH controls; add the mode alongside them in Slice G.

## Latest physical iOS take evidence + macOS AHHH state (2026-08-29; supersedes output-13/14 notes below)

iOS ScratchLab right-deck stereo now uses physical outputs 3/4 after the RANE hardware meter proved 13/14 lit the wrong deck. DVS remains on physical inputs 3/4; those input/output channel namespaces do not conflict. Active takes now own raw crossfader MIDI, derived cuts, detected notation, Watch request/reply evidence, and a scratch WAV whose basename matches the movie/sidecar for reliable Review/recovery/export.

Watch Start must only be enabled when the iPhone is live-reachable. The iPhone Capture/System Check screen must be foreground and ready and the Watch must display Transfer Connected; paired is not sufficient and background camera autostart is not supported. The signed phone/embedded-Watch build installed on iPhone `K`; unlock/open it for the physical smoke.

macOS notation is independent of audio. `Apply mapping + load AHHH` intentionally arms silently; the new `Test AHHH audio` action is always available in Mixer & Hot Cue Mapping, explicitly plays a short excerpt of exact `dvs_ahhh`, and leaves it armed. The latest clean signed app is open at `build/CodexProducts-macos-ahhh-final/Debug/ScratchLab.app` (PID 20154), with source/bundle AHHH SHA-256 `4c932a6fd6b26af317eaa7850ca8e11626c5a41e8d382561dcfac81e95949791`. Focused tests and builds pass. The final broad rerun passed fixtures 47/47, then retained the known missing Coach Demo failures and lost the sandboxed runner/IDE helper connection before the next export test completed; do not call that incomplete test a new regression. Nothing committed or pushed.

## Latest AHHH waveform/playhead state (2026-08-29)

Figma file `AgrnQXwRvkAKlORTQ2U25z` contains `SamplePositionWaveform` component set `457:3817` and eight audited phone/pad landscape placements. Production now renders the exact approved AHHH sample envelope plus the actual renderer-synchronized playhead at the bottom of active iPhone/iPad landscape Practice and Capture. Preserve the transparent surface, independent cue marker, START/MID/END labels, and amber BEFORE START / PAST END warnings. The renderer snapshot is deliberately unwrapped so negative travel does not jump visually to sample end.

Focused coverage passed twice; fixtures passed 47/47; iOS, macOS, and watchOS builds are green. A fresh signed build with the embedded Watch companion is installed and launched on physical iPhone `K`. The full repository script still exits 65 on the known dirty-WIP resource/UI/MIDI/DVS/profile baseline; the waveform test passes. Next manual action is a physical RANE eyes-and-ears check comparing the cyan playhead to audible AHHH at cue and both bounds. This is a sample-position aid; target notation remains the movement-size reference. Nothing committed or pushed.

## Latest audited Figma + Save/Watch/RANE state (2026-08-29)

Figma file `AgrnQXwRvkAKlORTQ2U25z` has been fully re-audited: 44 direct notation surfaces, five canonical variants, 17 instances, and the macOS overlay/preview set have zero structural failures, zero stale demo metadata, and zero notation/control intersections. Targets use the current BBB 79 BPM 32-movement demo; performance examples are independent; notation surfaces are transparent; false click/turnaround markers are removed; open-fader rails remain. Prototype A, iPhone Portrait Entry + Practice, iPhone/iPad landscape Practice/Capture, and macOS Copy are included. Do not restore old 89 BPM labels, the short target, dark notation backing, or click-like turnaround anchors.

Production is aligned: transparent canonical notation panel/lane, taller unbacked macOS Copy overlay, direct iOS recorder-finalization completion (including Stop-during-start), Watch-to-phone Start/Stop commands with truthful replies, and RANE ScratchLab playback on physical outputs 13/14 while DVS remains on 3/4. The current signed iOS build is installed/launched on iPhone `K`, and the current macOS build is launched. The Watch companion is embedded; a direct Watch install failed because the Watch rejected the Mac Bluetooth pairing (CoreDevice 4000 / remote pairing 1035), not because of a build error.

Focused tests pass 9/9, fixtures 47/47, and isolated macOS/iOS Simulator builds are green. `scripts/build.sh all` exits 65 on the existing dirty-WIP missing-resource/UI/profile/DVS/demo baseline after reaching the broad 366-test plan; do not misattribute those failures to this slice. Next physical checks: Save/Export one short iPhone take, start/stop while Capture is open from Watch, confirm RANE output 13/14, and approve notation on phone/iPad/macOS. Nothing committed or pushed.

## Latest iOS Save Take repair (2026-08-29)

The physical-iPhone Saving hang was fixed and deployed. The original media was not lost: the inspected take has a completed sidecar and a 10.4-second HEVC/AAC movie in `Documents/CompanionCaptures`. Saving now freezes elapsed time at Stop, consumes the matching finalized-summary publication, reaches Review before optional audio inspection, and has a bounded stop-retry/recovery watchdog. Immersive landscape now uses one safe-area-aware local control row instead of overlapping native and custom chrome. `ahhh`/`dvs_ahhh` both resolve to the approved `VirtualPlatter/ahhh.wav` because a different legacy flattened copy is also present in the bundle.

Current signed source was installed and launched on iPhone `K`. Focused tests pass 3/3; fixtures pass 47/47. The broad macOS test plan hung after starting `AutoCutVisualPlaybackTests` and was interrupted after 92 seconds, leaving no runner process. Next manual action: record one short take, press Save Take, confirm the timer freezes and Review appears, then Keep/Export. Preserve the older staged take and all unrelated dirty WIP. Nothing committed or pushed.

## Latest device deployment (2026-08-29)

The current source was built, installed, and launched on physical iPhone `K` (iPhone 16 Pro Max, iOS 27.0), bundle `com.machelpnz.scratchlab`. The packaged platter AHHH exactly matches SHA-256 `4c932a6fd6b26af317eaa7850ca8e11626c5a41e8d382561dcfac81e95949791`. A fresh arm64 macOS app was also built and launched from the isolated `build/CodexProducts-macos-launch/Debug/ScratchLab.app`; its BBB demo exactly matches SHA-256 `220a2d74568b91d580ab5945ad77d9f0acc74a19d5e839dd2ae8e01c3dbee74f`. Both used isolated build databases, so the prior shared-Xcode lock did not recur. Physical landscape/RANE audio and macOS subjective alignment smokes remain.

## Latest iOS landscape + HC1 state (2026-08-29; supersedes older read-only/listen-only notes)

All active iPhone/iPad landscape Practice and Capture notation overlays now fill the available safe workspace; do not restore the old 144–184-point height cap. Compact iPhone Home uses a horizontal minimum-width carousel, and compact System Check details wrap. Advanced MIDI is live and editable: source selection, verified RANE mapping, HC1 learn/relearn, `dvs_ahhh` assignment, and explicit Load AHHH are all connected to production models. iOS HC1 is deliberately not gated by ScratchLab transport because Serato can own transport externally. Pressing HC1/Load arms the sample; right-platter movement produces audio. Keep the RANE channel-assign switch fully left.

Figma file `AgrnQXwRvkAKlORTQ2U25z` was updated before SwiftUI: Advanced `416:4202`, iPad Capture HUD `360:71`, active iPad Practice `281:969` / HUD `436:2421`, plus the iPhone landscape live HUD set. Isolated iOS Simulator build and 3/3 resolver tests are green; fixtures pass 47/47. Physical iPad landscape and RANE audio smoke remain. Nothing was committed or pushed.

## Latest macOS Watch notation repair (2026-08-29)

Practice Ready/Watch/Listen now renders `ScratchNotation.babyScratchDemo`, the exact 32-stroke timeline paired with the 16.048-second BBB `baby_noBeat.wav`. `MacAnalyzerView` reads `demoModeController.demoPlayer.sampledPlaybackTime()` directly and clamps at the last movement during the two-second tail; do not reintroduce the old 4.700-second modulo loop into Watch. Copy/scoring/review intentionally retain the short canonical `ScratchNotation.babyScratch` cycle.

`ScratchPhraseChartView` no longer adds a decorative diamond at every platter reversal because that symbol falsely reads as a crossfader click. Keep direction legible through the continuous path, nodes, and chevrons. The fader transition diamond inside `drawTargetFaderLane` remains valid and must only appear when fader state actually changes. Isolated macOS build/tests are green (11 Watch/live tests twice, 61 demo-notation tests, and three exact audio/motion checks twice). Manual eyes-and-ears playback approval remains.

For CLI verification while Xcode is open, use isolated `-derivedDataPath`, `OBJROOT`, `SYMROOT`, and `SHARED_PRECOMPS_DIR`; do not share Xcode's build database. The stale generated `ScratchLabDesktop-primary.priors` file has already been removed.

## Latest iOS AHHH decision (2026-08-29; supersedes the no-AHHH paragraph below)

Karl explicitly asked to restore local AHHH after Hot Cue 1 was silent. Production Practice Controller Setup and Capture Hardware Setup now have explicit `Load AHHH` buttons with truthful status, the verified Rane mapping assigns local ScratchLab samples, and older sampleless Rane mappings repair missing defaults without losing learned data. The correct platter sample is `ScratchLab/Resources/VirtualPlatter/ahhh.wav` (1.047415 seconds; Git blob `2895220755832dff90d940789533bc7111041fb6`), not the longer padded `ScratchSamples/ahhh.wav`. Do not remove these controls based on the older Serato-companion note unless Karl changes direction again.

## Latest build-resource repair (2026-08-29)

The four tracked Scratch Sample WAVs, `ScratchLabDesktop/AppIcon.icns`, and `Resources/Coach/Coach.usdz` were restored byte-for-byte from the intact `ScratchLab-fix-stable-ios-audio-session-activation` checkout. Their Git blobs match the index. macOS and generic iOS Simulator builds now succeed, and capture fixtures pass 47/47. Do not delete these six files or remove their valid resource references. Other deleted WIP resources were deliberately left untouched; the broad desktop test plan still detects missing `chirpflare_noBeat.wav`, so do not claim the full test gate is green or restore more files without explicit scope.

## Latest completed iOS integration slice (2026-08-29)

The existing adaptive Home/sidebar views are now connected to implemented iOS flows; compact iOS exposes Home/Practice/Capture/Review/Advanced, and regular-width landscape iPad uses the persistent sidebar. Baby Demo routes to the current BBB audio/motion pair at 79 BPM instead of the old reel. Cold launch now uses a compact 240×240 static logo, and `AppLaunchContainerView` shows the SwiftUI splash before heavyweight root services are constructed; a fresh iPhone 17 Pro simulator showed the logo at 0.5 seconds and Home at 7.5 seconds. Device/simulator builds and 47/47 capture fixtures passed. The new launch contracts compile, but normal source reads are blocked by the Downloads sandbox and the unsandboxed retry stops on the unrelated deleted `Coach.usdz` WIP resource. Production iOS RANE mapping is listen-only for hot-cue pads and no longer exposes or invokes local AHHH loading; manual learning stays sampleless, and old saved pad sample IDs are removed on load without discarding learned MIDI/calibration data. Serato remains on the Mac/PC, while iPhone/iPad is the ScratchLab companion. Do not reintroduce AHHH loading to production Practice/Capture; the DEBUG Virtual Platter owns the standalone local test.

No current Figma context was available because saved node `AgrnQXwRvkAKlORTQ2U25z` / `38:23` is deleted. If Karl supplies a current node-specific Figma URL, use it to audit exact latest-frame parity. Do not claim pixel parity without it. NDI/breakout overlay output and the proposed iOS timecode test side app are still separate, unimplemented tasks.

## Most recent completed slice (2026-08-29)

Karl's latest BBB 79 BPM scratch-only take is now the app's bundled Baby Scratch demo. `baby_noBeat.wav` contains 16 clean forward/backward cycles with two-second lead/tail, and `baby_scratch_strokes.json` contains the matching 32-stroke live timing; the desktop visualizer now reads that same resource. The affected demo tests are green. Treat “CCC” as BBB unless Karl supplies a distinct CCC archive. Do not replace or reprocess the demo without a new explicit request.

## Immediate continuation (2026-08-29)

The first unchecked task is still Capture-movement loss Phase 1/2. Take 009 proved the exported trace recorded the wrong builder coordinate: live received angular `processed.position`, while the trace stored smoothed display X, so its live 48 final movements replay as 0. DEBUG trace wiring and an environment-gated hardware replay assertion have been corrected, but the task must remain unchecked until a fresh hardware take from this build exactly reproduces its live final count offline.

Next action: make one short, clean Baby Scratch hardware take with the updated macOS Debug app. Export it, locate `debug/take-N_movement_trace.json` and `debug/take-N_movement_diagnostics.json`, and run `MovementTraceDiagnosticsTests.testExternalHardwareTraceExactReplayMatchesLiveDiagnostics` with `SCRATCHLAB_MOVEMENT_TRACE` and `SCRATCHLAB_MOVEMENT_DIAGNOSTICS` pointing to those files. Compare the printed live/ideal/exact funnels. Do not change sampling or thresholds until exact replay matches live and reveals the first real loss stage.

Product recording direction: CXL should hear the beat in headphones/cue, while ScratchLab records the scratch deck alone as the canonical audio stem. A future Ableton Link slice may store shared tempo/beat/phase, but Link does not identify Serato's left deck; the operator must set the left deck as the Serato Link/master reference. Keep any beat reference or mixed evaluation audio separate from the canonical training stem.

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

## Immediate continuation (2026-08-31 standalone output capture)

Build the macOS target and fix only compile errors introduced by the post-mixer routine capture and automatic review-MOV audio replacement. Then load onboard AHHH, record a fresh RANE-controlled take, and verify the new `Onboard AHHH output` meter responds while `Hardware input signal` remains diagnostic-only. Review must play the scratch in sync, the MOV must contain one stereo audio track rather than the old multichannel RANE track, and exported scratch WAV must be audible on both sides. Do not return to RANE 13/14 routing; standalone AHHH no longer uses that input as its canonical source.

Release continuation: build 1.0.1 (19) has an exported IPA at `build/AppStore-1.0.1-19/ScratchLab.ipa`. Before submission, rerun the complete desktop XCTest plan and make one fresh Rane take, then verify scratch-only, beat-only, scratch-with-beat, and review video durations match the actual captured take.

## App Store build 20 continuation

ScratchLab 1.0.1 build 20 was uploaded successfully from `feature/ios-capture-camera-ux` at HEAD `9fbbd65c` plus uncommitted release-warning fixes and the build-number bump. Confirm processing in App Store Connect and inspect any Apple warnings. Do not upload build 20 again; use build 21 for any changed binary. Commit or push only with Karl's explicit approval.

Continue the Watch relay/export fix from 2026-09-04. Do not delete any worktree, duplicate, archive, screenshot, or generated build data unless the user gives new explicit approval. First build the macOS and generic iOS schemes, confirming the Watch target compiles. Then install the updated iPhone and Watch apps, run a physical Mac+iPhone+Watch take, export it, and verify that the manifest reports a Watch source and that `watch/` contains the motion CSV. Preserve all unrelated dirty changes. The prior supplied ZIP has an empty `watch/` directory and cannot be repaired.
