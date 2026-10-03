# Current checkpoint — Batch 2 final verification BLOCKED / NOT VERIFIED


## 27 September 2026 — Capture reconciliation Batch 2 final verification BLOCKED

User-selected verification-only gate. Fresh audit proves the complete tracked diff/status, HEAD/index and all 19 untracked files match the failed Batch 1 final candidate; all 738 inventory paths accounted for, no unexplained source drift. Reference approval has historical bounded PASS, but five MIDI-drain failures and the invalid-Stop failure remain unrepaired. The worker non-recording guard still suppresses the explicit Stop error. Mandatory precondition therefore FAILS.

Phase 1 complete; Phases 2–4 NOT RUN: zero new test executions, no scripts/build.sh all invocation, no iOS/full Mac/CXL/Watch build, no MacAnalyzerView receipt audit. Historical Batch 1 only: focused 213/426 pass; broader 469 distinct/938 executions = 924 pass, 12 fail, 2 skip; Python 87/14/36 pass; exit65 at XCTest before every platform build leg. Do not promote those historical numbers to fresh results.

Only four workflow documents updated, retaining historical bytes. No source/test/project/resource edits or commit/push/install/hardware capture/Learner/notation work. Candidate BLOCKED / NOT VERIFIED. Complete report, full modified/deleted/untracked inventory, baseline comparison and final preservation receipt: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-final-verification-20260927T093040Z/RESULT.md. Next action is separately scoped repair/verification of MIDI drain and invalid Stop, then rerun this gate.

--- Earlier checkpoint retained verbatim below ---

# Capture reconciliation Batch 1 — bounded approval PASS, broader gate FAIL (27 September 2026)

STOP after this batch. Evidence and preservation: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch1-20260927T091041Z/RESULT.md`; `AUDIT.md`, `final-preservation.json`, `batch1-only.patch`, commands/logs/xcresults are adjacent. Both trees remain at expected79fb3ecd74d261de5f3fd1f8b1434b620077ae3c; source main, donor detached/read-only. Entry source was38modified/2deleted/19untracked (six more modified than supplied audit), explained by earlier Slice1/2/3 work. Donor14modified and both indexes preserved.

Approval repair, donor regressions and nonfinite-end coverage were ALREADY present. No production changes. Extended two authorized test files for finite-beat conversion overflow at both ends, no first-frame allowance on later repetitions, and actual approval recovery while retaining independent selection gating. Entire ReferenceValidation/derivedInspectionIssues and offline tests/producer preserved. Focused213distinct/426executions PASS,zero fail/skip; Python87/14/36 PASS; all seven named approval regressions and three saved-draft/archive round trips PASS.

Required scripts/build.sh all, using existing isolated bounded verification practices, FAILED exit65:469distinct/938executions,924passed/12failed/2skipped. Five unchanged LivePerformedNotationTrackerTests MIDI evidence-drain cases plus the known unchanged ReferenceAuthoringViewModelTests invalid-Stop case fail in both configurations; exact names/assertions in RESULT. Optional take003 fixture missing causes both skips. No exclusions/repairs. Platform build legs (iOS/fullMac/CXL/Watch) not reached. No whole-candidate or all-platform PASS claim.

Only two tests and four workflow docs changed in this batch. Every other source inventory entry, donor, protected untracked JSON/hash, deletions, indexes and historical documentation preserved. MacAnalyzerView remains unchanged; old shipping-media receipt is not current parity proof. No new stop/finalization/camera-diagnostic transfer, notation/schema/calibration/Watch/Learner changes, install, hardware capture, commit or push.

Next requires a separate bounded authorization: reconcile the five MIDI drain failures; finish Slice3 explicit invalid-Stop behavior; then pending Slice4/final reconciliation and MacAnalyzerView receipt audit/full gates. Existing later work stays intact. Do not execute historical deployment/physical prompts below.

--- Earlier checkpoint retained verbatim below ---

# Canonical reconciliation Slice 3 — NOT VERIFIED, 27 September 2026

STOP: focused gate exposed a Slice 3 regression. ReferenceAuthoringViewModelTests.testBridgeErrorAndInvalidStopTransitionAreSurfacedWithoutChangingPhase expected "No recording is in progress." but received nil. The new ReferenceAuthoringWorker.stopRecording non-recording phase guard silently drops the existing explicit-stop error. Do not weaken the test; distinguish stale reconciliation no-op from explicit invalid stop in a separately authorized continuation. No fixes made after the failure. Final focused result: 543 distinct tests; 1086 expanded executions; 1 distinct failing test / 2 failed executions; 0 skips. See ../evidence/canonical-reconciliation-20260927/slice3/RESULT.md and focused.xcresult. No Slice 2/1/downstream reruns, no Slice 4, no commit/push/install/physical capture.

Changes retained for review: exact terminal status, worker token/cancellation/deduplication fences, view-scoped weak polling, shared Review path, Stop/progress UI, nine new lifecycle/integration tests. Source-only work and Slice 2 endpoint/whole-WAV code are preserved. See slice3/AUDIT.md, BLOCKER.md, before.json, slice3-only.patch. Current canonical source only; duration-diagnostics remains read-only.

--- Previous checkpoint follows ---

# Canonical reconciliation Slice 2E — Slice 2 VERIFIED, 27 September 2026

STOP here; Slice3 is not started or automatically authorized. Current canonical source main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c remains dirty and uncommitted. Read ../evidence/canonical-reconciliation-20260927/slice2e/RESULT.md and DIAGNOSIS.md. Earlier stopped checkpoints below are historical.

The256-frame discrepancy was a production measurement defect, not lost WAV data: actual test RIFF2688000PCM bytes/4 and AVAudioFile.length both prove672000frames. measureAudio's first successful read returned671744 and stopped; a second read retrieves256. All WAV bytes/hashes were identical before/after. No crop/conversion/writer runs in artifact measurement. Classified F exposing J before editing via LLDB and independent header/read probes. ReferenceAuthoringCaptureBridge.measureAudio now consumes remaining declared frames, sums actual reads and measures peak through the tail; zero progress fails explicitly. Existing allocation and schemas preserved. New tail0.75 marker in the endpoint test proves the final partial read contributes to peak; exact672000 assertion and113.9/114/114.1 endpoint/sidecar/projector assertions remain intact. Slice2C production endpoint logic unchanged.

Fresh software acceptance: single downstream1 distinct/2 executions; full Slice2 240/480; full Slice1 203/406; focused downstream integrity61/122. All PASS,zero failures/skips. All requested downstream selectors discovered. Complete Slice2 production diff and preservation audited: first token-owned endpoint retained, inclusive final MIDI bound, original timestamps/order, passive diagnostics, held-fader semantics and bound reset preserved; no canonical algorithm/schema/calibration/tolerance change. The only new Slice2E production change is audio measurement. All19 prior untracked files,two intentional deletions,reference tree,indexes and protected JSON preserved.

This is bounded software readiness for a separately requested Slice3, not completion of whole reconciliation or hardware/product acceptance. Full repository/all-platform gate, actual watchdog timing and physical capture/export remain unrun for this batch. No commit,push,install,physical capture,notation export feature or Learner changes. Do not follow historical release/installation instructions below.

--- Earlier checkpoint retained below ---

# Canonical reconciliation Slice 2D — STOP on corrected single-test failure, 27 September 2026

Continue only under a new bounded request. Read ../evidence/canonical-reconciliation-20260927/slice2d/RESULT.md. Slice2C production repair is preserved byte-for-byte. Slice2D changed only testBoundedFinalizationProtectsPerformedProjectionAndSavedSidecarArtifacts in ReferenceBeatPilotTests.swift plus this checkpoint, next_prompt and DEV_LOG.

Before editing, isolated reproduction failed in both configurations. LLDB attached only to the isolated test host proved two distinct paths: MacScratchDetector.trainingAudioFiles at line546 catches the absent optional DEBUG internal_training/baby_scratch directory and returns[]/fallback; ReferenceAuthoringCaptureBridge.buildArtifacts at line889 returns recordingFailed("endpoint.wav is missing or empty after finalize.") with audioCheck exists=false/bytes=0. The test's Result.get propagates the latter; XCTest displays the earlier observed caught directory error. The runtime attribution mechanism was not changed. No archival folder is required for captured-take artifact assembly.

One fixture repair: temporary deterministic mono48kHz silent WAV intended to span14s/672000frames, same AVAudioFile pattern as existing finalized-media review tests; explicit113.9,114.0,114.1 probes around witnessed114; read actual saved sidecar, decode/project imported artifact and verify audio/sidecar hashes. No production/resource/schema/algorithm changes. Corrected single test FAILED in both configurations at ReferenceBeatPilotTests.swift:1142: artifact audio.frameCount671744 != requested672000. No other assertions reported failure. This is the next exact blocker, NOT diagnosed as a production bug; no assertion relaxed and no repair/rerun after it. Complete Slice2, Slice1 and downstream integrity gates NOT RUN under the user's explicit stop rule; historical full gate counts do not certify this fixture.

Preserve both trees/indexes,19 untracked files,two intentional deletions and protected JSON. No Slice3,notation export,commit,push,install,physical capture or Learner changes. TASKS not completed. Next authorized work must identify the256-frame discrepancy without weakening the audio-integrity assertion or changing production speculatively, then rerun only this test; broader gates only after success.

--- Earlier checkpoint retained below ---

# Canonical reconciliation Slice 2C — STOP on test failure, 27 September 2026

Canonical source main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c only; duration-diagnostics remains read-only. The endpoint repair freezes the first token-owned MIDI close time and filters the finalization drain with timestamp <= endpoint, preserving admission order and passive diagnostics. Changes are in MacCaptureEngine.swift and two existing test files. Read ../evidence/canonical-reconciliation-20260927/slice2c/RESULT.md before continuing.

Slice2 gate FAIL: 240 distinct tests,239 pass/1 fail/0 skip;480 executions,478 pass/2 fail/0 skip. Sole failing test in both configurations: RoutineStopDuringStartTests.testBoundedFinalizationProtectsPerformedProjectionAndSavedSidecarArtifacts, caught NSCocoaErrorDomain260 for absent bundled internal_training/baby_scratch. XCTest points at the existing makeEngine teardown registration line651; exact throwing dependency is not established. Read-only inspection also finds the new artifact fixture writes only JSON whereas buildArtifacts requires a nonempty audio WAV. Do not restore shipping archival resources, bypass guards, weaken assertions, or assume the fixture's downstream path is verified. Initial compile-only run had an Int/Double fixture typo, corrected before the actual test run. Logs and both xcresults retained.

Original delayed movie endpoint regression now PASSES:113.9 and114 survive,114.1 is excluded. Multiple/out-of-order/exact-boundary/control-wide filtering, unchanged bounded bytes, stale/next-take isolation, manual/watchdog entry points and held-fader coverage tests PASS. Actual watchdog timer, hardware and full saved-media/export lifecycle are not proven. Slice1 rerun and full builds NOT RUN because user requires STOP on any Slice2 failure. TASKS remains incomplete. No Slice3, notation export feature, commit,push,install,physical capture or Learner work. Preserve all19 prior untracked files, intentional deletions, indexes and protected JSON. A separately authorized continuation must resolve the downstream test fixture/dependency, rerun the complete Slice2 selection, and only if fully green rerun complete Slice1.

--- Earlier checkpoint retained below ---

# Slice 2B — STOPPED on verified endpoint regression, 27 September 2026

Only the two MIDI endpoint test fixtures were corrected using the existing token-checked testOnly_openTakeMIDIEpoch after claim/before didStart, with ownership and admitted-event assertions. No production file changed. Full previous Slice2 selection compiled and ran:180 distinct tests(179pass,1fail,0skip),360 executions(358pass,2fail,0skip). testWitnessedStopClosesMIDIAdmissionAtExactEndpoint now passes. testDelayedMovieCallbackCannotRetainMIDIAfterItsWitnessedEndpoint now fails with actual[113.9,114.0,114.1] versus expected[113.9,114.0]: the fixture is valid, but the production finalization drain retains MIDI beyond witness114.0. closeMIDIRecordingWindow seals parked coverage and retires admission; it does not bound previously admitted events. Stop under user's rule; no production correction or Slice1 regression rerun (requires green Slice2). Earlier203/406 Slice1 PASS is historical, not rerun.

Receipt: ../evidence/canonical-reconciliation-20260927/slice2b/RESULT.md and before/after.json, slice2.log/xcresult/summary. All production hashes unchanged from Slice2B entry; passive diagnostics,19 untracked files, protected hash459264664bbd116610440ac179c1060e6b81d0a0ef1923016605ef5d36fed309, both deletions, reference tree and empty indexes preserved. Ordinary CC capture uses callback-host now; native packet timestamps are separate passive diagnostics. Do not claim native-measurement timestamp authority or end-to-end finalized notation proof from the direct admission test. Next requires a separately scoped endpoint-bounding correction preserving raw provenance/ownership, then Slice2 and Slice1 gates. No commit/push/install/physical/Slice3/export work. SLICE 2 NOT VERIFIED. Earlier checkpoint below is historical.

# Canonical reconciliation — STOPPED at Slice 2 gate, 27 September 2026

User-selected Option A: canonical `source` main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c; detached `duration-diagnostics` is read-only repair evidence. External preservation receipt, before patches/source snapshots, SHA-256 inventories, logs and xcresults: `../evidence/canonical-reconciliation-20260927/`.

Slice 1 was reconciled at the validation/test hunk level: finite start/end and before-media rejection, real preroll and nominal-first-frame allowance preserved, direct approval revalidation. Fresh gate PASS: 203 distinct tests / 406 executions, zero failures/skips. Includes one additional nonfinite-end test; existing derived-inspection additions preserved.

Slice 2 implementation is PARTIAL / NOT SOFTWARE VERIFIED: pure witnessed-sample endpoint helper; maxRecordedDuration disabled; single writer stop with witnessed MIDI closure; delayed-start/reset handling; original 0.75 s watchdog/manual/safety-cap paths retained. No sample-end comparison or tolerance change. Seven reference regressions plus three endpoint/ordering tests were added. Fresh gate FAIL: 180 distinct tests, 178 passed and 2 failed; 360 executions, 356 passed / 4 failed, zero skips; compilation succeeded, xcodebuild exit65. Failed methods in ReferenceBeatPilotTests.swift: testWitnessedStopClosesMIDIAdmissionAtExactEndpoint and testDelayedMovieCallbackCannotRetainMIDIAfterItsWitnessedEndpoint.

Immediate cause of these two failures is an executor-added TEST FIXTURE defect: testOnly_claimRoutineMediaStart claims the movie but does not invoke beginRoutineTakeTimelines/open the MIDI epoch. didStartRecordingTo also does not open that epoch. Both new tests consequently reject all MIDI and drain []. This is NOT proof of an actual endpoint leak or dropped production MIDI. The next bounded action is to open the test epoch using existing testOnly_openTakeMIDIEpoch(at: 100) in both fixtures, assert nonzero epoch/admission, and rerun Slice 2. The delayed-callback requirement is still unresolved: closeMIDIRecordingWindow currently closes admission/seals parked coverage while drainCapturedMidiCCEvents returns previously captured events; no retrospective endpoint filtering is shown. Do not weaken the test or claim no post-boundary notation leakage without proving the actual finalization path.

Stopped under the user's explicit STOP-on-failure instruction; no fixture fix or further production work after the failed gate. Slices 3 (late finalization), 4 (bounded observability), historical-document reconciliation, full build/test gates, final export/notation parity verification and fresh MacAnalyzerView semantic audit are NOT RUN. Only these handoff/continuation checkpoint headers were added; historical docs and product decisions are preserved. TASKS is not marked complete. Do not run old installation/release/physical prompts below.

Preservation so far: all 19 pre-existing untracked files are hash-identical, both intentional deletions remain, duration-diagnostics is unchanged, no index changes. All original passive diagnostic addition blocks and offline validator/test addition blocks remain byte-identical. Notation implementation, exports, project/resources, shipping-media UI and all other tracked files outside the six implementation/test paths remain hash-identical to preflight. Protected cxl_baby_target.json SHA256 remains459264664bbd116610440ac179c1060e6b81d0a0ef1923016605ef5d36fed309. Build used the existing isolated shippingmedia verification host/cache, with no project signing/language/isolation edits. No physical capture, device setup, deployment, install, upload, commit or push. Nothing changed in Learner or Downloads checkout.

# CXL release finish — active 4ca4 worktree, 13 September 2026

Active branch `codex/cxl-release-finish-20260913`, source `/Users/karlwatson/.codex/worktrees/4ca4/ScratchLab`. The user requested continuing in this new worktree. Transferred 18 dirty files from the prior Rane worktree and hash-verified them; that worktree is preserved. Current evidence/output root: `/Users/karlwatson/Developer/ScratchLab-CXL-Release-Finish-20260913`.

Root cause of the saved-draft failure: the bridge allows acknowledged captures with no Stop diagnostics to reach a bounded timeout, but the session recovery required Stop diagnostics even for a subsequently verified matching file. Recovery now accepts that legacy absence only from timedOut (not arbitrary conflict); exact command/take, SHA-256 and export binding checks remain. Added both positive timeout recovery and negative conflict coverage. The original reopen/approve/export integration case remains unchanged and now passes. Focused stable-Xcode26.6 gate: four unique cases/eight executions, zero failures/skips, exit0. Full stable-Xcode release gate passed (exit0): Python87;836 unique XCTest cases,1672 executions across two configurations,1666pass/6existing skips/0fail. iOS, universal full Mac, universal CXL and Watch builds all succeeded. All517 frozen build inputs still match. Full XCTest suite and physical hardware acceptance NOT RUN. See evidence/release-gate-receipt.json, release-gate.log and release-source-hashes.json.

Latest ASC read: CXL6811514515 no builds; iPhone6761674709 build23VALID. Both build24 archive scripts are PREPARED, NOT RUN. Stable Xcode direct upload follows the verified checkpoint. The new CXL Mac App Store profile YRTR28LXSV was created using the existing distribution certificate and installed locally. Approved beta descriptions, contact details and public privacy URL are saved for both apps through the authenticated browser. The API key can read/upload but returned403 for profile/metadata mutations; do not broaden it or create replacement keys. Commit/push follows this checkpoint; no upload/install yet. Existing iPhone ASC review contacts may be reused for Mac under user authorization; no invitations or App Store production submission. Hardware Seventy-Two/Twelve NOT RUN.

--- Prior worktree handoff retained below; current paths/status above take precedence ---

# Spark release handoff — 13 September 2026, current

User explicitly requests a Spark prompt to commit all relevant changes, push, and upload through Xcode Cloud or a working local Xcode path. Worktree: /Users/karlwatson/Developer/ScratchLab-CXL-Rane-SeventyTwo-20260913/source; branch codex/cxl-rane-seventy-two-twelve-20260913; base 1e92aa531bb18ebbc34a3305dd78366550aeb144. This worktree started clean; current dirty changes belong to this task. No candidate commit/push/install/upload has occurred.

BLOCKING VERIFICATION: final-gate.log contains a real failing saved-draft/late-Watch test: ReferenceTearEvidencePipelineTests.testSavedDraftCanBeApprovedAndExportedAfterRestartWithExactEvidence, in ReferenceAuthoringViewModelTests.swift:1025,1035,1037. The reopened take is not linked; approval reports that the Watch Stop reply or motion file missed its 90-second timeout. The test creates the acknowledged transfer after saving, before reopening. Diagnose persisted timeout versus validated late-link recovery (and fixture identity/timestamps); do not simply skip the test or relax media identity checks. Root cause is not yet established. Watch is supplementary; keep raw Mac media/export available and make wrist-evidence absence truthful.

Codex stopped only its active xcodebuild PID30242 with SIGINT after the failure. Parent build PID29290 and command session51201 have exited75. No gate remains running from this attempt. Partial log accounting: 1378 passing test executions, four skips, one failed execution; INTERRUPTED, not a complete passing gate. Preserve ../evidence/final-gate.log, final-gate.xcresult and final-gate-source-hashes.json. The all-platform builds were not completed by this attempt. Run one replacement gate after fixing the failure; do not overlap Xcode builds. The existing wrapper ../evidence/bin/xcodebuild and the recorded command in final-gate.log capture all 28 selected classes. Give the 23-technique archive integration case its existing 600-second allowance (it passed in 141 seconds).

Earlier completed focused runs: controls39 unique/78 executions; Twelve91/182; Tear-identity-and-routes74/148; explicit output pairs33/66. All passed, no skips. These overlap; do not sum them as unique tests. The three historical Tear fixture failures were fixed by supplying exact source IDs and adding a negative missing-ID regression; production validation was not weakened. Claude F5-F7 gate separately verified451 unique/902 executions:898 pass,four existing skips,zero failures, plus Python87 and all platform builds. Do not repeat Claude's audits or media rebuild.

Implemented dirty changes: shared Mac/CXL hot-cue/sample/fader-curve setup; guarded Load/Re-cue for four real samples; separate modern CoreMIDI Twelve Deck2 CC1/CC2 ingress with source/generation/take ownership; raw MIDI preservation; explicit device-bound scratch/beat USB output pairs; setup snapshot in existing sidecar audit. Hardware Seventy-Two/Twelve acceptance NOT RUN; protocol is operator-supplied, ticks/revolution uncalibrated. Existing captures and installed app remain untouched.

Release: read-only ASC check found CXL Mac app6811514515 has no builds; iOS app6761674709 has VALID build23, which is not this candidate. Refresh before assigning a build number. ../evidence/archive_verified_cxl.zsh is PREPARED, NOT RUN, using stable /Applications/Xcode.app (26.6), universal CXLRelease and proposed build24. Current test outputs use Xcode-beta and must not be uploaded. Preserve team2DDKGL33BU, com.machelpnz.scratchlab.cxl-authoring and all entitlements. Existing authenticated helper: ~/Developer/ScratchLab-Xcode-Cloud-20260913/evidence/asc_client.py. Existing local API key must never be printed. Reuse approved beta text at ~/Developer/ScratchLab-CXL-Handoff-20260913/TESTFLIGHT_BETA_INFO_APPROVED.md and existing ASC contact details; no tester invitations or production release authorized. Cloud asset uploader belongs to another workspace; inspect current state without killing or replacing it. Prefer direct stable-Xcode upload if Cloud's private-asset pin is not ready.

169 reference assets verified unchanged in ../evidence/reference-library-verification.json. Updated one-page PDF/DOCX is in ../package/; visual one-page check passed. Do not put media, archives, credentials, compiler output or private artifacts into the public source repository. Before release update DEV_LOG/TASKS/handoffs, review named staged paths, commit without Co-Authored-By, push the actual candidate branch, and prove ASC processing/review status from Apple's response. A commit is not an upload; an upload is not beta approval.

--- Earlier notes follow; this section supersedes their progress/release status ---

# Codex takeover — CXL capture and Seventy-Two/Twelve, 13 September 2026

Active source: `/Users/karlwatson/Developer/ScratchLab-CXL-Rane-SeventyTwo-20260913/source`, branch `codex/cxl-rane-seventy-two-twelve-20260913`, base 1e92aa5. User ran out of Claude usage and asked Codex to finish the remaining work. This worktree started clean; current source changes are Codex-owned. No new commit, installation or upload yet.

F5/F6/F7 from Claude are completed: 1ab8f3a / 163c0d4 / 1e92aa5. Their final capture gate finished successfully: 451 unique tests, 902 executions (898 passed, four existing skips), Python87, iOS/full Mac/CXL/Watch builds. All445 Swift/Python hashes still matched. Preserve Final-Capture-Fixes evidence; do not repeat Claude's audit.

Implemented here: shared Mac/CXL fader/curve/hot-cue setup; persistent Load/Re-cue with four samples; capture-time configuration guards; separate modern CoreMIDI Twelve source using the user-supplied Deck2 CC1/CC2 protocol; raw-source preservation and take-ticket/generation checks; explicit device-bound USB output pairs for scratch and beat. Initial sample/mapping/source settings are retained in the existing sidecar audit trail. No export schema change.

Verification in progress, external evidence at `../evidence/`: controls78/78, Twelve182/182 and Tear-identity/routes74/74 passed. The first combined gate was deliberately stopped after it reproduced the three old Tear failures and the 23-technique archive case exceeded120seconds. Positive fader fixtures lacked source IDs; corrected them and added a missing-ID negative regression without weakening production validation. The expensive 23-technique integration case now has a bounded600second allowance. A focused output-pair test run is active; run the final all-platform gate after completing remaining review. No concurrent xcodebuild.

Actual Seventy-Two/Twelve is not connected here: protocol/pair/physical headphone acceptance NOT RUN. The protocol is operator-supplied, not certified; no calibrated revolution claim. Mac installed app and captures untouched. Latest read-only ASC check: CXL app6811514515 has no builds; iPhone app6761674709 build23 is VALID and does not contain this candidate. Cloud asset uploader is separately active (do not interrupt or edit its sources).

--- Historical notes below are superseded where they conflict ---

# Audit-origin slice verified — 13 September 2026

F1–F4 correction complete in source. Python87pass;440unique XCTest cases across2configurations=880executions,876pass4existing skips0fail. Required all-platform gate passed iOSDebug and universal fullMacRelease but ran out of disk at CXL universal packaging. After task-owned compiler-cache/unsafe-stage cleanup, CXL universal and Watch builds pass without source changes. Exact7file hashes in ../evidence/audit-correction-receipt.json. DO NOT claim the original all command exited0; its preserved exit65 is explained by disk capacity and completed by two successful build retries.

Unsafe ../staged/ScratchLab CXL.app removed to prevent accidental installation and reclaim space; its original receipt remains. Corrected app is NOT staged/installed/uploaded. Original captures, installed app and Claude audit workspace unchanged. F5–F7 and approval/export dependency review stay open; this is software verification of the origin slice, not complete CXL hardware acceptance.

Next: commit/push this correction under existing authorization, integrate its seven source/test files into the prepared Cloud branch, preserve Cloud-specific docs and configuration. Private dependency access is granted and30checkpoint media upload is progressing. Three manual workflows exist; first remote runs wait for completed private pin plus corrected committed source. No TestFlight distribution.

--- Earlier active notes follow, superseded by completion above ---

# Active independent-audit correction — 13 September 2026

DO NOT INSTALL the staged d86a369 app. Claude's audit identified real origin/validation/export defects despite the earlier focused gate. Its three regression tests were run unchanged on d86a369: 3 executed, 3 failed (../evidence/audit-red.xcresult). Existing captures, installed app, old archive and Claude audit workspace remain untouched.

Correction in progress in this worktree: fixed planned performance duration independent of measured camera origin; bounded 150ms preroll / one 30fps frame lateness shared with export; actual start-offset duration accounting and exact beat stem; lock-owned sidecar updates retain measured origin and late Watch association/Stop diagnostics. Six audit/origin/merge tests pass. First expanded run: 63 executed, 62 passed, one older test expected the old measured-dependent planned-duration error. That assertion has been corrected to require the explicit late-camera rejection while retaining the fixed plan. Full gate not yet rerun. No installation or hardware success claimed.

Keep remaining audit findings visible: start/Stop boundary race, secondary-camera admission/end timing, and persisted pending Watch Stop recovery require separate follow-up; approval/export dependency audit was not completed by Claude. New TestFlight upload requires a build number above existing build 21 after checking ASC.

Xcode Cloud setup continues separately at ~/Developer/ScratchLab-Xcode-Cloud-20260913/source. ScratchLab Cloud product 4ABF7852-6C7E-45C8-B7AD-FAD2040DBEF4 now exists; its initial workflow is inactive. CXL ASC app 6811514515 exists, but its Cloud product is not yet initialized. Private media upload restarted in resumable 90MiB checkpoints; script/evidence under that worktree's ../evidence. No Cloud build has run. Source repository is public; media stays in the private ScratchLab-ReferenceAssets repository.

--- Superseded candidate record below; do not follow its installation instruction ---

# Active repair — timed capture and late Watch evidence (13 September 2026)

User-selected task: fix the reported Baby take stopping short and falsely reporting Watch Stop failure. Worktree: `/Users/karlwatson/Developer/ScratchLab-CXL-Timing-Fix-20260913/source`, branch `codex/cxl-timing-watch-fix-20260913`, base7b056cd. Original a4aa delivery worktree remains untouched; Claude may be handling ASC independently.

Evidence: original take64b341bc-9d01-4f44-821a-71d4baa54516/take-001 has542430 WAV frames at44100Hz (12.30s), plan13.333s, stopReason=planned_duration_reached. Intended start103044.44893 host seconds; old callback-owned fader/audio epoch103045.5313785 (1.08245s later). Watch Stop sent at finalize, stopped reply afterward and linked file3s later. Original three files remain unchanged; read-only hashes/timeline at `../evidence/reported-take.json`. No canonical approval or preferred selection fabricated.

Candidate changes: prepare during count-in; a small AVCaptureFileOutputDelegate adapter enables sample-accurate first movie frame; camera PTS is converted to host time and shared by MIDI/platter/camera/PCM;150ms real preroll puts first beat inside the movie and shifts the maximum duration to retain the same musical end. Persist measured media origin. Collect real PCM before recording and through buffered tail delivery, trim against original finalized movie duration. Refuse incomplete coverage, clock gaps or overflow and retain diagnostic PCM; normal maximum-duration errors cannot hide audio/mux failures. Watch sent remains pending. Old falsely failed sent drafts may recover only with original snapshot, matching capture/command and verified file hash. Duration validation stays strict; generic mismatch wording no longer blames a manual stop.

Verification complete: required `scripts/build.sh all` exit0. Python87pass; selected430unique/860executions=856pass/4existing skips/0fail across2configurations; iOS, universal fullMacRelease, universalCXLRelease and WatchRelease builds passed. Full XCTest suite NOT run;13 selected classes are in the wrapper. Two pre-existing tests skip per configuration (optional capture output unset; host supplies no render callbacks). All10 source/test hashes match the gate. Original three capture files remain byte-identical. Stable Apple-signed candidate at `../staged/ScratchLab CXL.app`, executable SHA256 b3b8cefbea7598d22a5add4a38906d81eb4631c20f5def7d8bdf1f5471249286; staging receipt preserves team, bundle, permissions and entitlements. Not installed; physical acceptance pending.

User also requested an independent Claude audit prompt with60% allowance remaining. Prepared `/Users/karlwatson/Developer/ScratchLab-CXL-Independent-Audit-20260913/CLAUDE_AUDIT_TASK.md` and isolated source snapshot on branch`codex/cxl-independent-audit-20260913`; all10 candidate source/test files matched this repair at freeze. Claude is instructed to audit/add tests only, preserve baseline, checkpoint, coordinate build availability, and leave10–15% of remaining allowance for handoff. No claim that a prompt enforces usage or that any audit guarantees all bugs are found.

Next: install the verified staged candidate only when CXL is safely idle/closed. The user additionally authorized Xcode Cloud setup; use a separate branch/worktree. ASC API access now works, no ciProducts exist, and source GitHub repository is public. Keep reference assets private. Initial Cloud product setup requires Xcode UI. Preserve captures/prior app and do not overwrite a running capture. User needs one fresh physical90BPM/1bar/four-repetition check and a late Watch review/reopen check. Existing short recording cannot regain missing audio; preserve it. Coordinate any source integration/upload with Claude's separate delivery work; prepared TestFlight artifacts do not yet contain this repair.

--- Historical handoff follows ---

# Current — TestFlight route prepared, blocked on Apple sign-in (13 September 2026)

Karl switched the Mac to TestFlight; the Developer ID plan is superseded. He is away (Remote Control on iPhone) and has not signed in to Apple. Nothing has been uploaded, no app record created, no beta review submitted and no testers invited.

Authentication checked without exposing secrets:
- Xcode has no account.
- Transporter has no account.
- The automation Chrome window shows ASC login `authResult=FAILED`.
- API key `AuthKey_M6C29AZTW5.p8` exists but has no recorded issuer ID.

The local ASC export of the Mac archive failed with `No Accounts` / `No profiles for com.machelpnz.scratchlab.cxl-authoring`.

New this turn:
- Mac archive at `/Users/karlwatson/Developer/ScratchLab-CXL-Handoff-20260913/archives/ScratchLab-CXL-Mac.xcarchive`: CXLRelease 1.0.1(21), stable Xcode 26.6/macOS 26.5 SDK, universal, App Sandbox with existing entitlements unchanged. Apple Development signed, strict verify OK, 169/169 assets match.
- Guide Install paragraph now covers TestFlight on Mac and iPhone. The one-page A4 PDF is in `package/`; the old PDF is kept as "(superseded download route)".
- Karl approved the beta text; saved in `TESTFLIGHT_BETA_INFO_APPROVED.md`.
- For beta review contact, feedback email and privacy URL, reuse existing ASC values. Ask if any are empty.

Keychain has Apple Distribution and 3rd Party Mac Developer Installer identities. The installed pilot was built with Xcode 27 beta, which ASC rejects, so use the new stable archive. Read `NEXT_STEPS_AFTER_SIGN_IN.md` in that root for the exact continuation. The iPhone IPA (build 22) is unchanged and still needs the ASC build-number check. Mac cache directory was removed; archive, logs and evidence retained.

--- Previous state (historical) ---

# CXL delivery preparation, Apple setup pending (13 September 2026)

User wants the CXL Mac app plus iPhone/Watch distribution and a one-page guide. Prepared root /Users/karlwatson/Developer/ScratchLab-CXL-Handoff-20260913. Read docs/cxl_delivery.md and that root's RESULT.md first. One-page PDF is package/ScratchLab CXL Quick Start.pdf. Mac internal pilot ZIP is Development signed only; no Developer ID certificate exists in the current keychain, no notarization. Installed blank Mac app untouched.

Successful stable Xcode26.6 iPhone+embedded Watch archive at archives/ScratchLab-iOS-Watch.xcarchive and Apple Distribution export at testflight-export/ScratchLab.ipa. Both version1.0.1/build22 (candidate; not checked against ASC), minimum iOS26.5/watchOS10. Signatures/profile entitlements verified, get-task-allow=false, no registered-device restriction. All169 library assets match in Mac/archive/export; Mac ZIP CRC and included guide verified. App source remains dcd7a7686575c2d7ca505677d8eb9130d60aa3d3; only documentation is changed this turn. No repeated broad tests or hardware acceptance claim.

Next: user signs in to Apple in the opened App Store Connect browser tab (last seen login); confirm existing app/build versions and beta account fields; obtain CXL's tester email and Mac/iPhone/Watch models/OS versions; upload and required external review/invitation; finish proper Developer ID Mac signing/hardened runtime/notarization. Current stage_cxl_mac.py uses a WWDR development requirement, so do not blindly feed it a Developer ID certificate. Enter credentials only on Apple pages. No upload, group, invitation, notarization or external send occurred. Existing user commit/push authorization applies; source docs checkpoint separately from artifact source hash. Preserve prior actual-rig limitations.

Evidence includes archive/export scripts/options and failures: use command-local -IDEBuildLocationStyle=Unique with isolated derivedDataPath for archives; global Xcode Custom paths caused first assembly failure. Export signing must be automatic for the existing Xcode-managed Store profiles; manual mapping was rejected. Temporary build/extraction/failed archive copies were cleaned after verification; final archives/packages/logs remain. Browser tab was handed off for sign-in; do not request passwords/OTP in chat.

--- Previous state (historical; current record above takes precedence) ---

# Current CXL delivery — installed, empty capture library, 13 September 2026

Worktree a4aa, branch codex/finish-reference-library-20260913, baseline778a7c4. The current changes are being committed and pushed under Karl's existing authorization; resolve the final checkpoint from Git. Evidence/report root: ~/Developer/ScratchLab-CXL-Review-Fix-20260913. No concurrent gate remains.

## Installed and reset

Installed/opened ~/Applications/ScratchLab CXL.app, executable SHA71674b5c59a52dd2badf3c28c8d0bd76262125ffabdbd987838b4319defd6e96, verified PID93241. Staged with scripts/stage_cxl_mac.py, Apple Development identity5C5FDEBBEAC7E2148567C91968CBBA6B6561D298, team2DDKGL33BU, stable bundlecom.machelpnz.scratchlab.cxl-authoring/permissions/entitlements/designated requirement. Receipt staged-3/ScratchLab CXL.receipt.json remains. The redundant staged app was later removed under the cleanup request; the installed app and previous app are retained. This is an internal development pilot, not a notarized public release.

The updated iPhone app was backed up, installed and launched on K (iPhone16ProMax, UUID1F80398A-96C8-537A-B0EE-821E186918B9); evidence/iphone-before-update and iphone-install/launch.json. Watch app was not replaced. No physical relay success claimed.

Karl explicitly requested a blank CXL capture library. With CXL observed closed, moved six generated folders outside the container: RoutineCaptures, ReferenceDrafts, RelayedWatchCaptures, ReferenceBeatAssets, CaptureJournal, AuditSummaries. Archive: /Users/karlwatson/Developer/ScratchLab-CXL-Review-Fix-20260913/archived-test-captures-20260913T121058. All505 moved files hash-verified, and one valid camera restored within the external archive from the untouched pre-install backup. After launch, ReferenceDrafts/RoutineCaptures/RelayedWatchCaptures contain zero files. Calibration and MIDI mapping files retained unchanged; bundled examples retained. Do not record new diagnostic takes without acknowledging that this repopulates the blank library. No old capture was permanently deleted. Installation backed up507 support files/preferences and the previous app at /Users/karlwatson/Developer/ScratchLab-CXL-Review-Fix-20260913/evidence/before-install-20260913T120857.

## Implemented and evidence

- Missing Baby second camera: a late Watch Stop refresh replaced the mutable sidecar while primary mux awaited. Finalization now owns/passes the completed camera attachment through to the final sidecar. Both success/failure paths preserve it.
- Startup recovery separately quarantined a valid second-camera movie as an orphan after the first install. That file was preserved in Quarantine and backup. Recovery now exempts only the exact take-bound, hash-verified attachment. Valid/changed/wrong-take/repeated-recovery regression passed. First launch's one missing original path is documented in after-launch-1.json, not misreported as preservation of all463 paths.
- Supplied two-take Baby ZIP SHA0f19e1d0e67f43178b559d655cadf6f76e4170ddb97c3b8ad96edf364ea47d8c: all23 original artifact references valid. Recovered both untouched camera movies into ~/Downloads/session_2026_09_13_cxl_baby_scratch_90_bpm_recovered_second_cameras.zip (SHA8241deb40b53f3b19d69f1ef19fca84298865a02db574b601e9a8b6c3f26e518). Decoded camera audio matches each WAV exactly; association established, physical absolute sync not independently measured. Original ZIP/sidecars/bounds/preferences not rewritten. Take2 preferred2; repetition1 begins-0.6667s before media and needs review if selected. Both original Watch Stops timedOut.
- Approve & Save Capture runs strict existing approval, saves locally, then opens existing raw ZIP save dialog. Cancel/failure leaves approval intact; nearby Save Capture retries, approval-only remains. No movement-check approval or evidence bypass. Inline180pt same-player recorded video/audio beside focused bounds; start/end preview and up to4beats rest context without editing source/rest bars.
- Camera recovery means changing recording camera (Karl's final correction), not undoing bounds; no Reset Bounds feature. Between-take main/second camera selection and reconnect; stale readiness invalidated; capture/finalization locks preserved. Explicit portrait90/270/landscape orientation remembered per secondary device and applied to preview/recording; active take owns frozen angle.
- Mac Searching vs iPhone Connected: listener failure left advertising true and retry idempotently stuck; an unready connection could retain Connected. Added Mac Reconnect iPhone relay/discovered peers and iOS Reconnect Mac, clear failed listener state, require ready connection, reject stale ready callbacks and clear waiting labels. User reports failure even with camera OFF; do not attribute solely to Continuity Camera. Physical Watch reliability remains unverified; no privacy/signing reset performed.
- Karl confirmed KEEP four attempts of the SAME variation per take with a preferred repetition. Different variations belong in separately labelled takes under current one-pattern-per-take metadata. No capture-structure or automatic-training change.

## Verification and cleanup

Final scripts/build.sh all gate6 exit0: Python87; iOSDebug, universal fullMacRelease, universalCXLRelease, WatchRelease succeeded. gate5=179unique/358executions, camera-routes1=23/46, gate6=98/196. Union269unique,600executions including repeats, zero fail/skip in these successful runs. All482 build-input hashes match. All169 library assets/provenance verified in built apps before cleanup. Test JSON/xcresult/logs retained. Earlier introduced compile issues and gate2's one stale beatOutputRoute source assertion fixed; no disabled tests. Same3 historical Tear methods are outside selected scope, full suite NOT run. See final-test-accounting.json and verification.json.

Karl requested freeing Mac/Developer space. Removed62 explicit generated build/cache directories and redundant signed staging app copies, 40.3GB observed free-space gain, 48.2GB free immediately afterward. Preserve source worktrees/Git, captures/backups, reference libraries, Claude/MKV audit artifacts, test results/logs and staging receipts. Exact paths in evidence/developer-cleanup.json. Build products/caches now need regeneration before another install; do not follow stale below handoff paths assuming those products exist. No Claude audit/rebuild repeated. No external MKV drive required for installed app/library.

## Remaining physical checks

The app was reopened blank. Portrait preview/recording, a fresh dual-camera export and actual Mac-to-iPhone/Watch relay remain operator checks, not software-proven successes. Prior Rane headphone/direct-Mac-meter observations and Seventy-Two/Twelve acceptance remain open. Legacy Python validator camB_metadata/reference_tear_evidence support and three baseline Tear failures remain separate tasks. Do not claim a final CXL handoff-ready hardware PASS without checking these. No model training, automatic approval or public release performed.

--- Previous handoff (historical; current state above takes precedence) ---

# Current CXL integration — installed, physical check pending, 13 September 2026

Source /Users/karlwatson/.codex/worktrees/a4aa/ScratchLab; branch codex/finish-reference-library-20260913. Completed libraryd26adc2 was pushed. Free-app/deferred-battle docs checkpoint27e3ee1; Claude3558128/5d7bd19 integrated as8c94247/bc61106 after source/xcresult review; Wellington academy subscription/teacher tools/classroom battles saved for later inbd41ddb plus explicitly requested persistent-memory note. Current follow-up source/docs are being checkpointed and pushed; resolve final hash from Git.

Installed/opened ~/Applications/ScratchLab CXL.app, executable SHAeb4fa86d704b43f5159e00d308ee6cbcd6d8f75d8584b3737fa3bcaaf17bd168, verified PID82699 at launch. Stable Apple-issued signing/team2DDKGL33BU and bundlecom.machelpnz.scratchlab.cxl-authoring retained via scripts/stage_cxl_mac.py. Old app and371 support files backed up under ~/Developer/ScratchLab-CXL-Integration-20260913/evidence/before-install-20260913T104338; all371 unchanged immediately after launch, including67 protected capture/Watch/beat files. No forced quit: no installed process was present on repeated checks. Internal Apple Development pilot, not a notarized public release. Full learner app names remain ScratchLab; only CXL installed.

Implemented: Claude's optional preferred repetition/reviewer/time and portable bound review metadata; repaired earlier unapproved-take notes lost during multi-take ZIP export; CXL backing preview/count-in/beat now follow AHHH output, with Rane ONE leftUSB1/2 versus scratch rightUSB3/4. Native device/UID/map readback before playback and after count-in, actual route saved in take audit, selected missing Rane refused. The scratch recording tap stays separate; original beat PCM/timing and scratch-only/beat-only/scratch-with-beat exports are preserved. Mac selection still follows system output. No delayed monitoring substitute or guessed other-Rane bus.

Verification: scripts/build.sh all exit0, Python87, iOSDebug, universal fullMacRelease, universalCXLRelease, standaloneWatchRelease. combined-2:508 unique/1016 executions=1012pass/4existing skips/0fail; downstream MacCameraPreviewViewTests33unique/66executions allpass. Final selected coverage541unique/1082executions=1078pass/4skip. The same3 pre-existing Tear methods were explicitly excluded, not passed; full suite not run. Earlier focused60/120 pass; initial compile failure and interrupted pre-routing combined-1 retained and superseded.568 input hashes accounted for: production unchanged after final gate; only the documented stale audit-label expectation changed and was separately tested. All169 library assets and manifest/provenance verified in iOS/fullMac/CXL and signed candidate; no MKV audit/rebuild/training repeated. Source drive is unmounted and not needed for installed library/capture.

Evidence/results: ~/Developer/ScratchLab-CXL-Integration-20260913/RESULT.md and evidence/{INTEGRATION_REVIEW.md,combined-2-summary.json,audit-route-followup-summary.json,gate-status-2.json,source-integrity.json,installation.json,after-launch.json}. No Xcode/tool build process remains running at this checkpoint.

Pending user question: in reopened CXL choose Rane output, load AHHH, preview backing, cue both decks and scratch right with fader open; can both beat and scratch be heard in headphones? Await literal outcome; no hardware pass inferred. Direct-Mac coloured AHHH meter also remains unreproduced; Claude added regression tests only, no production meter fix. Later: short timed capture/preference/notes/stems/reopen check, optional dual-camera alignment, separate Seventy-Two/Twelve acceptance. Same-iPhone Continuity Camera plus reliable Watch relay remains unverified and optional. Python validator's older Baby assumptions and rejected tear-evidence/camB-metadata are a separate follow-up; no weakening. Preserve both Tears library passes and other documented source uncertainties.

--- Earlier handoffs (historical, superseded where the current record differs) ---

## Current — Claude follow-up complete in software, 13 September 2026

Source: /Users/karlwatson/Developer/ScratchLab-CXL-Claude-Followup-20260913/source, branch codex/cxl-claude-followup-20260913 (base 673b3ee). Local commits only, no push/merge. Codex integrates and pushes. LocalReferenceLibrary is the unchanged V1 external symlink; never stage it.

1. Direct-Mac AHHH meter: NOT reproduced in software, no production change. Real controller meters System Default (MacBook Pro Speakers) with fresh silent callbacks and across explicit-device to System Default rebinds; Mac-route WAVs are finite full-scale PCM; installed CXL source equals this branch. Regressions in commit 3558128. Needed physical check: AHHH output = Mac, AHHH loaded, scratch, read the meter label (Unavailable / Silent / frozen dBFS / moving) and the "AHHH playback:" route line. Result decides the layer. ../evidence/task1/RESULT.md.
2. Preferred repetition: Mark as Preferred / Clear (single selectedRepetitionIndex; approval unchanged), mark persisted in drafts, Save Capture adds bound notation/*_reference_review_metadata.json (1-based number + 0-based index, original media hashes, notes, late-Watch rebinding, second camera). Movement checks: notes only. ../evidence/task2/RESULT.md.
3. Gate: scripts/build.sh all via ../evidence/bin/xcodebuild exit 0 — Python 87 OK; 455 selected tests x2, 0 failures, 2 pre-existing skips; iOS/full Mac/CXL/Watch builds. Three ReferenceTearEvidencePipelineTests fail identically at 3558128 before task 2 and were skipped (not investigated). Full XCTest suite not run. Not installed.
4. Open: python validate_session.py rejects reference_tear_evidence/camB_metadata in current CXL ZIPs (pre-existing); physical meter check; physical Mark/Clear/Save Capture check on the installed build after Codex installs.

--- Earlier handoffs (historical state) ---

Latest clarification: user wants four4-beat scratch slots with4rest beats between. Current2-bar phrase setting gives4scratch+4rest beats per slot, repeated4times, with rest after the fourth slot plus the existing tail bar. At95BPM the whole sequence including count-in is25.263s; saved media~22.737s. Explained that canonical workflow currently treats slots as repeats of one variation; no rest/variation schema or capture timing was changed.

--- Preserved reference library and product decisions ---

# Current handoff — reference library complete, 13 September 2026

## Latest product decision and Claude progress

Karl asked to save live-battle/private-avatar/automatic-judge ideas for later and assess keeping the learner app free before continuing. Decisions and sourced funding arithmetic are in docs/free_learner_pilot.md; deferred ideas are in docs/future_product_ideas.md. The immediate sequence is CXL reliability and a small teaching set, then a three-skill learner loop and roughly ten learners for four weeks. Replace mandatory learner payment with payer validation from sponsors/institutions. Sponsorship is a hypothesis, not a secured business model. Watch is optional CXL research only with a useful question; learners must not need it. No runtime Watch removal, scoring or advertising integration occurred in this documentation slice.

Claude's pasted progress and worktree were inspected: branch codex/cxl-claude-followup-20260913 at3558128, with dirty task-2 preference/export changes, no final HANDOFF_TO_CODEX.md and an active isolated xcodebuild gate. The meter fault was not reproduced and no production repair was made. Do not promote the passing controller tests to an operator pass. Do not interrupt the gate, merge a moving working tree or duplicate its work. After final handoff, review source/tests/known baseline failures, integrate with the completed library, then stage and arrange the exact physical capture check. Current planning changes were checked as documentation only; no concurrent Xcode gate was started.

Worktree: `/Users/karlwatson/.codex/worktrees/a4aa/ScratchLab`.
Branch: `codex/finish-reference-library-20260913`, based on673b3ee.
Status: software verified; signed CXL candidate staged; installed apps/captures unchanged.
Result: `/Users/karlwatson/Developer/ScratchLab-Reference-Library-20260913/RESULT.md`.

The library now contains23 techniques,24 whole source sequences (both unresolved Tears source versions),95 available camera videos,72 exact source-PCM tracks and2 unchanged advisory models. Claude's completed repeat/camera audit was consumed, never rerun. The original MKVs, previous libraries and review observations remain intact. Final payload is `library-v2-checked/ReferenceExamples` under the result root; manifest SHA-256 `5583667aa9469a6d3f6e8a65e93dad2d331eba40145500068e003bc1ec553bc5`. The ignored LocalReferenceLibrary symlink points there. No source drive is needed to build with this prepared payload; rebuilding derivatives does require the originals and audit.

Shared V2 catalogue/view supports source lesson titles, full-sequence playback, generic audio choices when roles are unknown, and both Tears source passes. V1 remains supported. Metadata checks support all23 existing nominal integer BPM labels, including both Tears passes. Original title aliases clarify Orbits as2-click flare(orbit), Dicing asDicing(transform tears), and Long-short tips asLong-short tip tears; legacy class/model IDs are unchanged. Full tempo candidates, title-card/source hashes and original observation scopes are in the final provenance. Nothing was trained, filtered for hum, canonically approved, or assigned a guessed sync correction. Nine unconfirmed audio roles, Cutting's absent camera2, unresolved Tears pairing, unobserved speech-free boundaries and physical absolute A/V sync remain explicit.

Verification completed: new builder6, metadata3, legacy builder5, capture fixtures84 Python tests pass.25 unique XCTest /50 executions pass,0 failures/skips;285 actual camera/audio compositions decoded and compared in EACH configuration(570 total). Shared advisory service8 and actual rebuilt-Baby model compatibility1 pass; the latter produced71 advisory windows with0issues and does not prove accuracy. scripts/build.sh all passed with isolated output/cache/test-host paths and two affected XCTest suites; separate iOS Release passed. Full Mac and CXL are universal arm64+x86_64; standalone Watch also passed. All169 assets and final manifest verified inside iOSDebug/Release, fullMacRelease and signedCXL. Full XCTest suite, UI/speaker and hardware acceptance were not run. Existing compile warnings and test-host linkd diagnostics remain in logs. No new Xcode builds are planned in this completed turn.

Signed candidate: `staged/ScratchLab CXL.app` under result root, executable SHA-256 `af50444f378327896691173510fcf18a2f04117fa0ce5346ee42763c59351dcb`. Mandatory stage_cxl_mac.py retained team2DDKGL33BU, bundlecom.machelpnz.scratchlab.cxl-authoring, Apple certificate chain, designated requirement, permissions and entitlements. Receipt beside app. This is an Apple Development internal candidate, not a notarized public distribution. Installed CXL remains SHA`1567a41bacd9e76508235132cfce77ec8bc8929c6c667608571fc01d9a1b5eb7`; last observed PID91078. Do not overwrite an active capture. Coordinate deployment after reviewing the capture fixes below to avoid repeated installs.

## Claude follow-up prepared at Karl's request

Karl asked if CXL can identify the best1st/2nd/3rd/4th repetition. Existing Select for Approval and Save for Later retain the selection/review notes locally without canonical approval, but the general choice/notes are omitted from the raw Save Capture ZIP. This gap is not repaired by the library work.

Karl then requested a Claude prompt to use his remaining subscription. Prepared clean worktree `/Users/karlwatson/Developer/ScratchLab-CXL-Claude-Followup-20260913/source`, branch`codex/cxl-claude-followup-20260913`, from673b3ee, with the old V1 resource symlink deliberately retained for that branch's reader/tests. Prompt: `../CLAUDE_TASK.md`. It assigns, sequentially:
1. Fix actual generated AHHH app metering on direct Mac output; no delayed monitor or fake input/MIDI meter.
2. Reuse the existing optional preferred repetition state, clarify its UI and preserve the recommendation/notes in validated portable review/export metadata without approval or changes to raw media.
3. Run isolated affected tests and platform builds, review the combined diff, make local verified commits and write `../HANDOFF_TO_CODEX.md`.

The prompt was supplied to Karl; Codex did not launch Claude or claim it is running. Its build coordinator file now exists: `/Users/karlwatson/Developer/ScratchLab-Reference-Library-20260913/evidence/CODEX_XCODEBUILD_COMPLETE`. Claude can use the Xcode slot. Do not duplicate its capture work in this root; inspect its handoff and commits when Karl returns them, merge only reviewed changes, and preserve both branches' workflow notes. Root commits/pushes are authorized by the session. Claude was asked to leave local commits for integration, not push.

Latest earlier timing clarification remains unchanged: a2-bar reference phrase at95BPM allows4scratch beats plus4rest beats per slot, repeated4times, including rest after the fourth slot and the existing tail. This branch adds no new capture timing or variation schema.

--- Previous CXL delivery context ---

## Current — CXL second camera installed, 13 September 2026

Active source: /Users/karlwatson/Developer/ScratchLab-CXL-Delivery-20260913/source, branch codex/cxl-delivery-20260913. The user explicitly required second camera in this build, distinct CXL naming/opening, safe Developer cleanup and commit/push. Optional native local/Continuity camera is now implemented: portrait preview/recording, common Record/Stop, original host-relative timing, bounded 15-second finalization with late-commit protection, coverage diagnostics, two-camera/one-audio review, saved-draft retention and raw/approved exports. Menu contains exactly23 collection techniques. No extra training eligibility or inferred Watch motion.

scripts/build.sh all final-2 passed exit0:135 unique XCTest/270 executions,0failed/0skipped/runtime warnings; Python84; iPhone/iPad, universal full Mac Release, universal CXLRelease, standalone Watch builds passed. New real-media raw archive test exposed missing camB/camB_metadata probe support in final-1; fixed with explicit video/JSON handling, unknown artifact rejection retained. Earlier catalogue run separately tested every23 identity through finalize/reopen/ZIP. Full XCTest suite and hardware acceptance were not run. Evidence ../evidence/named-install/RESULT.md; all514 build-input hashes unchanged;253 resource assets verified.

Installed/opened ~/Applications/ScratchLab CXL.app; CFBundleName/DisplayName ScratchLab CXL, full Release remains ScratchLab. Stable bundlecom.machelpnz.scratchlab.cxl-authoring, executable/moduleScratchLab, team2DDKGL33BU and Apple-issued certificate retained via scripts/stage_cxl_mac.py. SHA1567a41bacd9e76508235132cfce77ec8bc8929c6c667608571fc01d9a1b5eb7, PID91078 at verification. Prior app and322 app-support files cloned/hash-verified;67 capture/Watch/beat files remain byte-identical after opening.38 derived AuditSummaries refreshed on launch, originals remain backed up; no raw evidence changed. Signing and installation receipts are under named-install. Apple Development internal pilot, not Developer ID notarized or sent to CXL.

Same-phone limitation: Continuity Camera requires locked iPhone; the existing foreground/timer-based Watch relay is not guaranteed to keep running on that same phone. USB helps connection but does not establish background relay. UI and guide disclose this. A native in-app iPhone recorder plus relay would be a different integration and needs hardware testing. Watch remains optional; physical same-phone simultaneous capture has NOT passed.

Cleanup removed53 specifically identified old compiler object/cache directories (15.32GiB allocated before removal). Retained source/Git recovery, datasets, recordings, reports, xcresults, previous apps and audit artifacts. Exact paths in cleanup-result.json. The Claude audit checkpoint was already pushed; the four subsequent media-review workflow documents were committed/pushed separately as a2e1a57 on codex/cxl-mkv-audit-20260913. Ready worktree's original seven dirty files remain preserved, with their audio fix carried into this branch. Do not stage LocalReferenceLibrary (external symlink).

Remaining: direct-Mac in-app AHHH meter defect is not fixed; no delayed monitoring substitute. Physical dual-camera preview/recording, orientation/alignment, export/reopen and Seventy-Two/Twelve acceptance remain. Appshot and trustworthy platter-pause evidence remain unresolved. User's latest duration question: at95BPM one bar is240/95=2.526s; reference plan4repetitions+tail records~12.632s; separate1bar count-in makes~15.158s total. No rest bars between repetitions currently. Movement check remains manual stop.

--- Earlier handoffs (historical state) ---

## Current handoff — 13 September 2026: exact23 capture catalogue complete in software

Active source: /Users/karlwatson/Developer/ScratchLab-CXL-Delivery-20260913/source, branch codex/cxl-delivery-20260913. Karl corrected the scope to ONLY the23 reference-collection techniques. The picker now uses exactly that set, preserving the separate Original Flare/Tips/Reverse Cutting labels and decoding legacy2/3-click Flare drafts. No extra practice/combo choices, training expansion or automatic recognition/approval claims. Source is uncommitted and not installed.

Final scripts/build.sh all exit0:116 unique selected tests/232 executions all passed, Python84 passed, iPhone/iPad/universal full Mac/universal CXL/Watch builds all succeeded. Every23 menu choice was finalized, saved, reopened and exported as a real fixture ZIP in both configurations. No full-XCTest-suite or hardware-pass claim. See ../evidence/capture-catalogue/RESULT.md and tests-catalogue-3.xcresult under ../evidence/second-camera. Earlier41-option runs are superseded for menu scope. An old package fixture now checks specific errors through full verification with its beat inputs still present; production validators were not weakened.

Installed CXL remains SHAaecacd0d3a6c04d9dcfa45739079cb5b19da09c34631ac9a032848ac9955e23a. Previous signed ZIP stays unchanged. No app was sent or newly installed. Continue the already-authorized optional-second-camera and direct-Mac-output meter work below before calling the combined candidate ready. Latest executable from the prior raw-build path was no longer running at the last check, but verify current process/state before any replacement. Continue to isolate products under second-camera rather than overwriting the previous running output path.

## Active work — 13 September 2026, camera and direct-output meter (unfinished)

User requires optional second iPhone portrait camera beside Mac landscape capture; missing second camera must not block primary recording. User also confirms direct Mac output is audible but the coloured in-app AHHH meter stops; Rane output drives the meter. Delayed Mac monitoring is unacceptable for performance timing. No audio-meter fix is implemented or verified yet.

Uncommitted second-camera implementation spans SecondaryCameraRecorder, MacCaptureEngine, shared sidecar evidence, saved drafts, raw/approved exports, two-camera review, project membership and tests. This is unfinished: optional finalization needs bounded timeout, review failure cleanup and metadata validation review. Four new SecondaryCameraTests passed in both configurations in the retained catalogue run1. The old package fixture ordering/verification assertions are now corrected and pass in final catalogue run3. All platform builds passed for the combined source, but camera finalization reliability and hardware acceptance remain unfinished. Evidence: ../evidence/second-camera/ and ../evidence/capture-catalogue/. Keep previous signed package unchanged.

Protect the running app: last observed PID75155 executes ../evidence/gates/products/CXLRelease/ScratchLab.app, not the installed app. New wrapper isolates outputs under ../evidence/second-camera/gates and watch. Do not overwrite the live build path. A silent isolated route probe received tap callbacks on both Rane and Mac speakers; this does not reproduce or fix the actual controller/UI meter bug. Direct Mac output preference and built-in speakers were confirmed. Next audio diagnostic should exercise the actual playback controller; never substitute input level or fabricated peaks.

The capture-catalogue task prompted by the missing 6:35 AM screenshot is now complete in software as described above. Do not restore the old seven-item list or the superseded41-item proposal.

## Current CXL delivery slice — 13 September 2026

User explicitly prioritized the capture app over complete routine coverage. Active source: /Users/karlwatson/Developer/ScratchLab-CXL-Delivery-20260913/source, branch codex/cxl-delivery-20260913, base04727e94921cfe523ba4ee31dd77439b64e25227. Existing seven-file reference-audio fix copied into this isolated worktree; original Ready source and installed app preserved. No commits/pushes in this slice. No active builds remain.

Completed optional-Watch policy across shared validation/session, exact package manifest/writer/reader, coordinator and CXL wording. Explicit notRequested/unavailable motion warns, never invents wrist data; pending/failed/mismatched/conflicting linkage remains blocked. No-Watch package export/reopen checks real sidecar absence. Repetitions, fader, timing, media and movement-check approval restrictions remain.

Final scripts/build.sh all exit0 with isolated focused wrapper: Python84/84;244unique/488executions passed,0failed/0skipped; CXL universal Release, full Mac universal Release, iOS and Watch builds passed. Full regression suite is deferred. Retained first run failed only old assumptions corrected before the passing rerun. Tests/receipt/report: ../evidence.

Signed candidate: ../package/ScratchLab CXL Pilot/ScratchLab CXL.app; delivery ZIP ../package/ScratchLab-CXL-Pilot-20260913.zip. New binary SHA8069134fdba5bafec842a479365be5ad282f4333bf9376ee5f6bfd2cc7afd439. Mandatory staging script preserved team2DDKGL33BU, bundlecom.machelpnz.scratchlab.cxl-authoring, permissions/entitlements and Apple/team designated requirement. macOS15+, Intel+Apple silicon.253 bundled assets hash verified,23 starter examples. No external app symlinks. Apple Development signed INTERNAL PILOT, not Developer ID notarized; production Seventy-Two/Twelve hardware acceptance remains open. Quick start docs/CXL_QUICK_START.md explains clean capture, no-Watch setup, raw Save Capture, same-Mac Save for Later, later approval and separate package export. No portable saved-draft import is implemented.

Installed ~/Applications/ScratchLab CXL.app remains the prior SHAaecacd0d3a6c04d9dcfa45739079cb5b19da09c34631ac9a032848ac9955e23a; not replaced/launched. Captures and all original datasets preserved. Routine/MKV rebuild and further manual review are deferred under the latest user direction. Native Appshot crash, defensible platter pauses and physical draft reopen remain unresolved, not release acceptance claims.

Unexpected Xcode auto-edit: shared ScratchLabCXL.xcscheme now version1.8 with empty auto TestAction; preserved, not an authored product feature. LocalReferenceLibrary is an untracked external resource link, never commit it. Source/tests/build outputs belong to this delivery worktree; do not mix media-audit changes or overwrite original Ready work. Before authorized installation preserve old app/captures, require closed app and verify running executable against receipt. No app has been sent externally.

--- Previous handoff follows ---

## Current slice complete — reference audio fixed and installed

Work in /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/source on codex/cxl-capture-readiness-20260913. The completed integration was committed/pushed as 04727e94921cfe523ba4ee31dd77439b64e25227 on codex/cxl-dataset-integration-20260913; original 8469 stays clean. This new audio fix is not committed/pushed yet. Exactly seven source/test/workflow files differ. No active builds remain.

All 91 reference videos have no embedded audio. Shared reference playback now composes the chosen camera with its selected same-performance WAV in one unmuted player; native transport owns both tracks. The five new regressions cover all 273 camera/soundtrack combinations and compare actual decoded PCM with each selected source. Final focused21unique/42executions all pass, zero skips; Python84/84; required all-platform build and extra iPhone/iPad Release pass. Initial new-test AVAssetTrackSegment/sourceURL compile failure is preserved and corrected with a checked AVCompositionTrackSegment cast. Full regression suite is still deferred. All422 build inputs and253 bundled asset identities verified.

CXL installed at /Users/karlwatson/Applications/ScratchLab CXL.app, executable SHAaecacd0d3a6c04d9dcfa45739079cb5b19da09c34631ac9a032848ac9955e23a, verified running PID1594 at install. Staged through scripts/stage_cxl_mac.py with Apple certificate5C5FDEBBEAC7E2148567C91968CBBA6B6561D298/team2DDKGL33BU and existing CXL identity/permissions/entitlements. Prior app and268 captures/motion files preserved in evidence/reference-audio-20260913/install-backup. CXL had closed before installation; no force quit. Full Mac staged and iPhone/iPad Release built, neither deployed. Karl confirmed the reopened CXL reference playback check: Yes, audio follows each camera angle. This operator check is PASS; broader capture/rig acceptance is separate. No app was sent to CXL.

Karl clarified variations means different recorded performances. Read-only audit verifies175 source performances and all273 packaged camera/audio pairings; no crossed take/tempo/variant links found. Baby has eight takes with four angles each. CURRENT APP ONLY INCLUDES TAKE01 PER TECHNIQUE (23performances);152 other source recordings remain unbundled/unselectable. Three soundtrack options are not a performance picker. Original manifest's1575 missing angle-specific WAV names resolve to matching shared WAVs; eight Cutting angle2 videos remain missing. Do not imply all175 can be played in the app or that source synchronization is measured. No catalogue expansion was performed.

Evidence/report: /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/evidence/reference-audio-20260913/RESULT.md and link-audit/REPORT.md. Playback check is complete. Next: choose exactly one next slice from current request/TASKS. Optional Watch policy remains unchanged and queued. Avatar/AI-battle motion stays deferred until CXL delivery/physical acceptance. Keep original sources and captures unchanged. Stable signed staged receipts must be used for future app updates.

--- Previous record follows ---

## Current direction — checkpoint integration, then CXL capture readiness

On 13 September Karl explicitly authorized committing/pushing the completed work and creating a new worktree before the next slice. Checkpoint the 34 named integration/workflow files on codex/cxl-dataset-integration-20260913; keep generated assets, raw captures and model binaries outside Git. Pre-checkpoint audit matched all 422 final build inputs to the successful gate snapshot. Checkpoint receipts are under /Users/karlwatson/Developer/ScratchLab-Dataset-Integration-20260913/app-evidence/checkpoint-20260913; resolve the resulting commit/push from Git and that receipt.

Avatar and AI-battle motion work is deferred in TASKS.md under After CXL capture delivery. Next is the first unchecked task: separate optional Watch motion from ordinary canonical approval while retaining explicit absence, same-take identity and every independent approval requirement. Prepare a clean worktree at /Users/karlwatson/Developer/ScratchLab-CXL-Ready-20260913/source from the verified checkpoint on codex/cxl-capture-readiness-20260913. Reuse the verified external reference library through the documented ignored resource link; do not regenerate or copy the corpus into Git. No next-slice implementation has begun at this checkpoint. CXL delivery/physical acceptance remains the priority; no app has been sent or newly installed.

## Completed integration — verified, not installed

Worktree8469 / codex/cxl-dataset-integration-20260913. User explicitly expanded scope: CXL capture-only, separate full general Mac plus full iPhone/iPad; both reference examples/comparison and optional recognition. Implementation/builds are complete; no commit/push/deployment. Report: /Users/karlwatson/Developer/ScratchLab-Dataset-Integration-20260913/app-evidence/RESULT.md. Signed Mac candidates +receipts are in app-evidence/staged; iOSRelease in app-evidence/gates/products/Release-iphoneos.

App57unique/114executions pass; Python84capture+5packager tests; ML198unique applicable cases pass including real-model compatibility smoke16windows, no accuracy assertion. Required all-platform build passed with documented focused wrapper/full-suite deferral; additional iOSRelease passed. Each final app has23examples/253hash-verified assets (~355MiB), no externalresource symlinks. Watch has no dataset payload. All422final build inputs stable. Mac staging uses valid Apple identity/team2DDKGL33BU; CXL identity/permissions/entitlements preserved. No running build sessions.

Original dataset/model files/captures/installed apps preserved. Generated library is external at reference-library-v1 via ignored LocalReferenceLibrary/ReferenceExamples. New canonical approvals, model training, scoring changes, upload and publication: none. Native UI/physical acceptance remains pending. External Baby hand pilot has7mapping tests and syntax pass; browser security blocked local page; do not bypass.

Latest user decisions: reserve fresh expert-labelled CXL performances as held-out evaluation, all angles/repetitions kept together and excluded from training/validation/tuning. One front45-degree camera plus audio is acceptable for this evaluation; Watch optional. Watch purpose is future3D battling-DJ avatars, supplemental wristmotion only. Camera-based pose animation is an alternative; oneWatch cannot capture full body/fingers. Current canonical Watch requirement remains unchanged, and aligning it with that purpose is a separate follow-up policy task. Do not fabricate missing Watch/fader/platter evidence.

Before deployment preserve old apps/captures; use staged receipts, exact identities and closed-app check. No app currently installed from this integration. Do not repeat completed full-corpus inventory or retrain. Read docs/reference_examples.md and RESULT.md for exact files/limits/verification.

--- Earlier record follows ---

# External dataset inventory completed — 13 September 2026

Active worktree /Users/karlwatson/.codex/worktrees/8469/ScratchLab, branch codex/cxl-dataset-integration-20260913, starts clean at c6c81c947a119e8c4d2e4045cd3be6ae6c62fac4. The first queued dataset slice is complete. Only TASKS.md, DEV_LOG.md, AI_HANDOFF.md and AI_HANDOFF/next_prompt.md change in Git; no commit or push was performed. Original 35b5 and Downloads checkouts were not changed.

External deliverables: /Users/karlwatson/Developer/ScratchLab-Dataset-Integration-20260913/inventory/REPORT.md, build_inventory.py, test_inventory.py, output/ machine-readable ledgers and analysis cache, integrity/reproducibility/preservation receipts. Original dataset, archives, models, caches/windows, pilot and corrections remain outside Git and unchanged. No source-media extraction, model inference/training, app import, approval or deployment.

Verified 2,651 source files, 700 camera manifest rows, 23 classes, 175 named performances, 692 videos and 525 actual WAVs. Ledger resolves 1,575 nonexistent camera-specific audio references to the performance's shared angle-4 audio, leaving zero unresolved audio references. Eight Cutting angle-2 videos are missing; preserve but withhold their eight cache/window pairs (38 windows) from source-verified reuse. All 700 feature caches and 700 window files remain retained; 171,776 raw rows and 4,700 windows inspected. Historical processor/source hashes are absent, so legacy derivation remains unverified rather than being promoted by present-file hashes.

Quality: 3,187 off-image points in 256 caches. Existing MotionWindowBuilder clips these; 871 windows contain 5,078 clipped point occurrences including overlapping-window repeats. Zero unexplained parent-coordinate mismatches after distinguishing existing clipping. All 162,477 populated hand confidence values equal 1 and are uncalibrated; no record/fader observations found. Candidate edit-list mapping flags 2,700 silence-overlapping windows, 1,292 wholly within candidate silence. All take-order/duration checks match, but chapter-to-clip clock mapping is unverified; these are review targets, never proof of intentional holds or electrical fader state. Requested 30Hz samples are not actual frame PTS; hand identity remains uncertain.

All 18 pilot files and its ZIP preserved; 17 listed checksums and all five original/nested-ZIP/copy bindings pass. Both model hashes match transferred values and selected full-ZIP members. Most source-to-full-ZIP bindings use size/CRC only, explicitly not SHA member equality. The transferred exact validation-angle leakage audit was not rerun; current model/report identities and counts were checked. No unseen-performance accuracy or runtime-readiness claim.

Final verification is recorded in external tests.log (8 tests), output/integrity.json (8 checks), reproducibility.json (identical 11-ledger hashes and all 700 analyses reused), preservation.json (all originals and 416 previously tested app inputs unchanged). Initial diagnostics and intermediate receipts are retained. No app rebuild is needed for this external-data/documentation slice; prior all-platform build evidence remains applicable. No currently running tool/build session at completion.

Next bounded task, not started: extend the EXISTING Baby Take1 pilot with cached trajectories after mapping requested timestamps to real video frames. Keep off-image/missing points, hand switches, clock uncertainty and disagreements explicit; preserve downloaded operator corrections wherever found. See external REPORT.md checklist and ignored AI_HANDOFF/dataset-integration.md. Stop before wider re-extraction, retraining, app integration or deployment. Prior app/hardware unresolved topics below remain separate.

# Saved reference drafts installed — 13 September 2026

Latest requested next task is complete in software and installed. CXL can capture now and Karl reopen/review/approve later on the same Mac. New finalized takes auto-save; Save for Later flushes notes; Saved drafts/Open for Review restores original evidence, media URL, repetition selection/bounds, corrections/projection/provenance and notes. Reopening checks original WAV/MOV hashes, exact sidecar and allowed same-take Watch additions; approval/export gates unchanged. Missing/changed files reject. Saved movement checks stay ineligible. No portable draft import/export or migration of older captures. Keep original recordings/beat assets. New scratch after reopening creates a fresh authoring session. Physical operator acceptance is pending.

Installed app /Users/karlwatson/Applications/ScratchLab CXL.app, SHA312663f82c41047ae7aece9f33e6c1f2e71fe802cfb48c96d684e5bf6a8b963a, PID80774 at launch. All platform builds passed. CXL was absent on repeated process checks before replacement, so no user-close question or forced quit was needed. Existing Apple Development certificate5C5FDEBBEAC7E2148567C91968CBBA6B6561D298/team2DDKGL33BU used exclusively via scripts/stage_cxl_mac.py; identity/entitlements/permissions preserved; strict/deep/universal checks pass. Old SHA4a2f67da app backed up under evidence/saved-drafts/backup. Companions not redeployed. Computer Use launches exact app but Appshot still fails native pipe closed; process/hash verification only, not window/capture acceptance.

Evidence root /Users/karlwatson/Developer/ScratchLab-CXL-Pilot-20260912/evidence/saved-drafts. RESULT.md has full changes, counts, limits and operator check. Six new tests cover exact restart/later takes, late Watch then approval/export, movement-check refusal, file corruption/mismatch, failed save and rejected review persistence. focused-3:12/12pass. Broader final.xcresult338unique/676executions=665pass/11fail:5old mock approval tests each supplied0.799s fader coverage; corrected to800samples over15.98s without validator changes. One saved-draft restart test had runner exit0 without assertion, unproven cause, other configuration passed. Final affected recheck37unique/74executions allpass, including all6new tests and affected mock suite. Latest applicable results cover338selected cases; do not claim the first broader run passed. Three previously reproduced baseline Tear failures explicitly excluded; full suite remains deferred. Python84/84; final scripts/build.sh all exit0 for iOS/embeddedWatch, universal Mac Release, standaloneWatch. No running build/tool session. Final416 frozen source/build inputs match source-final-sha256.json. No warnings in xcresult summaries. Failed logs retained.

Completed saved-draft source follows parent checkpoint250945d on codex/cxl-pilot-checks-20260912; Karl authorized committing and pushing completed work before a separate worktree fork on 13 September. Resolve the resulting checkpoint from Git rather than treating the historical uncommitted/local-only notes below as current status. Only prior dirty docs were preserved and appended; source/UI/project changes plus new ReferenceDraftStore.swift are this slice. No raw recordings changed. TASKS first entry marked complete for software/installation, hardware check pending. The subsequently transferred dataset workstream is recorded in the ignored local file AI_HANDOFF/dataset-integration.md and queued next in TASKS.md. Its original absolute path is /Users/karlwatson/.codex/worktrees/35b5/ScratchLab/AI_HANDOFF/dataset-integration.md; carry this local handoff into the new worktree because Git does not include it. First slice is an external inventory/quality ledger and reuse plan; dataset sources have not been reread or modified here. Do not recreate the existing pilot or trigger retraining/bundling/deployment. Do not automatically proceed into Appshot/Watch transport/gesture grouping or a full audit. Those remain separate unresolved topics below. New operator action is a fresh reference take, Save for Later, restart and reopen from Saved drafts; no approval bypass.

# CXL repair follow-up installed — 2026-09-12

## Scope and current state

Use only /Users/karlwatson/.codex/worktrees/35b5/ScratchLab, branch codex/cxl-pilot-checks-20260912. Initial baseline e83401ff4287cbba7863c1fef5858a808be37627. First repair checkpoint ad3ad3d and follow-up250945dea878fb1c0599887a07cac4a55f6d9a59 are committed locally, not pushed. See followup-checkpoint.json in the evidence root. Prior session authorizes verified commits/pushes and in-place app updates. Preserve dirty Downloads checkout and original Recovery/source. No subagents requested.

Evidence root: /Users/karlwatson/Developer/ScratchLab-CXL-Pilot-20260912/evidence/save-playback-relay.

Latest installed Mac /Users/karlwatson/Applications/ScratchLab CXL.app, bundle com.machelpnz.scratchlab.cxl-authoring, universal arm64+x86_64, version1.0.1/build21, executable SHA2564a2f67da26562649172befa9080699b87ac7891b5c47a73092f2828d2941142d, PID73223. Karl confirmed CXL closed before installation; prior full bundle/preferences preserved in before-followup-install. Only preference changed: scratchlab.mac.scratchPrimaryOutput=macSystemOutput. System default verified MacBook Pro Speakers. Karl first replied Still silent then immediately corrected: no it works. Treat latest correction as operator PASS for direct Mac speaker audio.

Operator supplied session_2026_09_12_cxl_tear_95_bpm.zip from Downloads and asks why four performed repetitions cannot be approved. Save ZIP now has actual hardware evidence: CRC passes, all six unique manifest-hashed artifacts match, both embedded sidecar bindings match. Session26fde798 contains two takes (4.2s and13.9s), both explicitly movementCheck with repetitionCount0/countIn0/tail0; performing four phrases does not create timed reference boundaries. This was the diagnostic mode we requested for audio/export testing; explain the needed mode switch clearly. Both takes lack Watch motion: take1 start timedOut, take2 start failed (Message reply failed), both Stop unreachable. Earlier green connectivity did not establish successful recording. Both takes have calibrated fader-open coverage for their full duration; do not repeat the old missing-fader diagnosis for this ZIP. Read evidence/operator-export-approval-diagnosis.json. Next operator setup: New scratch, Capture -> Reference take (four repetitions), Apply Authoring Setup; restore relay/Watch readiness before recording. Reference mode uses one count-in bar, four repetitions, one tail bar and automatic stop. No approval bypass or retroactive movement-check conversion. Forward-up hardware retest remains unconfirmed.

## Implemented fixes and actual evidence

- Save initially failed before panel because late Watch Stop diagnostics changed the sidecar after immutable review binding. First repair allowed only same-take Stop diagnostic/audit additions and showed progress/error beside Save.
- Latest failure was DIFFERENT: fresh session237cdc48-e240-4a19-85fb-90ac432c6dd3/take001 received Watch motion eight seconds after finalization, appending watch_linked/watch_reconciled and linkedMotionCaptureID/FileName. Actual F73B6B capture has1058samples and matching session/take/start-command58fccf4d. Follow-up export verifies actual linked motion UUID/session/take/start command and permits only these additions plus allowed Stop updates. Original captured data, unknown fields, prior audit entries, immutable review/projection and original raw files remain unchanged. A different association/command or unrelated mutation rejects.
- Audio input previously forced primary AHHH output to Rane. Follow-up adds independent persisted Rane / Mac(system output) choice via existing output graph. Mac selection removes delayed duplicate monitor, survives input refresh and locks during take. Actual-route audit already persists device/UID/pair separately from capture input. Mac setting applied locally; operator audio PASS.
- Direction: first repair inverted exact Rane ONE MKII channel1 CC6 after Karl confirmed old take004 first decreasing run was forward. Fresh take has tiny -21step transient then +1734step main run(2.734–4.358s) then -1821steps(4.358–6.313s). Karl explicitly confirms forward then backward/pause/backward. Initial-byte inference was wrong for the fresh take. Follow-up REMOVES that inversion and restores increasing-forward decoder/fixtures; forward-up/backward-down Canvas tests pass. Raw old takes are not rewritten. Old take004 conflict is not universal calibration evidence.
- Pause question: ? means unknown, not pause. Fresh raw counter slows sharply around5.4s but continues changing; no repeated stable counter samples. Detector merges the backward strokes, and earlier small filtered reversal runs leave unknown gaps. Do not invent flat holds or classify packet absence as stillness. Pause recognition remains unresolved pending defensible motion evidence/calibration.

## Recurring Appshot issue — user additionally requested repair

Latest review question (11:17 screenshots): Karl identifies gestures1–3 of session26fde798/take002 as ONE completed Tear (forward, back, pause, continue back). ZIP candidates: gesture1 forward1.112–2.157s; gesture2 backward2.301–2.900s; packetGap2.900–3.043s; gesture3 backward3.043–3.636s. Current review edits are confined to one fixed candidate; no phrase-group or cross-gap joining correction exists. Reading1-tear asserts one hold INSIDE that candidate, not one complete phrase. Screenshot Gesture3 operator-added hold3.043–3.093s matches Add Tear Boundary's default50ms at candidate start, not the gap between gestures2/3. Do not endorse that placement as measured or label all three as separate Tears. Explain whole phrase vs directional parts; current safe recording of Karl's reading is an explicit saved review note, followed by Save Capture to export it. A complete structured correction needs a separate scoped implementation for grouping/resegmentation with operator provenance; no implementation requested or performed in this explanatory turn. The gap remains unknown in measured evidence. This take's gap differs from earlier237cdc48 slow-but-continuing counter evidence.

No verified repair. Capture of Finder succeeds. Exact installed CXL capture fails repeatedly before/after restart and with disableDiff:true: Sky Computer Use native pipe closed before response. Appshot hotkey host logs update_poll_failed and worker AESendMessage -600; managed helper keeps respawning. Matching SkyComputerUseService crashes show SIGTRAP at Swift Array.remove(at:) with helper image offsets6572452,7524484 and recursive traversal. Helper26.902.1000968 UUID63AF4DA3-EDB2-3F62-9A5B-7AC4A83FD471 matches bundled binary. Host26.908.40834/build8881; latest documented desktop release family26.908. No native helper source is present. Do not reset ScratchLab permissions, modify signed OpenAI binaries or claim restart fixed it. Local report/crash/log excerpt: appshot-diagnosis/REPORT.md. Nothing sent externally.

Computer-use skill was read at /Users/karlwatson/.codex/plugins/cache/openai-bundled/computer-use/1.0.1000968/skills/computer-use/SKILL.md. Use node_repl + @oai/sky for UI; no alternate UI technology. Codex itself is blocked by tool safety policy; do not bypass that restriction. Finder is a successful control. Current CXL app runs normally; earlier WAV/MOV descriptors were read-only.

## Verification

First follow-up focused run:53unique/106executions=104pass/2fail. New late-link test put motion JSON among routine sidecars, causing invalid export metadata. Fixed fixture placement to the actual relay directory (unique name, own-file teardown); no production bypass.

Final scripts/build.sh all using explicit focused wrapper: Python84/84;191unique=190pass/1optionalDEBUGfixture skip;382executions=380pass/2skip/0fail. Includes live tracker, controller decoder, direct routing, input-selection/persistence/capture lock, late Stop export and late link ZIP create/reopen tests. Signed iOS+embedded Watch, universal Mac Release and standalone Watch builds pass.461frozen Swift/build inputs unchanged. All logs and failed results retained. Full suite remains deferred under prior user instruction.

First repair had3unchanged failures also reproduced on pristine e83401ff: ReferenceTearEvidencePipelineTests.testClicksAtHoldAndGestureEdgesRetainIndependentTimes, testOpenAndClosedFaderKeepMotionIndependentOfAudibility, testRestoredSingleCandidateDoesNotInheritAnotherSelectedGap. Do not claim those passed. Prior direction/final union163unique and328executions=326pass/2skip remains historical evidence only.

## Signing and companions

Mandatory scripts/stage_cxl_mac.py used. Apple Development fingerprint5C5FDEBBEAC7E2148567C91968CBBA6B6561D298, team2DDKGL33BU, expiry2027-07-12. Stable designated requirement anchors Apple chain, same bundle and team. Never codesign --sign -; previous external staging script repeatedly reintroduced ad hoc signatures and Local Network denials. Entitlements/permission keys preserved; strict/deep verify passes. Another expired certificate shares this name: use exact fingerprint.

Previous iPhone1F80398A-96C8-537A-B0EE-821E186918B9/com.machelpnz.scratchlab and WatchFA341802-22F1-54A7-811C-68EB29F1BF0A/com.machelpnz.scratchlab.watchkitapp first-repair installs/launches succeeded. Karl reported Mac preflight Connected/green, and fresh Watch file actually arrived, but Stop was unreachable/start timedOut in sidecar. Companion follow-up builds passed; not redeployed. Avoid another companion install unless needed.

## Preserved captures and continuation

Original session54d8c669 takes001–004:12raw WAV/MOV/JSON copies and verified recovery ZIP, all-four-captures.json. Fresh237cdc48 take001: WAV/MOV/JSON plus linked Watch motion, fresh-operator-captures, fresh-recovery.json, CXL-237cdc48-take001-raw-recovery.zip. These raw backups contain no fabricated notation or canonical approval.

Follow-up checkpoint250945dea878fb1c0599887a07cac4a55f6d9a59 is local, not pushed. Save ZIP supplied and checked; current issue is reference-mode setup plus Watch recording failure. No app code changed for this diagnosis. Do not restart a full audit or repeatedly rebuild without a concrete new failure. Rane ONE is pilot evidence; Seventy-Two+Twelve acceptance remains separate. Appshot and pause detection are explicitly unresolved.


## 27 September 2026 — Batch 2 / Slice 3 MIDI-drain forensics complete; NO REPAIR

User-authorized diagnostic-only slice supersedes the earlier premature final-gate continuation for this task. Five named LivePerformedNotationTrackerTests methods reproduce: 10 grouped executions and 10 single-method executions across both plan configurations all FAIL; LLDB adds 5 failing executions, with seven drain snapshots (three cycles in one method). Total 25 executions, 0 passed, 25 failed, 0 skipped. No other tests run. Both configurations use Debug, not Debug/Release.

Root cause shared by all five, classification B: tests inject T+.01 through T+.10 synthetic event times, then no-argument Stop seals real time before those events. Slice2C's required inclusive endpoint filter correctly returns []; debugger proves full intended buffers remain intact before filtering, every event strictly after the sealed endpoint. Preview cleanup, failed start, generation/ownership and zero-epoch checks still pass. Each method fails alone too. All five bodies match original390fe80, HEAD and donor. Donor whole-array drain lacks the endpoint correction and must not be copied back.

Proposed smallest repair, NOT IMPLEMENTED: only LivePerformedNotationTrackerTests.swift, use existing explicit at:token: close helper with each fixture's final intended synthetic timestamp; retain existing assertions and add exact sequence checks. No production changes, sleeps/delays/retries/polling, weakened assertions or broadened tolerances. Await authorization. No invalid-Stop work, final gate, platform build legs, MacAnalyzerView audit, commit/push/install/hardware capture/Learner/notation export. Only four workflow documents appended; prior content/evidence preserved. Complete trace/classification/history/proposal and preservation receipt: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-slice3-midi-forensics-20260927T094617Z/RESULT.md.


## 27 September 2026 — Batch 2 / Slice 3 five-method MIDI fixture correction complete

Explicit user-authorized fixture-only slice. The five LivePerformedNotationTrackerTests methods placed synthetic events after a real-clock Stop; production's inclusive first-close filtering was correct. Only those five method bodies now share their exact final injected timestamp with testOnly_closeTakeMIDIEpoch(at:token:): T+.10, T+.06, T+.09, Tcycle+.01*cycle, T+.01. No padding/sleep/retry/poll/tolerance or production/helper change. All 32 original assertion calls retained semantically; 20 added checks establish explicit pre-close values/times/relative times and full drained-array equality.

Fresh isolated sandboxed macOS Debug test build exit 0. Each method independently: 1 distinct / 2 passed executions (five invocations total: 5 distinct / 10 executions); grouped: 5 distinct / 10 passed; complete containing suite: 128 distinct / 256 executions = 254 passed, 0 failed, 2 skipped; eight existing endpoint/boundary methods: 8 distinct / 16 passed. Total: 136 distinct / 292 executions = 290 passed, 0 failed, 2 skipped, 0 runtime warnings. Both plan configurations are Debug. Skips: unchanged testTake003RealStreamIsNotFlattenedByTheLivePath, missing take-003 artifact, once per configuration. Existing compiler warnings retained. Inclusive endpoint, nextUp/after-Stop rejection, delayed callback filtering, order, stale predecessor/successor isolation, immutable first close, retired ingress and invalid endpoint fail-closed regressions all pass. No newly exposed dependency requires a broader gate.

Production/project/resources/protected files and all unrelated dirty/untracked work preserved relative to entry; only five methods plus four append-only workflow records changed. Exact commands/results, source-only patch, assertion audit, 738-path inventory and final integrity receipt: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-slice3-fixture-correction-20260927T104544Z/RESULT.md. Bounded fixture correction complete; overall reconciliation/final candidate remains NOT VERIFIED. STOP: do not begin invalid-Stop repair, final gate/scripts/build.sh, platform build legs or MacAnalyzerView audit without separate authorization. No commit/push/install/hardware capture/Learner/notation-export work.


## 28 September 2026 — Batch 2 / Slice 4 invalid-Stop forensics complete; NO REPAIR

User-selected diagnostic-only task. Slice 3 checkpoint matches saved delta/status and all 738 inventory paths. Exact failing method: ReferenceAuthoringViewModelTests.testBridgeErrorAndInvalidStopTransitionAreSurfacedWithoutChangingPhase. Fresh isolated execution fails identically in both Debug configurations: after synthetic start failure, phase remains readyToRecord but invalid Stop errorMessage is nil instead of No recording is in progress. Independent ReferenceAuthoringSessionTests.testFinishRecordingRefusesWhenNotCurrentlyRecording passes both configurations. Two read-only debugger runs add two failures; first collector had wrong-frame variable-read errors, second captures exact state. Total 2 distinct methods / 6 executions = 2 passed, 4 failed, 0 skipped; no runtime warnings. Fresh isolated test-host build exit 0; no platform build leg.

Runtime proof: cancellation=false, expectedFinalizationToken=nil, readyToRecord, no takes, no consumed token, no draft store. Worker lines 577/578 returns makeUpdate before status read or domain finish; breakpoint hits: rejection 1, status 0, domain 0. Error is prevented from being created, not thrown then swallowed. Current/donor/HEAD/original 3316fe0 failing test byte-identical. Domain noActiveRecording guard/error dates to 71c4f47; donor/HEAD worker correctly maps it. The offending guard is in the earlier canonical late-finalization slice3 patch, not the completed MIDI fixture correction. Classification D/A/E; no test-staleness, cross-test-order or configuration explanation. Existing makeUpdate can persist an already-reviewed draft in other states, so do not claim universal write-free worker errors; this fixture has no store/take and no resource/artifact/export path is reached.

Proposed only: split cancellation/token-scoped no-ops from explicit non-recording Stop error using existing noActiveRecording message, retain all identity/consumption/unavailable/cancellation safeguards, strengthen narrow worker assertions. NOT IMPLEMENTED. Only four workflow records appended; production/tests/MIDI Slice3/protected files unchanged, donor unchanged. Evidence and full requested report: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-slice4-invalid-stop-forensics-20260927T105955Z/RESULT.md. STOP for separate repair authorization. Overall candidate UNVERIFIED. No final gate, scripts/build.sh all, platform build legs, MacAnalyzerView audit, commit, push, install, hardware capture, Learner or notation-export changes.


## 28 September 2026 — Batch 2 / Slice 4 invalid-Stop repair verified

User-authorized narrow repair: only ReferenceAuthoringWorker.stopRecording initial guards in ReferenceAuthoringViewModel.swift. Cancelled calls retain existing no-op; non-recording token-scoped calls retain existing no-op; ordinary non-recording calls return a direct snapshot with the existing noActiveRecording mapping (No recording is in progress.) before status reads, token consumption or hooks. Direct snapshot bypasses makeUpdate autosave to satisfy no export-visible mutation. All subsequent token/unavailable/consumption/timeout/late-finalization logic and unrelated UI remain byte-identical. Domain/session/bridge/engine and completed MIDI Slice3 unchanged.

Hardened original worker regression retains all four assertions verbatim and adds state/counter/token/media checks. Two new deterministic methods cover configuring/ready untokened refusal versus token no-op, and existing-review rejection without autosave/draft error. No new sleeps/polling/retries/timeouts/tolerances; existing requested asynchronous regression harnesses unchanged.

Fresh isolated sandboxed macOS Debug test build exit 0. Both existing plan configurations: original: 1 distinct / 2 passed; independent domain: 1 distinct / 2 passed; hardened group: 3 distinct / 6 passed; token group: 3 distinct / 6 passed; late/ownership group: 9 distinct / 18 passed; full containing ViewModel suite: 42 distinct / 84 passed; directly affected Session suite: 61 distinct / 122 passed. Total: 104 distinct / 240 executions: 240 passed, 0 failed, 0 skipped, 0 runtime warnings. No failures/retries. Saved-draft endpoint/hash regression passes; no physical acceptance. All 738 source and 719 donor paths audited; only two code files plus four append-only workflow documents changed, all protected/untracked/deleted entries and HEAD/index retained. git diff --check passes. Complete evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-slice4-invalid-stop-repair-20260927T111020Z/RESULT.md.

Bounded Slice4 repair COMPLETE; overall candidate UNVERIFIED pending separately authorized final gate. STOP: no scripts/build.sh all, final gate, platform build legs, MacAnalyzerView receipt audit, commit, push, install, hardware capture, Learner or notation-export changes. Prior take-003 optional evidence gap and compiler warnings remain.


## 28 September 2026 — Batch 2 final verification/audit complete; candidate BLOCKED

User-authorized verification only. Preflight matches completed Slices 3/4: 738 source paths and 719 donor paths; exact Slice4 delta and Slice3/protected hashes retained. Canonical scripts/build.sh all ran once, unfiltered, with external build output/fresh sandboxed test identity only. Exit 65. Combined Xcode test plan:4950 distinct / 10172 executions = 9899 passed, 161 failed, 112 skipped. XCTest alone: 8,836 executions (8,563  passed,  161  failed,  112 skipped); Swift Testing: 1,336 passed. Counts cross-checked against parameter-expanded per-configuration xcresult nodes, not assertion counts. Seven methods differ between configurations, including the ReferenceTear physical-forward test's 30,182-byte JSON equality assertion at line240; causes unresolved, no retry. Python 87/87 passed, 0 fail/skip. All four subsequent platform legs (iOS, full macOS Release, CXLRelease, watchOS) NOT RUN because XCTest failed; no manual bypass/retry. No supplemental Python suite rerun after failure.

First divergence: CameraNotationOverlayTests.testCameraOverlayModeSwitchClampsControllerTimeToNewDuration expected coach duration>1 but got 0. Existing project resource de-scope makes bundled Baby notation lookup nil; adapter supplies empty model/zero duration. This test was outside Batch1's bounded gate; newly observed on pre-existing source, not a Slice3/4 edit. Other failure categories remain separately unresolved. Missing take003 remains an optional real-stream coverage gap, and the full plan discloses additional opt-in/hardware skips; none counted passed.

Read-only MacAnalyzerView audit confirms six full-macOS receipt defects: wall-clock Duration versus measured export duration; live/global detection used to confirm/write a selected take; mutable target/BPM/count-in inconsistent with saved take; prior export status carried to new take; URL-based ready header; corrected label value omitted from ordinary canonical export. Source-level findings, no hardware/UI reproduction. CXLRelease uses ReferenceAuthoringView instead. Smallest repairs proposed only; no production/test/export/Learner changes. Concurrency, unsafe device-property access, deprecated duration/clock APIs and release/test warnings classified without repair.

Only this append-only workflow documentation changed. Source/tests/protected untracked JSON, boundaryFindings, derivedInspectionIssues, offline fixtures/tests, existing deletions, donor and unrelated work preserved. Prior evidence 104 + 4,838 manifest records verified. HEAD/index/status set retained; git diff --check passes. Complete evidence, exact failures/skips, source trace, warnings and final preservation: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch2-final-gate-20260927T115019Z/RESULT.md. Candidate BLOCKED; STOP for separate authorization. No commit/push/install/hardware capture or repair.


## 28 September 2026 — Batch 3 read-only failure triage complete; candidate BLOCKED

User-selected forensic-only task; no test/build rerun or production/test/resource change. Entry exactly matches Batch2 final checkpoint:738source/719donor paths,HEAD/index/staged/status preserved. All84 failing method bodies match HEAD and donor. Preserved Batch2 totals remain161failed executions across84methods;77fail both configurations,7diverge. No new execution counts.

Eight clusters: C1 removed bundle-notation fixture47; C2 legacy recorded-demo timing/motion17; C3 removed-demo source/resource/metadata contracts11; C4 iOS evidence-owner source predicate1; C5 asynchronous MIDI learn/calibration/hot-cue test readiness5; C6 wrong-source learned-mapping publication1; C7 DVS logger completion criterion1; C8 ReferenceTear noncanonical JSON byte comparison1. C1–C3 total75methods/150failures; other9methods/11failures. Exact methods/assertions/configurations and per-cluster first divergence/history/confidence are in external report.

Camera first failure requests Bundle.main/Notation/baby_scratch.json. Offline file is a12-stroke authored deterministic template (969f2f1), not itself proven third-party. September26 intentionally removed whole archive-resource memberships and automatic demo playback; do not reverse that policy.47direct lookup failures plus17fallback/demo timing and11obsolete contract failures share that de-scope. Generic tests should inject deterministic data; retained Camera Coach/Notation Lab UI needs separate current-product reconciliation.

Highest-priority finding: queued applyLearnedMapping completion has no current-source/generation check. Configuration2 actually observes midi_test_iso_rane mapping while Pioneer is selected. Helpers matchHEAD/donor and date to945c4dd, notSlice3/4. Learn/calibration fixtures also wait50ms instead of complete persistence/main publication; failed calibration logs show refusal before learning is visible. DVS test treats file existence as completed write/status; ReferenceTear compares separate default JSON encodings of immutable input, likely key ordering but exactbytes absent. No configuration-option difference; shared default mapping files remain a confounder.

Skips56methods/112executions: A46externalfixture,C1hostaudio callbacks,G9opt-in/conditional; B/D/E/F0primary. take003 is1method/2skips, optional missing operator evidence. Liveoutputcapture,hardware-derived replay and real saved-session export remain evidence gaps; no hardware clearance inferred. Preserved full-gate Slice3five10/10,endpoint16/16,Slice4hardened6/6,token6/6,lateownership18/18,ViewModel84/84,Session122/122. No reopening/rerun justified. None of84failures directly tests the six MacAnalyzer receipt defects; same-file demo source assertions are not receipt coverage.

Next ONE proposed repair slice: C6 MIDI learned-mapping publication ownership acrosssource changes, including A→B→A; proposed files MacCaptureEngine.swift andMIDILearnEngineTests.swift plusappendrecords. Keep originating diskpersist, rejectstale runtimeeffects, add deterministic held-completion proof before code selection. NOT implemented or authorized by this triage. P0capture/metadata integrity outranks75fixturefailures. SeparateMacAnalyzerP0review/exportidentity work,thenMIDIharness andresourcecontract reconciliation,theniOSsourcepredicate/logger/JSONoracles. No sleeps/retries/tolerancewidening proposed.

Onlyfourworkflow records appended; protectedJSON,Slice3/4,domain,bridge,donor,offlineevidence andallunrelatedwork preserved. Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-triage-20260927T122932Z/RESULT.md. STOP for separate authorization; candidateBLOCKED. No source/test/resource changes,fullgate,platformbuilds,commit,push,install,hardwarecapture,Learner ornotationexport changes.


## 28 September 2026 — Batch 3 / C6 controlled reproduction complete; no production repair

User-authorized forensic scope. Entry matches the Batch 3 triage checkpoint: 738 source paths and 719 donor paths, unchanged HEAD/index/staged state. The existing testOnly_waitForMappingPersistenceQueue seam can finish real persistence while a synchronous MainActor segment holds queued main publication. Added one diagnostic test method only; no new production hook, sleeps, polling, retries or timeout changes. All existing methods/assertions remain unchanged.

Fresh isolated Debug test host compiled/linked. One focused invocation, both plan configurations: 1 distinct method / 2 executions / 0 passed / 2 failed / 0 skipped, with 12 assertion failures exposing the expected defect. Six scenarios per configuration: A→B and A→B→A violate runtime/legacy/calibration ownership in both; unchanged selection, cancel-before-event, cancel-after-successful-claim and rejected CC6 match current semantics. These 12 scenario executions are not extra XCTest methods. No full gate or platform build leg ran.

Real A persistence completes while runtime remains nil. After selection B, releasing the real queued completion publishes A, sets learned/legacy mapping and enables calibration. Returning to A before release also accepts the obsolete A1 completion; no fresh A2 reload is performed. Actual disk remains A-only. The first corrupted mapping write is applyLearnedMapping currentMIDIDeviceMapping assignment at11058. Earlier queued Learn/observed UI writes are also unguarded in source order. This proves the generic completion defect without claiming the original full-gate OS schedule or physical-device behavior.

Persistence and runtime ownership differ: preserve accepted origin-device writes but fence current-state publication by source ID plus selection epoch. No shared selection epoch exists today; connection, Learn request and calibration/curve generations have different scopes. ID-only protection cannot reject A→B→A. Audit also finds unguarded reload, calibration/mapping mutations, clear/error/status and associated curve effects; existing operation-generation/binding/source-observation guards must be preserved. Reference-authoring hardware readiness is not proven incorrectly ready by these synthetic tests. Disk save currently uses try? without a result; failed-save behavior was not injected and remains unverified.

Proposed future repair is limited to the selected-source publication boundary in MacCaptureEngine.swift, with focused MIDILearnEngineTests.swift regressions. No production change implemented. One additive failing diagnostic method plus these four append-only records are the only slice edits. Slice3/4, domain, bridge, capture Stop/drain, donor, protected JSON, media, receipt paths, Learner, notation export and unrelated work remain unchanged. Full report/traces/commands/counts/audit: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-c6-forensics-20260927T125324Z/RESULT.md. Candidate BLOCKED; STOP for separate production-repair authorization. No commit, push, shipping installation or hardware capture.


## 28 September 2026 — Batch 3 / C6 production ownership repair; focused verification complete

Explicitly authorized selected-source publication repair. Added MIDISelectionOwner(sourceID, selectionEpoch) under existing midiCaptureLock; actual selection transitions advance independently of reconnect success. Learn captures origin at initiation and validates it at atomic claim. Accepted origin-device persistence remains unconditional; selected-source main publication is fenced. Selection retires old runtime mapping and pending Learn/calibration/curve state. Central mutation/delete callbacks, reload positive/nil/error, learned legacy/status/curve effects and adjacent mapping UI publications share this owner. Existing connection/Learn/calibration/curve generations and binding/validation guards remain intact. No new lock or nested-lock path.

Production confined to MacCaptureEngine.swift; permanent C6 regressions in MIDILearnEngineTests.swift preserve the original diagnostic and assertions. Existing persistence barrier retained; a Debug-only callback deferral tests real successor state before old callback release. No new sleeps/polling/retries/delays/timeouts. A→B, ABA, same selection, cancellation controls, origin persistence,16stale-result operations, fresh A2 reload and calibration ownership pass in both configurations.

Final source:210distinct methods/420executions/420passed/0failed/0skipped. Including the initial4-method C6 run:428executions/428passed/0failed/0skipped. Complete focused suites183/366 plus bounded broader MIDI27/54. Two initially mistargeted source-selection selectors ran zero tests; corrected selectors actually ran both methods in both configurations in broader, and zero-test selections were not counted. No full gate or platform build leg; isolated Debug hosted-test compilation only.

738source/719donor path preservation audit; only two authorized source/test files and four append-only records changed. Slice3/4 and protected JSON hashes preserved;67Stop/drain/finalization/take/recording bodies identical; recordReceivedMIDICCEvent changes only its UI monitor fence. Donor, HEAD/index/staged state and unrelated work unchanged; git diff --check passes. Full commands, per-configuration counts, path classifications, lock review and preservation receipts: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-c6-repair-20260927T132233Z/RESULT.md.

C6 IMPLEMENTED / FOCUSED SOFTWARE VERIFIED. Overall candidate remains UNVERIFIED; other Batch3 clusters/final gate/platform and physical acceptance remain outstanding. Existing store-save error suppression and physical reconnect/audio behavior are outside this slice. STOP: no full gate, commit, push, installation, hardware capture, Learner, notation export, resources or MacAnalyzer repair.


## 2026-09-28 — Batch 3 MacAnalyzer take-bound forensic slice (NO REPAIR)

User-authorized scope: read-only production tracing and deterministic reproduction through existing seams. Canonical HEAD `79fb3ecd74d261de5f3fd1f8b1434b620077ae3c`; C6 complete, Slice 3/4 preserved. Overall candidate remains BLOCKED.

Evidence: [batch3-macanalyzer-forensics-20260927T133511Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-forensics-20260927T133511Z/FORENSIC-REPORT.md). The report contains the complete identity trace, twelve-field/ten-column authority matrix, all six first divergences, export-path comparison, proof boundaries and permanent regression proposals.

Findings: (1) Review duration uses sidecar wall span, while readable-audio export uses frames/rate; demonstrated 24 s versus 1 s, with exported actual duration 1 s. Proven duration defect is presentation-only, not corrupted wall timestamps. (2) A can display persisted Baby evidence while the confirmation adapter persists global B's Chirp/91 input to A. (3) mutable setup changes historical target/clock; Baby is the only canonical target, so changing to Chirp makes it unavailable. Saved export config/handedness correctly wins. (4) global export success can classify B as exported without membership/revision evidence. (5) non-nil URL drives READY FOR REVIEW before authoritative readiness. (6) ordinary review/export projections omit reviewDecision.label while preserving a corrected source flag; the separate reviewMetadata.labelOverride survives, and optional bound-beat export also carries the full sidecar.

No universal frozen-selected-take invariant is claimed: frozen capture configuration/evidence, playable artifact measurements, human review revisions and archive membership each own distinct facts. No serialized MacAnalyzer receipt or arbitrary older-take selector was found. Different-session reselection is the source-traced A/B path. No private SwiftUI action or complete ZIP/upload was executed; model reproduction and source-level adapter proof are identified separately.

Only code delta: one preserved additive forensic method in `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`, `CaptureReliabilityPhase1CoreTests.testMacAnalyzerTakeAuthorityForensicTwoTakeDiagnostic`. It characterizes current defects and is not a passing repaired-contract regression. Existing test content and assertions remain byte-identical. Temporary synthetic WAVs use the existing test helper; no recorded-media resource changed.

Execution evidence: final diagnostic 1 distinct method / 2 executions / 2 passed / 0 failed / 0 skipped, in `Configuration 2` and `Test Scheme Action`. All invocations 4 executions / 2 passed / 2 failed / 0 skipped. Initial two failures were the new diagnostic's incorrect assumption that Chirp had a canonical BeatPattern; current source contains only Baby. The new diagnostic was corrected to require Chirp unavailability and preserve the full existing fixture package. Initial source/log/result remain saved. No production repair, pre-existing assertion change, timing retry, sleep, polling or widened timeout. Focused hosted-test compilation only; no repository gate or separate platform build leg.

Recommended sequence: selected identity/confirmation -> saved historical comparison inputs -> complete review-decision export -> export membership/revision status -> artifact duration/readiness. Exactly one next repair proposed: selected-take confirmation/persistence, with identity validation and selected saved detection/confidence. Proposed future files: MacAnalyzerView.swift, minimal pure review adapter beside existing types in CaptureCore.swift, and permanent two-take tests in CaptureReliabilityPhase1Tests.swift. No engine/bridge/MIDI/Stop/drain/export-schema work in that proposed slice.

Integrity: final-preservation.json compares all 738 canonical paths and 719 donor paths. Expected delta only this appended diagnostic plus append-only TASKS.md, DEV_LOG.md, AI_HANDOFF.md and AI_HANDOFF/next_prompt.md. All production/protected files, C6 engine/tests, Slice 3 fixtures, Slice 4 worker/tests, domain and bridge preserved; path set, HEAD/index/staged/status unchanged; git diff --check passes. No commit/push/install/hardware/Learner/notation-export change, no repair of de-scoped media failures.

STOP for separate repair authorization. Do not treat this forensic diagnostic's final pass as proof that MacAnalyzer is repaired or the candidate is verified.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 1: selected-take confirmation ownership

Explicitly authorized Defect 2 repair only. Pure CaptureCore.TakeReviewContext binds existing session/take/media/sidecar identity and saved evidence; validates destination and evidence before constructing a decision. MacAnalyzer display/Accept/Correct/Unknown use captured context. No global detector/latest-media/setup fallback. Accept rejects missing saved detection; missing confidence stays nil. Human correction/unknown preserve raw missing state. Synchronous context-bound write and sidecar-URL cache isolate repeated take IDs across sessions. Existing acceptance vocabulary and sidecar schema unchanged.

Changed production only MacAnalyzerView.swift and a pure adapter insertion in CaptureCore.swift. CaptureReliabilityPhase1Tests.swift adds12permanent ownership tests; forensic diagnostic preserved byte-identically. Two existing source-wiring expectations updated for extraction and delegation strengthened; behavioral assertions preserved.

Final source:78distinct methods/156executions/156passed/0failed/0skipped in Configuration 2 and Test Scheme Action. Focused13/26, related43/86, broader22/44. All invocations182executions/180passed/2failed/0skipped: initial new exact-audit regression compared in-memory subsecond Date against persisted ISO-8601 precision. Fixture corrected to read its persisted baseline; equality assertion retained, production unchanged. Failed bundle/source retained. No sleeps/polling/retries/tolerances added. Complete SessionReviewMetadataTests and ReviewPresentationStateTests, selected core identity/sidecar/persistence tests and bounded GuidedCaptureReviewStateTests/CaptureConfigMigrationTests/RoutineFinalizationWatchMergeTests passed. No full gate or separate platform build legs.

Audit:738source/719donor paths; only3authorized code/test files+4append-only records changed. Fourteen protected view members exact; reviewPresentationState differs only in human-decision lookup. Defects1/3/4/5/6 remain, including mutable comparison, duration, readiness, export success and missing correction export. Existing core models/serialization unchanged. C6 engine/tests, Slice3fixtures, Slice4worker/tests, domain, bridge, Stop/drain, recorded resources, protected JSON and donor preserved. HEAD/index/staged/status/pathsets unchanged; git diff --check passes; no unexplained drift.

Full report/commands/results/selection/scope/hash evidence: [batch3-macanalyzer-slice1-20260927T135943Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice1-20260927T135943Z/RESULT.md). Existing wrong decisions are not migrated; other five MacAnalyzer defects and cross-process file races remain outside scope. UI is source-wiring verified, not manually exercised; no hardware proof implied.

MACANALYZER SLICE1 IMPLEMENTED / FOCUSED SOFTWARE VERIFIED. Overall candidate BLOCKED. STOP for separate authorization. No full gate, other repair, commit, push, installation, hardware capture, Learner, resource reconciliation or export-schema change.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 2: historical target/comparison authority

Authorized Defect3 only. MacAnalyzer now interprets the selected take from strict persisted sessionID/scratch/BPM/count-in/meter fields, validating sidecar identity/evidence via unchanged Slice1 TakeReviewContext. New pure HistoricalReviewInput bypasses CaptureSessionConfig's setup normalization for this historical projection only; existing decoder/source/schema unchanged. Missing/invalid/stale/unowned inputs are explicitly unavailable. No current-setup fallback or sidecar rewrite. Target, clock, first-cycle/full comparison, grid, viewport, overlay and BPM detail use saved authority; DEBUG overlay cache compares full target and evidence. Handedness has no identified consumer and remains untouched. Future capture setup remains mutable. Versioned CXL recipes are unsupported in the ordinary comparator; runtime canonical pattern version remains an unpinned risk.

Production changes only MacAnalyzerView.swift and inserted adapter in CaptureCore.swift. CaptureReliabilityPhase1Tests.swift appends14permanent tests; all pre-existing test bytes/assertions unchanged. Final221distinct methods/442executions/442passed/0failed/0skipped across Configuration2 and Test Scheme Action: focused27/54, comparison124/248, related43/86, broader27/54. All invocations492executions/484passed/8failed/0skipped. Initial4new methods failed in both configurations, exposing setup-decoder normalization and one nil-vs-saved-meter expectation. Strict raw-field adapter fixes the actual authority gap; coherent-flow regression asserts saved meter plus exact prior stroke/fader/timeline/score equivalence. Intermediate test-only decoder-helper compile error caused0executions; fixed with ordinary production JSONDecoder ISO8601 convention. Failed evidence retained. No timing workaround or weakened existing assertions.

Audit738source/719donor paths; only3authorized code/test paths+4append-only records differ. Twenty-two protected view members exact; whole comparison algorithm after input resolution exact except saved-meter projection. Slice1 context/actions/cache, Defects1/4/5/6, C6, Slice3/4, Stop/drain/domain/bridge, resources/protected JSON/export schemas/Learner and donor intact. HEAD/index/staged/status/pathsets unchanged; git diff --check passes; no unexplained drift.

Evidence: [batch3-macanalyzer-slice2-20260927T141828Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice2-20260927T141828Z/RESULT.md), execution-counts.json, verification-selection.json, scope-audit.json and final-preservation.json. No manual UI/hardware proof. Missing legacy fields unavailable; general decoder still normalizes elsewhere; current registry versions can change cross-version; synchronous sidecar decoding cost/cross-process changes remain risks.

MACANALYZER SLICE2 IMPLEMENTED / FOCUSED SOFTWARE VERIFIED. Overall candidate remains BLOCKED. Defects1/4/5/6 remain. STOP for separate authorization. No full gate, other repair, commit, push, install, hardware, Learner, media reconciliation or export-schema change.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 3: Phase4 precedence stop (NO REPAIR)

Authorized Defect6 trace reached the user's explicit stop condition: reviewDecision.label and reviewMetadata.labelOverride can disagree, and no safe precedence is established in current production, tests, history or donor. Decision introduced df4972a/2026-05-06; metadata added independently78fe5f9/2026-05-26. Both have live writers preserving the other. Metadata reviewedAt also changes on notes/quality/state updates, so timestamp precedence would misrepresent label chronology. Existing forensic test persists Transform decision plus Flare override; ordinary export omits Transform but preserves Flare and corrected provenance.

First loss: resolvedNotationExport reduces decision to labelSource/confidence; reviewDocument separately projects only metadata. Share/Save Copy/Upload use SessionArchiveBuilder.preparePackage/createArchive. Bound-beat export additionally copies full sidecar; ordinary projections remain lossy. Existing staged validation compares against those same projections and has no conflicting-human-label rule. Optional reuse of CaptureReviewDecision may permit additive compatibility, but no schema change/version decision is implemented.

Fresh read-only verification using unchanged Slice2 compiled products:18distinct existing methods/36executions/36passed/0failed/0skipped across Configuration2 and Test Scheme Action; SessionReviewMetadataTests17 plus forensic1. No new tests, production edits, build or repair acceptance. Exact report/trace/commands/results: [batch3-macanalyzer-slice3-20260927T144500Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice3-20260927T144500Z/RESULT.md).

Integrity:738canonical/719donor paths; all production/test/resource/schema/protected JSON bytes match Slice2. Only these4append-only records changed. Slice1/2,C6,Slice3/4,Stop/drain/domain/bridge and donor intact; HEAD/index/staged/status/pathsets unchanged; git diff --check passes; no drift. Defects1/4/5/6 remain.

STATUS:BLOCKED AT PHASE4, NO REPAIR. User explicitly required STOP before production modification when precedence cannot safely be established. Suggested decision for authorization: reject conflicting new exports pending human resolution while preserving legacy archives and both stored fields; alternatively specify which label field has precedence. No policy implemented. No full gate, commit,push,install,hardware,Learner,media reconciliation or other repair.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 3: Defect6 conflict-safe repair verified

Authorized policy: no human-label precedence. Shared SessionArchiveBuilder now preserves complete persisted CaptureReviewDecision plus separate raw detection; compatible legacy override remains. Pure resolver distinguishes absent/accepted/corrected/unknown/legacy/conflict/invalid. Conflicting populated labels fail closed with session/take error before archive production; timestamps do not select a winner. Invalid blank/corrected and self-inconsistent accepted/unknown representations rejected. Reference-bound new exports use same rule. Existing forensic Transform/Flare values retained; expected rejection replaces omission assertions. Optional fields only, schemaVersion strings/legacy decoders preserved; no historical sidecar migration.

Production only SessionExportCoordinator.swift. Test file CaptureReliabilityPhase1Tests.swift adds17deterministic regressions, updates forensic expectation, adds2required try annotations; all other old tests exact. Final147distinct methods/294executions/294passed/0failed/0skipped in both Configuration2 and Test Scheme Action. All invocations430/424/6/0; initial compile-only fixture error0executions; initial3new unprepared nil-slate/clap fixtures failed both configurations (6), fixed via real preparation without weaker assertions/production guards. Next68pass; finalfocused70pass; all failed evidence retained.

Integrity:738canonical/719donor paths; only2authorized source/test files+4append-only records changed. Whole View/Core/engine/worker/domain/bridge/Batch2fixtures protected. Slice1/2 methods unchanged and52executions pass; nine protected export members/raw-event projection exact. Defects1/4/5,C6,Slice3/4,Stop/drain/resources/protectedJSON/Learner/donor untouched. HEAD/index/staged/pathsets unchanged; only new statusentry is modified export service. git diff --check passes, no unexplained drift.

Evidence: [batch3-macanalyzer-slice3-repair-20260927T145517Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice3-repair-20260927T145517Z/RESULT.md), execution-counts.json, verification-selection.json, scope-audit.json, final-preservation.json; commands/logs/xcresults retained. Upload uses common preflight/new archive builder but existing cached ZIP reuse remains unchanged: no claim cached archives are migrated/current or network upload verified. No manual UI/hardware/full platform/final-gate proof.

MACANALYZER SLICE3 DEFECT6 IMPLEMENTED / FOCUSED SOFTWARE VERIFIED. Overall candidate remains BLOCKED/UNVERIFIED; Defects1/4/5 remain open. STOP for separate authorization. No full gate, commit, push, installation, hardware, Learner or recorded-media reconciliation.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 4: Defect4 forensic HARD STOP (NO REPAIR)

Proven: global SessionExportCoordinator success has no session/take membership or content revision; both MacAnalyzer Exported consumers ignore selection/current review. Validated context loses ownership proof when reduced to URL/size/name/session-date result. A->absentB/same-ordinal-other-session leaks; R1->legitimateR2 and current conflict retain stale success. A/B saved archives can both exist while coordinator retains only latest. Failed later request clears lastResult despite an earlier durable archive remaining valid. Multi-take A+B membership is legitimate. Share-ready already says Exported; cancellation hides it while ZIP remains.

Exact source-locked private Upload prepareArchive diagnostic reproduces stale A R1 reuse for A R2 and absent B within same session/cache name. Actual network not invoked; isolated job storage only. Cache hit conditional on lookup/actual naming match. Retry reuses old job ZIP without current-source validation; Slice3 still correctly rejects current conflict on new preparation. Classify cache as same Defect4 ownership repair, not separately resolved by fixing badge.

Recommended: builder-derived versioned semantic projection receipt keyed by(sessionID,takeID), member artifact/projection digests and separate whole-package membership/options digest; retain ZIP integrity separately. Manifest alone unchanged by review correction; raw sidecar bytes over-invalidate ordinary audit-only changes. Exclude generatedAt/analyzedAt from semantic identity, preserve persisted decision/provenance dates; include actually exported full sidecar where applicable. Separate operation status/current membership/cache validity; no new last-exported-take Boolean or timestamp precedence. No repair implemented.

Fresh diagnostics10methods/20executions/20passed/0failed/0skipped in both configurations; preservation73methods/146executions/146passed/0failed/0skipped. Final83methods/166executions/166passed/0failed/0skipped. All invocations186/178/8/0; initial compile helper error0executions, initial four new revision diagnostics failed both configs because generic kept-N filenames fail legitimate review ownership. Only appended fixture names corrected using LocalRecordingNaming. Failed evidence retained. No sleeps/polling/retries/delays added. Diagnostic tests intentionally assert current defects and must be explicitly converted under repair authorization.

Integrity738canonical/719donor paths:all production and pre-existing tests byte-identical; only additive diagnostic in CaptureReliabilityPhase1Tests.swift plus4append-only records. Slice1/2/3,C6,Batch2Slice3/4,Stop/drain,Defects1/5,resources/protectedJSON/Learner/donor preserved. HEAD/index/staged/status/pathsets unchanged; git diff --check passes; no unexplained drift.

Evidence:[batch3-macanalyzer-slice4-forensic-20260927T151938Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice4-forensic-20260927T151938Z/RESULT.md), source-trace.md, execution-counts.json, final-preservation.json, commands/logs/xcresults and diagnostic-append.swift. No native UI/network/hardware acceptance claimed.

FORENSIC COMPLETE / DEFECT4 REPRODUCED / NO PRODUCTION REPAIR. Overall candidate BLOCKED/UNVERIFIED. STOP for separate repair authorization. No full gate, duration/readiness/media repair, commit,push,install,hardware or Learner changes.


## 2026-09-28 — MacAnalyzer Slice4 repair: Phase2 performance checkpoint, no implementation

Authorized repair read and entry matched prior forensic checkpoint. Before adding production code, source trace established that existing preparePackage/canonicalContext/current-manifest path performs complete artifact reads, stereo WAV projection and beat/mix generation; no reusable general primary-media identity index exists. Archive replacement proof also requires current integrity evidence. Authorization explicitly requires reporting before expensive UI-path I/O. No UI I/O, production/test edit or repair introduced. Background dispatch alone does not solve repeated work or invalidation.

Phase1 definition and concrete continuation design recorded in [batch3-macanalyzer-slice4-repair-20260927T154818Z](/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice4-repair-20260927T154818Z/RESULT.md): separate pure deterministic semantic projection from bounded artifact-identity acquisition/invalidation; retain a bounded receipt history independent of operation state; per-member and full-package revisions separate; fail closed while proof unresolved; preserve immutable historical output. No breaking public schema requirement identified. No implementation acceptance claimed.

This turn0tests/0passes/0failures/0skips, no build/performance benchmark/hardware/full gate. Read-only integrity738canonical/719donor paths exact. Only4append-only records changed; all production and tests including Slice1/2/3,C6,Batch2Slice3/4,Stop/drain,Defects1/5,resources/protectedJSON/donor preserved. HEAD/index/staged/status/pathsets unchanged; final audit recorded separately.

SLICE4 NOT IMPLEMENTED — stopped at pre-UI-I/O performance report. Overall candidate BLOCKED/UNVERIFIED. No commit,push,install,hardware,Learner or resource change. Continue from the documented performance/invalidation design, not from a purported completed receipt repair.


## 2026-09-28 — Batch 3 / MacAnalyzer Slice 4 Defect 4 completed (bounded identity continuation)

Authorized task: validated export membership/revision ownership, bounded artifact proof and revision-safe Upload cache. Six source/test files changed: ScratchLab/Services/SessionExportCoordinator.swift, ScratchLab/Services/SessionUploadManager.swift, ScratchLab/Services/SessionSharePresenter.swift, ScratchLabDesktop/Views/MacAnalyzerView.swift, ScratchLab/Views/CompanionCameraView.swift, ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift.

Original failure: global export success and filename-based Upload reuse discarded validated membership/content ownership. The repair retains versioned builder-derived composite-member/package/ZIP receipts, preserves prior successful representations, adds bounded event-driven artifact proof, uses memory-only selected-take queries, and binds Share/Upload async publication to owners. Receipts reuse validator digests; same-path replacement, missing proof, review changes and archive tampering fail closed. Later failures cannot schedule prior temporary ZIP deletion. Ten diagnostics converted; 16 further Slice 4 regressions added.

Final focused verification, both Configuration 2 and Test Scheme Action: 173 methods; 348 executions / 348 passed / 0 failed / 0 skipped. All implementation invocations: 1170 executions / 1166 passed / 4 intermediate failures / 0 skipped; both diagnosed intermediate defects were fixed without weakening existing assertions. No full repository gate or platform build legs.

Integrity: 738 canonical paths / 719 donor paths checked; only the six authorized files plus four append-only records differ. Protected regions, C6, Batch 2 Slices 3/4, Stop/drain, resources, JSON and donor remain intact. HEAD/index/staging preserved; git diff --check PASS.

Evidence/report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice4-identity-20260927T160117Z/RESULT.md`. Exact commands, xcresults, counts, source snapshots and hash audits remain alongside it. Overall candidate remains UNVERIFIED. STOP; await separate authorization for subsequent work. No commit/push/install/hardware/Learner/Defect 1/5/resource reconciliation.


## 2026-09-28 — Batch 3 final MacAnalyzer artifact-truth forensics (Defects 1/5; NO REPAIR)

Authorized forensic task only. Display Duration uses sidecar wall span: fresh 24s vs 1s playable WAV/export actual. Active header uses URL presence and bypasses finalizing state. Structural artifact preflight additionally marks stable nonempty unreadable MOV/WAV ready. No production repair. Review supports saved-evidence/manual correction/unknown without classification; Accept still requires saved detection. Full take audio duration, final movie duration and notation/range extent are separate authorities. Existing export receipts contain hashes/revisions, not duration/readability.

Held-completion diagnostics prove composite take identity rejects A as B, while same-path replacement changes 1s WAV to 2s but old snapshot/read result stays valid-looking. This is primitive/source evidence, not an end-to-end private UI publication guarantee. Refresh cancellation is outside the MainActor commit, whose only explicit guard is directory equality; future observation publication needs exact owner/generation checks. Recommend classification B: shared bounded artifact observations, readiness contract first, duration consumer second. STOP before repair.

Verification: 46 distinct methods / 92 executions / 92 passed / 0 failed / 0 skipped across Configuration 2 and Test Scheme Action. Eight new deterministic forensic diagnostics; all old tests/assertions unchanged. Related Slice1/2 ownership, Slice4 identity/stale/no-I/O, take-boundary, finalization inspection and exact generated frame regressions pass. Existing production/fixture waits unchanged; no new sleep/poll/retry/tolerance. No full gate or separate platform legs.

Integrity: entry matched completed Slice4 checkpoint; 738 canonical/719 donor paths audited. Only additive CaptureReliabilityPhase1Tests.swift diagnostic and four append-only workflow records; 733 other canonical paths/all donor paths exact. All production/Slices1-4/C6/Batch2Slice3-4/Stop-drain/resources/protectedJSON unchanged. HEAD/index/staging/pathsets/status preserved; git diff --check PASS (see final audit).

Report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-artifact-truth-forensic-20260927T165711Z/RESULT.md`; source-trace.md, exact commands/logs/xcresults/execution-counts.json and final-preservation.json alongside. Defects1/5 OPEN; overall candidate UNVERIFIED. No commit/push/install/hardware/Learner/resource changes. Await separate repair authorization.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 5A: authoritative Review readiness

Authorized Defect5 only. READY FOR REVIEW now derives from selected session/take/published-media coherence, completed capture, validated owned sidecar and bounded current-generation movie/WAV readability. URL presence and existing structural `.ready` are insufficient. Shared additive observation service uses existing TakeReviewContext ownership and Slice4 filesystem invalidation hints, one generation-owned background task, bounded current-owner cache and file/parent watches. Audio reads one PCM frame; movie checks playable track/dimensions and decodes one image frame. No exhaustive playback claim, full-file hash or duration measurement. Limited evidence/manual correction/unknown remain available for coherent sidecars when media fails; Accept requires saved detection. Export remains independent; observation changes no export revision.

Only2production files: SessionExportCoordinator.swift (existing whole file retained as exact prefix, new service appended), MacAnalyzerView.swift (readiness adapters/action gates/owned-write invalidation). CaptureReliabilityPhase1Tests.swift converts6forensic methods and adds19permanent methods. Defect1 getters/diagnostics unchanged; CaptureCore/engine/domain/bridge/Stop-drain/C6/Batch2Slices3-4/resources/protectedJSON/donor unchanged. No schema or project change.

Final-source focused verification:137distinct methods/308executions/308passed/0failed/0skipped in Configuration2 and Test Scheme Action. Groups:readiness50, ownership52, human-review70, receipts52, related84 executions. All final selectors verified. All task XCTest invocations690/670/20/0; initial compile-only failure0tests, then20intermediate new-readiness failures caused by rejecting compressed zero-sample video markers. Isolated probe established one decoded first frame; corrected without weaker assertions. Earlier3misqualified lifecycle selectors were detected by result-node audit and corrected in final run. Failed evidence retained. Existing fixture-generation warnings remain; no native UI/hardware/full-gate claim.

Probe assertions:300presentation queries add0media probes;50equivalent requests share1audio+1video observation;100verified requests add0; audio deletion0decoder calls/recreation1new audio probe/unchanged movie0; sidecar-only review changes0additional media probes. HeldA→B and same-pathA1→A2 publication tests exercise actual service; replacement during observation fails closed before notification. Archive-free Review and export-revision separation pass.

Integrity738canonical/719donor paths:only3authorized source/test files+4append-only records;731other canonical/all719donor paths exact. Protected view members and existing export prefix exact; all old tests unchanged except6authorized diagnostic conversions. HEAD/index/staging/status/pathsets unchanged; git diff --check PASS. Detailed report, counts, commands, xcresults, prototype-failure evidence, final source copies and hash audit: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice5a-20260927T171425Z/RESULT.md`.

SLICE5A IMPLEMENTED / FOCUSED SOFTWARE VERIFIED ONLY. Defect1 remains OPEN; overall candidate UNVERIFIED. STOP. No full gate, commit,push,install,hardware,Learner,recorded-media reconciliation or duration repair.


## 2026-09-28 — Batch 3 MacAnalyzer Slice 5B: playable artifact duration

- Authorized Defect1 only; complete focused-software verification. Review's `Audio duration` now uses frame/sample facts retained by the existing owner-bound 5A probe/cache; video metadata remains separate. No second audio open or video asset; no new observation/generation mechanism. Wall timestamps and audit span are unchanged. Unresolved/missing/unreadable audio shows unavailable without fallback.
- Verified wall24/audio1/UI1/export1, fractional frames, safe invalid rates, independent video extent, A→B and same-path1→2 ownership, short-notation distinction, unchanged export revision/receipt, and zero extra probes for 300 observed queries or review-only changes.
- Final source: 153 distinct methods / 344 executions / 344 passed / 0 failed / 0 skipped across Configuration2 and Test Scheme Action. Includes complete 5A and Slice1/2/3/4 preservation groups plus related capture/review/export-duration tests. Initial test-build failure (optional Date assertion) executed 0 tests, corrected before passing runs.
- Production changes only in SessionExportCoordinator's 5A observation extension and MacAnalyzerView's duration label/getter; test changes only in CaptureReliabilityPhase1Tests. Four workflow documents appended. 738 canonical paths audited; 731 unchanged apart from these seven files. All719 donor paths, HEAD/index/staging/status, C6, Batch2Slices3/4, Stop/drain, resources/protectedJSON and existing export/schema unchanged; diffcheck PASS.
- Full evidence: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch3-macanalyzer-slice5b-20260927T174315Z` (RESULT.md, execution-counts.json, commands/logs/xcresults, final-preservation.json, slice5b-only.patch).
- All six original MacAnalyzer defects are repaired and focused-software verified. Overall candidate remains UNVERIFIED; final repository gate, rendered-UI/hardware acceptance and delivery are not performed. STOP for separate final-gate authorization. No commit/push/install/hardware/Learner/resource reconciliation.


## 2026-09-28 — Batch 4 full gate BLOCKED, partial checkpoint only

- Canonical `main`, HEAD `79fb3ecd74d261de5f3fd1f8b1434b620077ae3c`. Existing dirty reconciliation tree preserved. No production/test source edited.
- `scripts/build.sh all` launched exactly once, unfiltered, without retries. Python:87 executed/87 passed/0 failed/0 skipped. Native Test Scheme Action completed3,738 XCTest executions:3,633 passed/83 failed/22 skipped; one further method is in flight. Swift Testing and Configuration2 have NOT STARTED. These are partial counts, not the new final repository baseline.
- Active blocker: `ScratchSamplePlaybackControllerTests/testExplicitDeviceToSystemDefaultRebindKeepsMeterAvailableWithoutStalePeak`. Read-only process sample: main waits in `waitForAudioQueue`; playback queue is blocked in `AudioUnitSetProperty(CurrentDevice)` during initial Serato Virtual Audio load. Repeated HAL proxy errors268451843/268435460. Production/test playback files are byte-identical to HEAD. Driver versus accumulated test-process state is unresolved.
- Six old failing methods pass once,78 old failures recur,5 newly observed failures: Clear's queued persistence completion contract(C6-adjacent), obsolete review reload cache-key source assertions(Slice1-adjacent), and3 MIDI pre-publication/calibration-admission assertions. No two-configuration resolution claim.22 existing skips recur;34 prior skipped methods have not executed.
- Observed media clusters contain75 methods:A generic fixture12/B retired expectation52/C retained algorithm fixture6/D undecided surviving UI5. No recorded media restored. Logger still reads published status before main completion; ReferenceTear passes once, with no fresh differing payload.70 warning records so far;5A/5B default-probe Sendable conversion is separately disclosed.
- Completed-repair focused methods executed so far pass, except the separate cross-suite contract findings above; full non-regression remains incomplete. Later iOS/full macOS Release/CXLRelease/watchOS legs NOT RUN. No final gate exit exists while the process remains active.
- Evidence and exact inventories: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4-full-gate-20260927T180304Z`. Read `BATCH4-PARTIAL-BASELINE.md`, `partial-progress.json`, `partial-analysis/ROOT-CAUSE-CLUSTERS.md`, `partial-analysis/SKIP-AUDIT.md`, and `test-host-audio-rebind-sample.txt`.
- Gate runner exec session20353/PID70049; xcodebuild PID71312; test host PID71859 (identifiers must be verified before any future operation). User terminate-versus-leave-running question is pending. No termination, device reset, rerun, manual build bypass, install, hardware capture, commit or push performed.
- Candidate **BLOCKED**. First next slice: bounded read-only audio-gate stall investigation/decision. C9 Clear completion contract is the next code-contract candidate after execution is accountable. No repair authorized by this verification pass.


## 2026-09-28 — Batch 4 Run1 audio-stall forensics; termination authorization overtaken by exit

This append supersedes only the earlier checkpoint's still-running/unexecuted-configuration statements; all earlier evidence is retained. Termination was authorized, but inspection at10:06:30 NZDT found Run1 already exited at08:51:29.960552 NZDT with65. **No signal sent; no process terminated by the agent.** Original runner70049/xcodebuild71312/first host71859 and second host74599 were absent; no orphan from Run1 found. Do not record an invented termination or gate timeout. Factual status: BATCH4 FULL GATE — RUN1: AUDIO-DEVICE REBIND STALL; ENDED BEFORE TERMINATION COULD BE APPLIED; REPOSITORY GATE INCOMPLETE/BLOCKED.

- One invocation only; no rerun or reproduction. Finalized xcresult now records XCTest9,056 =8,782 pass/162 fail/112 skip; Swift Testing1,336pass; native combined10,392 =10,118 pass/162 fail/112 skip;84 distinct failing methods/56 skipped. Python87pass. Test Scheme Action5,196 =5,056/84/56; Configuration2 5,196 =5,062/78/56. Later iOS/full macOS Release/CXLRelease/watchOS legs NOT RUN. Original3,738/3,633/83/22 partial snapshot remains unchanged and labeled historical.
- Exact stalled method: ScratchSamplePlaybackControllerTests.testExplicitDeviceToSystemDefaultRebindKeepsMeterAvailableWithoutStalePeak, fileline202, main drain212. Both native executions eventually failed after2315.587s and2315.703s. Original stack proves audioQueue→MacScratchOutputRoute.prepare5092→AudioUnitSetProperty(CurrentDevice)→HAL HasProperty→Mach IPC, while main waits. Later logs show StartIO failure and repeated rebind attempts inside the test's existing loop. No XCTest retry was initiated.
- SDK identifies HAL268451843/268435460 as Mach receive/send timeout errors, not an XCTest or repository-gate timeout. SeratoVirtualAudio1.0.1/build1.0.1.74 installed; exact numeric deviceID/UID not logged and not guessed. Same-run System Default tests passed1.622s/1.610s. Serato-route/HAL connection failure proven; vendor-versus-service-state cause unresolved, aggregate/all-external-device generalization unsupported.
- History8c94247 confirms intentional real-engine integration, despite stale class header. Serato is an inaudible explicit-output surrogate. Presence-only guards admit an unresponsive driver into the default gate. Deterministic backend can prove ordering/generation/no-stale-peak/refusal; it cannot certify real HAL binding/tap cadence or physical output. No fake-pass substitution proposed.
- Production risk independently proven: UI Load/Re-cue and Test AHHH actions synchronously wait for playback queue; their queued work includes binding/start, not just a bounded WAV read. MainActor beat preview synchronously calls shared binder directly. Playback timer runs off-main but can also stall publication. No app cancellation/deadline interrupts the C call; queued unload cannot pass it. engineLock is released before the sampled setter; internal driver locks unknown.
- Classification:F combination, B default-plan external integration admission and D absent bounded/cancellable contract proven; C observed virtual-route/HAL failure; A application integration/UI hang exposure proven, Apple/Serato implementation fault unproven; E resource-leak contribution possible, not proven.
- Proposed smallest next slice: early explicit opt-in for real-route tests plus externally supervised native test process ownership/termination/reaping, preserving assertions and incomplete-run receipts. Use synthetic blocked child for supervisor tests. Proposed files: existing playback tests, scripts/build.sh, new run_mac_test_gate.py/test_mac_test_gate.py and records. NO implementation performed. Backend extraction and independent production UI/device-lifetime isolation need separate approval; merely racing a timeout against an uninterruptible call is insufficient.
- All raw logs, finalized bundle, original partial report/inventory, process sample, historical system log and per-configuration test traces preserved with hashes. Full forensic report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4-full-gate-20260927T180304Z/audio-stall-forensics-20260928/RESULT.md`. Includes exact call sites, classification/uncertainties, proposed policy, and source/driver/no-orphan evidence.
- Only these4records appended. Source/tests/resources/protected files/donor unchanged; no reset/install/device reconfiguration/Core Audio restart/hardware capture/Learner/media restoration/commit/push. Final audit is in `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4-full-gate-20260927T180304Z/audio-stall-forensics-20260928/final-integrity.json`. Candidate BLOCKED. STOP for separate repair authorization; do not run a new full gate.


## 2026-09-28 — Batch 4A: explicit audio integration admission and native process containment

- Authorized scope implemented: shared test admission in four existing test files; build.sh routes software tests through a new external macOS supervisor and offers separate audio-integration mode. New native_test_policy.json/run_mac_test_gate.py/test_mac_test_gate.py. Application source is unchanged.
- Inventory321 candidates: A212/B8/C0/D99 plus2 mixedA/B. Eight whole methods now require exact SCRATCHLAB_RUN_REAL_AUDIO_INTEGRATION=1 before discovery/construction; two mixed methods retain default no-device checks and gate only optional hardware discovery. Ordinary audio assertions remain unchanged. D99 incidental-engine cases stay enabled and are explicitly not proof of repository-wide hermeticity.
- Default software mode forces opt-in0 even in an opted-in parent environment. Integration mode selects ten methods and enables existing output tap explicitly. Software success, real-device integration, and physical hardware acceptance remain distinct. Real-device and physical acceptance NOT RUN.
- Supervisor owns a new process group and PID/kernel-birth identities, tracks descendants and unique-product launchd test hosts, retains logs/xcresult/receipts, enforces outer3600s software/1800s integration budgets with overrides, performs bounded TERM/KILL/reaping, and reports PASS/TEST FAILURE/TIMEOUT124/INFRASTRUCTURE70 separately. PID/group reuse and unrelated-process protection covered.
- Final focused verification347 executions =331 passed/0 failed/16 explicit integration skips: Python17pass; native330=314pass/16skip across both configurations. Complete playback suite288=278pass/10skip. Final native87.668s, exit0, no signals/survivors, child reaped. Stalled rebind method skips twice for explicit admission reason.
- Four actual-script routing regressions use fake xcodebuild plus real supervisor; no real full gate/platform legs. Blocked parent/grandchild force TERM/KILL, output retained, no orphans. Detached host fixture was strengthened after review exposed early OS SIGKILL of an unsigned copy: disposable copy now ad-hoc signed, explicit supervisor PID/TERM and -TERM exit asserted. Final17Python tests pass with this proof.
- All development attempts preserved:1,104 executions =1,054pass/4 failures-or-errors/46skip (Python114:112pass/2errors; native990:942pass/2fail/46skip). Initial parser/selector checks corrected. Native initial stale-signal failure diagnosed as incorrect mixed classification; guard moved to whole B method without weakening assertions. Final successful native repeated only after supervisor ownership hardening, not an unchanged retry.
- Integrity:738 original source paths →741;729 original exact, fourtests+build.sh+fourappend-only records changed, threenewscript files. All719donor paths exact. HEAD/index/staging preserved; protected JSON/media, production audio, C6, MacAnalyzer1–5B members, Batch2Slices3/4 unchanged. git diff --check PASS; no unexplained drift. Full evidence/report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4a-20260927T214346Z/RESULT.md`.
- Earlier combined proposal is partially resolved: admission/containment COMPLETE; independent production hang repair remains UNAUTHORIZED/OPEN. Candidate remains BLOCKED/UNVERIFIED. STOP for separate authorization. No full gate, production audio repair, device reset/change, Serato reproduction, commit,push,install,hardware capture,Learner or recorded-media change.


## 2026-09-28 — Autonomous Batch 4B hard stop: standard timed-capture clock mismatch

User authorized4B→4C→4D→4E with explicit global hard stops. Selected4B production audio responsiveness;4A was not repeated. Entry canonical main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c matches all741paths in the4A final inventory; donor719paths preserved. No production/test edit was made.

During4B.1 shared binding trace, identified a separate pre-existing capture-timing defect: ScratchLabBeatEngine.start(mode:bpm:) default non-clickTrack/no-explicit-count-in branch chooses legacyClickStartHostTime before preparation/binding/start, but scheduleUICallbacks receives nil host deadlines and schedules callbacks relative to post-startup now. Both standard timed-capture UIs copy old returned clocks into CaptureTimingMetadata; iOS persists them without measured-origin correction, while Mac updates recording origin but retains old beat origin. Ordinary export consumes these clocks for generated beat position. Source proves inconsistent timing bases; actual driver/audio offset and existing archive corruption were NOT measured. Prepared CXL start and clickTrack use different timing paths and are not implicated by this finding.

GLOBAL HARD STOP1: new capture/data-integrity production defect outside the bounded responsiveness phase.4B repair/focused tests NOT RUN;4C/4D/4E NOT RUN. Fresh XCTest0executions/0pass/0fail/0skip; Swift Testing0/0/0/0; Python0/0/0/0;0distinct methods, neither configuration. scripts/build.sh all and all four platform legs NOT RUN. Fresh skip/warning audits and take-003 reassessment NOT RUN. Historical4A347=331pass/0fail/16skip remains historical only.

Only append-only TASKS.md,DEV_LOG.md,AI_HANDOFF.md,AI_HANDOFF/next_prompt.md changed. All production/tests/resources/intentional removals/protectedJSON/4A/C6/MacAnalyzer/Batch2 work preserved; no commit,push,stage,install,physical capture,real-device integration,Core Audio/device/driver change,media restoration,Learner change or new notation feature. Evidence: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-20260927T220327Z/RESULT.md`, SOURCE-TRACE.md, frozen source, inventories, exact index/status and final preservation receipt. A preliminary collector-only directory-symlink representation mismatch is retained and corrected, not unexplained drift.

Next requires explicit bounded shared timed-capture clock repair authorization: one post-preparation origin for playback/callbacks/metadata, deterministic held-preparation/injected-clock tests, both standard capture consumers and export alignment coverage, preserving prepared-CXL/clickTrack/schema/raw evidence. Then resume4B from its trace; do not claim a responsiveness repair or rerun4A. FINAL CANDIDATE: BLOCKED — SOFTWARE DEFECTS REMAIN.


## 2026-09-28 — ACTIVE 4B0 continuation checkpoint (not acceptance)

The user authorized shared timed-capture clock repair4B0 and automatic resumption4B→4C→4D→4E on acceptance; do not request another authorization. Master prompts are preserved in batch4b-20260927T220327Z/user-request-part1.txt and user-request-part2.txt. New authorization and evidence: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b0-20260927T221134Z/`.

Entry matches preceding hard-stop source741/donor719 inventories exactly. Current implementation edits: shared ScratchLabBeatEngine.swift; ordinary-start adapters only in CompanionCameraView.swift/MacAnalyzerView.swift; appended regressions in ReferenceBeatPilotTests.swift/CaptureReliabilityPhase1Tests.swift. No other implementation paths changed. Shared immutable OrdinaryTimedCaptureOrigin is chosen after preparation+initial buffer scheduling; absolute callbacks and metadata use same host origin. Existing activeGeneration now owns request before reset/preparation; stale completion rejected before origin. Runtime requestGeneration travels in BeatEngineStartMetadata (not persisted schema), and both adapters recheck it inside their final MainActor task. Missing timing no longer invents now. Prepared-CXL start body and old CXL callback scheduler untouched. Clock inventory saved externally.

Verification so far: first15new methods/30executions allpass in software-mi8ve2so. Combined attempt software-bwb7x1_c failed compile because new export fixture chose void two-argument overload; fixture corrected to explicit usesClickCountIn:false, failed evidence retained. Corrected combined software-axhpr0z5 passed92methods/184executions=182pass/0fail/2explicit integration skips. Final actor-boundary ownership checks and two more regressions added after review. Fresh final focused run ACTIVE: launcher session7905, final-focused-launch.log, new native/software-* directory. Do not edit its frozen five inputs while it runs; final-focused-input-sha256.json recorded. Required per-configuration leaf accounting still needs xcresult extraction.4B0 NOT YET ACCEPTED; no4B repair has started, full gate/builds NOT RUN.

Next: complete final focused run, check failures within authorized4B0, audit source/preservation, write4B0 report, then automatically resume4B. Known4B exposure: Load/Test/ownership-mode waitForAudioQueue; main live loop-context/diagnostics reads; off-main presentation poll synchronous reads stall publication; ReferenceAuthoring beat preview uses MainActor PracticeBeatPlaybackEngine. Do not simply Task-wrap that actor-isolated protocol or move waits to another caller. Need owned asynchronous work, generation checks, meter invalidation and deterministic held binding seams; preserve successful audio behavior and bounded worker count. Do not reimplement4A or weakenC6/MacAnalyzer/Stop/drain. No stage/commit/push/install/hardware/integration/media restoration/Learner changes. Continue work; this is a context handoff, not a final result or request for permission.


## 2026-09-28 — Batch 4B0 PASS; automatically resume 4B

Shared ordinary timed-capture clock repair accepted. One post-preparation immutable host origin controls returned metadata, playback and callback deadlines; existing generation rejects cancelled/superseded preparation and final actor delivery. Both ordinary adapters consume shared captureTiming; no now fallback or persisted schema change. Prepared CXL bodies and existing test prefixes remain exact.

Final focused software-xlxnkx8e: 94 distinct methods, 188 executions = 186 passed / 0 failed / 2 explicit integration skips. Each configuration: 94 = 93/0/1. New22methods/44executions allpass. Supervisor PASS/exit0/reaped/no survivors. All development executions402=398pass/0testfail/4skip; one retained compile-only failed test-overload attempt ran0tests. Swift Testing/Python/full gate/independent platform matrix/real-device integration/physical acceptance NOT RUN.

Five implementation/test paths plus four append-only records changed; source741 and donor719 inventoried, no new/deleted paths, HEAD/index/protectedJSON/intentional media removals preserved. No drift; diffcheck passes. Detailed clock inventory, warnings, commands, receipts, xcresults, counts and report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b0-20260927T221134Z/RESULT.md`.

User already authorized automatic 4B→4C→4D→4E after 4B0. Resume 4B now, without another authorization; all master hard stops remain. No full-gate or hardware claim. No commit/push/stage/install/capture/integration/reset/device/driver/media/Learner action.


## 2026-09-28 — Resumed 4B HARD STOP1: ordinary Stop before media arming

4B0 accepted: final94methods/188executions=186pass/0fail/2explicit integration skips; eachconfiguration94=93/0/1. Supervisor PASS/exit0/reaped/no survivors. Clock/export ownership repair preserved. Report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b0-20260927T221134Z/RESULT.md`.

Resumed4B entry matches source741/donor719 checkpoint exactly. No4B production/test edits. Trace confirmed deeper shared binder exposure (including prepared CXL inside main.sync), then discovered separate pre-existing capture-integrity defect: ordinary MacAnalyzer Stop→toggleRoutineRecording→untokened stopRoutineRecording only cancels pendingRoutineMediaStart if already installed. A Stop during sessionQueue preparation before armPendingRoutineMediaStart leaves the ledger request valid; late preparation arms it, queued Stop sees no claimed/movie writer and returns, then a later eligible frame may start recording after Stop. Token-aware requestRoutineRecordingStop rejects this case, but ordinary UI does not use it. Existing Stop tests begin after arming and call token-aware Stop; they do not prove this interval. MacCaptureEngine bytes match4A, so4B0 did not introduce it. Source interleaving proven; no physical reproduction or archive-corruption claim.

GLOBAL HARD-STOP RULE1. Responsiveness repair NOT IMPLEMENTED;4C/4D/4E NOT RUN. Fresh4B native/SwiftTesting/Python each0executions/0pass/0fail/0skip;0methods; configs NOT RUN. Fullgate0invocations; all platform legs NOT RUN. No claim that process isolation is required. Preserve failed/earlier evidence. Detailed report, source excerpts and required bounded repair: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-resumed-20260927T222629Z/RESULT.md` and SOURCE-TRACE.md.

Next human action: separately authorize ordinary Stop-before-arm request ownership from beginRequest through preparation/arming/first-sample claim, with deterministic held-preparation cancellation, late completion, A1→A2, MIDI release and existing deferred-Stop preservation. Then resume authorized4B→4C→4D→4E. Do not repair now. Only four workflow records appended; no source/test/schema/resource/media/driver/Learner changes, stage/commit/push/install/device operation or hardware capture. Candidate: BLOCKED — SOFTWARE DEFECTS REMAIN.


## 2026-09-28 — ACTIVE 4B1 continuation checkpoint (not acceptance)

User authorized ordinary macOS Stop-before-arm request ownership repair and automatic continuation through 4B→4C→4D→4E on acceptance. Clarified contract: preserve sequencing; Stop prevents later start effects, while already-emitted count-in remains historical. Canonical source main/79fb3ecd; entry source741/donor719 inventories matched prior checkpoint.

Candidate edits only MacCaptureEngine.swift and appended OrdinaryRoutinePreparationOwnershipTests in ReferenceBeatPilotTests.swift. Existing request tokens now own preparation, deferred UI publication, immutable setup snapshots and cancellation cleanup; Stop retires pending preparation synchronously, and late completion cannot arm or publish over a successor. Reserved take identities prevent a retry reusing an outstanding cancelled request's name. Prepared CXL, shared 4B0 timing and persisted schemas unchanged.

First focused run software-2eem_pe9 passed14methods/28executions/28passed/0failed/0skipped across both configurations, supervisor PASS. Expanded combined verification ACTIVE (launcher session60471); no acceptance yet. Includes ordinary ownership, shared timing, Stop/boundary/finalization and CXL authoring preservation. Evidence, authorization, before snapshots and frozen inputs: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b1-20260927T223917Z. Do not edit frozen implementation/test inputs while active.

Next: inspect combined result, audit exact preservation and cleanup, complete required focused coverage and 4B1 report. If accepted, automatically resume production audio responsiveness4B, then reconciliation4C, canonical gate4D and read-only4E; do not ask another authorization. All hard stops remain. Full gate/platform matrix/real-device integration/physical hardware NOT RUN. No commit/push/stage/install/media restoration/Learner/device/driver changes. This checkpoint is not completion.


## 2026-09-28 — Batch 4B1 PASS; automatically resume 4B

Ordinary Stop now retires the existing admitted request before media arming, without waiting for session/audio work. Late success/failure cannot arm or publish over A2; exact MIDI cleanup and immutable session/take/Watch inputs protect successor resources. Normal confirmed/deferred Stop and MIDI drain remain unchanged. Shared token-stop queued UI publication also checks ownership.

Karl clarified sequencing: already-emitted count-in remains historical; Stop prevents later start effects. Shared4B0 engine/adapters and prepared-CXL bridge unchanged. No claim that pre-media Stop erases an earlier beat origin.

Final software-3_5t5zgz:204distinct methods/408executions=406passed/0failed/2explicit integration skips; eachconfiguration204=203/0/1. New19methods/38executions allpass. Supervisor PASS/exit0/reaped/no survivors. All development842=838pass/0fail/4skip; final counts are separate. SwiftTesting/Python/full gate/platform matrix/real-device integration/physical acceptance NOT RUN.

Only MacCaptureEngine.swift and appended ReferenceBeatPilotTests.swift plus four append-only records changed; source741/donor719 inventories, protected work, HEAD/index and intentional removals preserved; diffcheck PASS. Evidence/report: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b1-20260927T223917Z/RESULT.md.

Automatically resume4B now without another permission request, then4C→4D→4E when accepted. Current audio exposure remains MainActor queue drains/diagnostics/loop-context reads, sample binding/publication, beat preview and prepared/ordinary beat binding; do not present moving a wait or Swift cancellation as interrupting a driver call. Master hard stops remain. No stage/commit/push/install/device operation/media restoration/Learner work.


## 2026-09-28 — Resumed 4B HARD STOP1: outer ordinary Start / Watch-wait ownership

4B1 accepted: final204methods/408executions=406passed/0failed/2explicit integration skips; eachconfiguration204=203/0/1. New19methods/38executions allpass. Supervisor PASS/exit0/reaped/no survivors. Separate report: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b1-20260927T223917Z/RESULT.md. Karl's sequencing clarification preserved: historical count-in remains; Stop prevents later media effects.

Automatically resumed4B and found a separate earlier capture-integrity gap. Ordinary MacAnalyzer Start awaits requestWatchCaptureStart before allocating either beat or media request ownership. The visible Start button does not exclude a second request during that await. A1 and A2 commands can resolve independently; after A2 starts count-in or recording, lateA1 resumes without an outer ownership check, applies its reply and calls beatEngine.start, which assigns a new audio generation and resets A2's backing. The4B1 ledger may reject later media admission, but cannot undo an earlier beat reset. Source proves an admitted ordering, not a physical reproduction or historical corruption. MacAnalyzer/receiver/shared beat source unchanged by4B1; no4B responsiveness source/test changes made.

GLOBAL HARD-STOP RULE1. Stop here; no4B/4C repair or4D/4E continuation. Fresh resumed4B XCTest/SwiftTesting/Python each0executions/0pass/0fail/0skip,0methods, neitherconfiguration. Fullgate0invocations; platformmatrix,real-device integration,physicalhardware NOT RUN. Evidence/source excerpts: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b1-20260927T225206Z/SOURCE-TRACE.md and RESULT.md.

Next human action: separately authorize bounded outer ordinary Start/Watch-wait admission and ownership before the first await. Define repeated Start/pending cancellation, reject obsolete replies before Watch state/audio/media effects, and clean only the original Watch identity; preserve4B0/4B1/confirmedStop/MIDI/schema/CXL. Required deterministic cases are in SOURCE-TRACE.md. Then resume already-authorized4B→4C→4D→4E. No process-isolation requirement established.

Only four workflow records appended in resumed4B. All implementation/tests/resources/intentional deletions/protectedJSON/donor/prior evidence preserved. No stage/commit/push/install/capture/integration/device/driver/CoreAudio reset/media restoration/Learner changes. FINAL CANDIDATE: BLOCKED — SOFTWARE DEFECTS REMAIN.


## 2026-09-28 — ACTIVE 4B2 checkpoint (not acceptance)

User separately authorized ordinary outer Start/Watch-await ownership and automatic4B→4C→4D→4E after focused acceptance. Read authorization in /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b2-20260927T225750Z/authorization.txt. Entry matches prior source741/donor719 checkpoint exactly.

Candidate edits: MacCaptureEngine.swift, MacAnalyzerView.swift, appended OrdinaryRoutineOuterStartTests in ReferenceBeatPilotTests.swift. Existing RoutineRecordingRequestToken now allocated before readiness/Watch awaits and atomically consumed by4B1 preparation. Current repeated Start remains admitted before media ownership, superseding old request; active media/MIDI/finalization refuses new outer admission. Reserved take identity registered before Watch send; late reply cleans only captured original Watch identity. Both final actor callbacks and media handoff check ownership. Ready-card input-readiness await and view disappearance are covered; iOS and preparedCXL/sharedbeat production unchanged. Sequencing unchanged: historical count-in retained, no new stale origin.

First focused attempt software-g8b0dgzu failed compilation only: new sidecar fixture omitted required startedAt. Corrected;0test executions. Corrected focused run ACTIVE launcher97414; log focused-corrected-launch.log; frozen three inputs in focused-corrected-inputs.json. Do not edit these while active. Newtests use held continuations (no sleeps/polling), real shared beat seams, real4B1 media ownership and synthetic PCM/sidecar finalization; results not yet accepted.

Next: finish focused run, fix in-scope issues, add/review remaining ownership/admission/cleanup cases, run both-config combined preservation suites (4B0/4B1/Watch/Stop/endpoint/finalization/CXL). Audit all await/callback boundaries and preserved files, write separate4B2 report, then automatically resume4Bwithout asking again. Full gate/platform matrix/integration/hardware NOT RUN. No commit/push/stage/install/device/driver/media restoration/Learner changes. This is an active continuation, not a final report.


## 2026-09-28 — Batch 4B2 PASS; automatically resume 4B

Ordinary Start now uses existing RoutineRecordingRequestToken before readiness/Watch awaits and consumes the same token atomically at4B1 media admission. Newest accepted pending Start supersedes older; media/MIDI/finalization still refuses overlap. Exact original Watch cleanup and unique provisional take reservations protect successors. Final MainActor callbacks check outer owner plus4B0 beat generation. Ready-card and Capture app's ordinary Practice wrapper share the owner; lesson/scoring logic unchanged. iOS/preparedCXL/sharedbeat production unchanged apart from shared reservation entry retiring obsolete ordinary ownership. Historical count-in sequencing preserved.

Final software-eho9at_8:263methods/526executions=524passed/0failed/2explicit integration skips. Eachconfiguration263=262/0/1. New24methods/48executions allpass; all4B1nineteenmethods and4B0clockregressions pass. Successor late-success/failure/timeout cases reach synthetic media Stop/finalization with exact token and persisted sidecar. Supervisor PASS/exit0/reaped/no survivors.

Retained development: compile-only missing-startedAt fixture failure0executions; focused32pass; firstcombined522=518pass/2fail/2skip, stale source-count assertion counted only unscoped Watch cleanup. It now recognizes exact-original cleanup too, same minimum threshold, with new runtime failure regression. All development1080=1074pass/2fail/4skip; final526counts separate. Full gate/platformmatrix/SwiftTesting/Python/integration/hardware NOT RUN.

Fourimplementation/testpaths changed: MacCaptureEngine.swift, ordinary admission portions of MacAnalyzerView.swift, appended ReferenceBeatPilotTests.swift, one stale Watch source assertion in CaptureReliabilityPhase1Tests.swift. Fourappend-onlyrecords. Source741/donor719, protectedwork, HEAD/index unchanged; diffcheckPASS. Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b2-20260927T225750Z/RESULT.md.

Automatically resume4B production audio responsiveness now, then4C→4D→4E after acceptance; do not ask again. No fullgateuntilfocused4Cclean. Existinghardstopsremain. No commit/push/stage/install/hardware/integration/driver/device/media restoration/Learner changes.


## 2026-09-28 — Resumed Batch 4B after 4B2: GLOBAL HARD STOP

4B2 remains accepted for ordinary outer Start: 263 distinct methods, 526 executions, 524 passed, 0 failed, 2 explicitly excluded integration skips; each Debug configuration 263/262/0/1. All 24 new methods passed twice (48/48). Exact tested source hashes and supervisor PASS receipt preserved in `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b2-20260927T225750Z`.

Resumed 4B audio trace found a separate prepared-CXL capture-integrity defect: CXL Start reserves shared engine identity A then awaits Watch without a reservation owner. Its view-disappearance cleanup does not cancel the unretained Start task. Ordinary B can replace the shared pending identity/configuration; late A applies its Watch reply before a cancellation-only check and can call generic media start using B's current reservation. CXL error/cancellation cleanup calls unscoped cancelPendingRoutineReservation, which retires the current ordinary owner and clears current state rather than checking A. Source-established interleaving; no new failing runtime test or physical observation claimed.

User GLOBAL HARD-STOP rule 1 applies. No responsiveness source/test edits; no post-stop tests or builds. 4B remains incomplete. 4C/4D/4E, complete gate, all four platform legs, integration, hardware and final release acceptance NOT RUN. Current resumed-4B test counts: 0 methods, 0 executions, 0 passed, 0 failed, 0 skipped. No source drift before append-only report updates: 741 source and 719 donor paths exact; HEAD/index/staged unchanged; git diff --check passes. Protected JSON, removed-media state and prior checkpoints/evidence preserved.

Evidence/report: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b2-20260927T231903Z/RESULT.md`; exact causal trace: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b2-20260927T231903Z/HARD-STOP-SOURCE-TRACE.md`; remaining responsiveness trace: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b2-20260927T231903Z/RESPONSIVENESS-AUDIT.md`.

Next action requires separate human authorization for prepared-CXL Start/reservation ownership, actual Start lifecycle cancellation, original-only cleanup and cross-surface held-reply/ABA/successor-finalization regressions. Do not reopen completed ordinary 4B2 absent direct contrary evidence. Do not resume 4B/4C/4D/4E past this hard stop without that authorization. NO COMMIT, PUSH, STAGING, INSTALLATION, HARDWARE, INTEGRATION, CORE AUDIO RESET, DRIVER CHANGE, MEDIA RESTORATION OR LEARNER CHANGE.


Lifecycle qualification: view departure by itself is not proof that an active capture should stop. Existing comments intentionally preserve engine-owned takes. The confirmed defect is the absence of exclusive/owned pending-Start admission across surfaces, plus unscoped stale cleanup. A repair must establish and preserve the intended pending-Start lifecycle (retire it on an actual cancellation, or keep it exclusively owned while it continues); it must not introduce unconditional cancellation of already-started takes. “View-departure cancellation” above is a proposed pending-start repair point, not authorization to change that product policy. Once B is accepted as current, A cannot mutate B under either policy.


## 2026-09-28 — ACTIVE Batch 4B3 (not acceptance)

User authorized prepared-CXL pending Start/reservation ownership and automatic continuation through 4B–4E after acceptance. Separate authorization/evidence: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b3-20260927T232933Z`. Entry inventories exactly matched prior hard-stop checkpoint: source741/donor719; main/79fb3ecd; no unexplained drift.

Candidate shares existing ledger token between ordinary and prepared-CXL Start, scopes Watch publication/cancellation/reservation consumption to exact owner, guards late prepared continuation and exact beat cleanup, and makes pending cancellation inert after media handoff. Existing active-capture/view-departure policy retained; no unconditional active Stop introduced. Prepared timing/PCM, ordinary4B0/4B1/4B2, MIDI drain, schema/resources unchanged.

Changed candidate files: MacCaptureEngine.swift, ReferenceAuthoringCaptureBridge.swift, 20 appended PreparedCXLStartOwnershipTests in ReferenceBeatPilotTests.swift, two source assertion shapes in CaptureReliabilityPhase1Tests.swift. Initial supervised run software-z6988in9 compiled no tests: new nested fixtures needed explicit MainActor annotations. Corrected run software-qj97_smv is in progress (launcher session31630); frozen inputs focused-corrected-inputs.json. Do not edit compiled source while it runs. No acceptance yet.

Next: finish focused run, address in-scope findings, cover prepared timing and movement controls as needed, then combined both-configuration preservation suites. Audit owned cleanup for immediate admission failures, unused helper/comment cleanup, final source hashes and donor preservation. Produce required4B3 report, then automatically resume remaining4B→4C→4D→4E when accepted. Do not stop simply because implementation tests need correction. No complete gate until4Cfocusedclean; existing global hard stops apply. No stage/commit/push/install/integration/hardware/device/driver/reset/media restoration/Learner changes.


### 4B3 active verification checkpoint — continue, not acceptance

Focused actual selection software-058zp62d PASS: 24 methods / 48 executions / 48 passed / 0 failed / 0 skipped, 24 passes in each configuration. First compile attempt software-z6988in9 executed0 due missing MainActor on new nested fixtures; corrected compile run software-qj97_smv executed0 because the caller duplicated the target prefix in --only-testing. Both retained; the zero-test PASS is explicitly not verification. Correct supervisor syntax uses class names only.

Added one final regression for CXL Stop immediately after reservation consumption (media preparation owns the request). Combined preservation run ACTIVE software-_252guvv, launcher session2467, frozen combined-inputs.json, command combined-command.json. Expected25new methods; actual final counts must come from xcresult, not assumptions. Includes the same17preservation classes as4B2 plus PreparedCXLStartOwnershipTests. DO NOT edit compiled source while active.

Candidate files remain the same four. No new lock; token + exact reservation validated at media admission under ledger lock, MainActor serializes global pending state, bridge cancellationLock released before any callback/ledger/Watch/audio work. Pending cleanup is inert after handoff; current failure before handoff retains cleanup ownership. No change to view-departure policy or active CXL Stop/finalization. Prepared beat source, ordinary4B0timing, MacAnalyzer, iOS and VM untouched. Focused67warning lines inclduplicates, only bridge duration-deprecation points at untouched code; final warning audit stillpending4D.

Finish combined, repair any in-scope failures and preserve evidence, then final inventory/diffcheck/report in `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b3-20260927T232933Z`. On4B3PASS automatically resume remaining4Baudioresponsiveness, then4C→4D→4E. Master fullgate exactlyonceinitial onlyafter4Cfocusedclean. No commit/push/stage/install/hardware/integration/media restoration/driver changes/Learner work.


### 4B3 final review candidate — verification running, not acceptance

First combined software-_252guvv PASS:288methods/576executions=574passed/0failed/2explicit integration skips; 25newmethods50pass. This is retained candidate evidence, not final-source acceptance. Final call-site review found an old finalization cancellation handler still invoking no-argument pending Watch cancellation; it could target a newer pending Start. This is within authorized4B3 and was corrected before acceptance.

Removed that cross-lifecycle call and independent bridge handshake epoch. Pending CXL Watch cancellation uses shared ledger owner; finalization cancellation only abandons its existing finalization wait. Scoped abandonment is exact-request; active handoff remains immune. Added two deterministic regressions: actual driver finalization-cancel vs newer CXL, and stale abandonment vs same-session CXL successor. 27newmethods now.

Final combined run ACTIVE software-3sp8nwhg, launcher session18557. Frozen five inputs in `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b3-20260927T232933Z/final-inputs.json`; DO NOT EDIT while active. Five files: MacCaptureEngine.swift, ReferenceAuthoringCaptureBridge.swift, ReferenceAuthoringViewModel.swift (driver closure only), ReferenceBeatPilotTests.swift appended tests, CaptureReliabilityPhase1Tests.swift source assertions. Finish run, account actual xcresult using account_tests.py, verify inventory, produce22-section4B3report and append acceptance. Then automatically resume4Bresponsiveness→4C→4D→4E. No new authorization needed unlessglobalhardstop.


## 2026-09-28 — Batch 4B3 PASS; automatically resume remaining 4B

Prepared CXL now shares ordinary Start's exact ledger token and immutable reservation/configuration, validates scoped Watch publication and atomic token+identity media consumption, and cleans only its own pending/beat state. Finalization cancellation no longer cancels an unrelated pending Start; independent CXL handshake epoch removed. Explicit pending Stop/supersession uses the shared owner; active/view-departure behavior retained.

Final software-3sp8nwhg:290distinct methods/580executions=578passed/0failed/2explicit integration skips; each Debug configuration290=289/0/1. All27newmethods/54executions pass. Full preservation includes4B0(21methods),4B1(19),4B2(24),CXL/Watch/Stop/finalization. SupervisorPASS/exit0/childExit0/reaped/no signals/no survivors. No active native processes remain from this run.

Development retained: initial compile-only actor-annotation failure0executions; mistaken duplicated selector build0executions(not verification); actual focused48/48/0/0; firstcombined576/574/0/2; final580/578/0/2. All executed development1204/1200/0/4, not substituted for final counts. SwiftTesting/Python/fullgate/platformmatrix/integration/hardware NOT RUN. Final67warninglines retained; full warning/skip audit awaits4D.

Five source/test paths changed: MacCaptureEngine.swift; ReferenceAuthoringCaptureBridge.swift; ReferenceAuthoringViewModel.swift(driver cancellation closure only); appended ReferenceBeatPilotTests.swift; two source assertions in CaptureReliabilityPhase1Tests.swift. Fourworkflowrecords append-only. Source741/donor719, protected JSON, resources/deletions, prior checkpoints and HEAD/index preserved; diffcheckPASS. Evidence/report `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b3-20260927T232933Z/RESULT.md`.

Automatically resume remaining4B now. Audio queues, UI Load/Re-cue/Test AHHH, snapshots, and ordinary/prepared/shared beat MainActor binding still need bounded asynchronous request completion and owned presentation. Do not claim driver C calls are cancellable. No fullgateuntil4Cfocusedclean. Continue4B→4C→4D→4E without another permission request unless a globalhardstop is established. No commit/push/stage/install/integration/hardware/device/driver/reset/media restoration/Learner work.


## Batch 4B continuation after accepted 4B3 — IN PROGRESS

4B3 is accepted; final focused run software-3sp8nwhg executed 580 tests: 578 passed, 0 failed, 2 explicit integration skips; 290 distinct methods, both Debug configurations. The full software gate remains NOT RUN. Automatic 4B → 4C → 4D → 4E authorization remains active.

Current 4B draft changes ScratchSamplePlaybackController.swift, MacCaptureEngine.swift, and appends nine ScratchPlaybackResponsivenessTests methods. It adds owned/coalesced load completion, asynchronous presentation refresh with invalidation, removes Load/Test AHHH/ownership-mode UI drains, moves take sample observation into the existing owned preparation worker while retaining admission-time MIDI mapping, and preserves request ordering across an obsolete unload. This draft is NOT accepted yet. Beat responsiveness is still unimplemented. No new hard stop has been established.

Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b3-20260927T235209Z. First development build software-m1ma2ebx compiled Swift but failed linking with errno=28 (No space left on device); 0 tests executed, supervisor exit 65, child reaped, no survivors. Generated build caches were compressed and content-verified before removing expanded copies; source, result bundles, logs, receipts and compiled products were not removed. Cache archives and receipts remain in the evidence package. Sparse compilation-cache hashing was corrected to stream in bounded memory.

Current verification software-l7aah7wt runs ScratchPlaybackResponsivenessTests plus ScratchSamplePlaybackControllerTests under the external supervisor, default integration opt-out, 900-second ceiling. At this append the first nine new test executions passed; the invocation is still running. Do not claim full or focused acceptance from that partial output. Source inputs are recorded in sample-second-inputs.json.

Continue current invocation to its exact final accounting, fix only justified 4B failures, then implement owned nonblocking beat startup/Stop and required held-operation proofs, preserving 4B0/4B1/4B2/4B3 timing and capture ownership. Do not run scripts/build.sh all until focused 4C is clean. No stage, commit, push, install, integration, hardware capture, driver changes, media restoration or Learner work.


## Batch 4B playback focused PASS; beat responsiveness IN PROGRESS

Playback software-l7aah7wt:153 distinct methods/306 executions=296 passed/0 failed/10 explicit integration skips; each Debug configuration153/148/0/5. All9 new playback methods18 executions passed. Beat timing/ownership preservation software-uur1uf99:48 methods/96 executions96 passed/0 failed/0 skipped across both Debug configurations. These are focused development results, not full4B or fullsoftware acceptance.

Shared beat draft now admits owned requests on MainActor and runs binding on one fixed device queue with one replaceable pending slot; logical retirement does not claim to cancel an in-flight HAL C call. Ordinary and prepared capture consumers and preview consumers use actual owned completion; routing choices snapshot before device work; prepared CXL retains its existing authoring-worker acknowledgement and exact Start owner. Runtime generation is not persisted into export schemas. New held-operation tests are in progress under supervisor software-l1x4k6fc; no result claimed at this append.

Evidence remains batch4b-post4b3-20260927T235209Z. User asked about20GB free; live checks showed13GiB free after the latest build. Monitor headroom and preserve logs/receipts/result bundles/products. Generated cache compression receipts remain preserved. No current disk block or new global hard stop. Continue4B review/focused verification then automatically4C→4D→4E under existing rules. No fullgate before clean4C; no commit/push/install/integration/hardware/media restoration/Learner changes.


## Batch4B PASS — automatic continuation to4C

Root cause: playback UI queue joins and shared beat MainActor binding inherited unbounded synchronous driver latency. Repaired with exact request-owned asynchronous completion on fixed queues, one pending replacement, stale meter/presentation invalidation, post-route readiness, and deferred beat metadata/callback publication. Pending previews remain responsive; Stop retires logical ownership without claiming to cancel C. Preserves4B0/1/2/3 timing/Watch/media identities and persisted schemas.

Final focused software-radfw34g:526 methods1052 executions1040 passed0 failed12 explicit integration skips; each Debug configuration526/520/0/6. All20 new methods40 executions pass. SwiftTesting/Python/fullgate/platformmatrix/integration/hardware NOT RUN.69 focused warning lines retained; no new proven capture/export defect. Main/HEAD/index/staged state unchanged; source741/donor719; donorunchanged;0 new/deletedpaths; frozenSwiftinputs0 drift; diffcheckPASS; fourdocoriginalprefixes preserved.

Development failures retained, not hidden: first link-only disk-full0 tests; one newtest Int/Double compileerror0 tests; initialcombined1006/984/10/12. Initialcombined included2 known retired-demo C3 methods accidentally throughbroadPracticeBeat selector;4failures explicitly remain4C. Corrected CXLsource-call assertion and stale ownership-mode Loadstatuspublication; finalcombinedclean. Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4b-post4b3-20260927T235209Z/RESULT.md and SOURCE-TRACE.md. Generated caches content-verified and archived, previous logs/receipts/xcresults/products preserved.13GiBfree atlastcheck.

Continue4C now: C5 MIDI mapping/calibration realpublication and isolatedstorage; C9Clear actualpersistence/publication completion; C7logger actualwrite/publication completion; C10compositereviewkey; C4iOSevidenceowner; retiredmedia tests/synthetic fixtures/retainedalgorithms/survivingUI. Focusedaftereachsubcluster thencombined. Do notrunfullgateuntil4Cclean;4Dfullgateexactlyonceinitially andhardstoponrequired failure. No newauthorizationneeded absentglobalhardstop.


## Batch4C C5/C9 candidate — IN PROGRESS

4Baccepted(final1052/1040/0/12;526methods). Newphaseevidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4c-20260928T003237Z, with fullbeforeSwift/workflow snapshots and source/donor inventories. C5tests fixedtime delays were not completion; replaced with DEBUG finitequeue/publication barrier and injected temporary mapping store(defaultproductionstoreunchanged). C6guards untouched, C6diskassertions useisolatedstore. Clear's asynchronousadmission now testedafter actualpreference/publicationcompletion withisolatedpreferences andadditional visible-stateassertions. Candidate notaccepted.

First4Crun software-74yaqqup had3testrefactorcompile diagnostics0executions; corrected engine1reference andexplicitselfcapture. SecondMIDI/Clear run ACTIVE (launcher89619); see midi-clear-second.log and frozenmidi-clear-second-inputs.json. Finish/accountbeforelateredits. No fullgate yet. Nextloggercompletion,C4/C10,thenrecordedmediareconciliation andcombined4C. No globalhardstop established.


## Batch4C focused progress — MIDI/Clear and logger PASS

MIDI/Clear software-b_pcnjf5:52 methods104 executions104 passed0 failed0 skipped. Logger software-8yfh8ghw:3 methods6 executions6 passed0 failed0 skipped. Both Debug configurations clean. Supervisor PASS, no timeout/infrastructure error. Full gate/platform/integration/hardware NOT RUN. Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4c-20260928T003237Z. Now reconcile C4 shared iOS evidence ownership and C10 take-bound sidecar cache tests; preserve production ownership. Free disk lastcheck10GiB; check before full gate. No commit/push/install.


## Batch4C media and ownership focused reconciliation — clean subclusters

C4/C10 software-9ixm76by32methods64executions64pass0fail0skip. Generic synthetic adapters/replay software-il9bwtph62methods124executions124pass0fail0skip. Removed-media/UI final focused software-9sct8n8r124methods248executions248pass0fail0skip: XCTest68methods136executions; SwiftTesting56methods112executions; bothDebugconfigurations identical. Prior media run248/244/4/0 retained: stale MainMenu coach-wiring assertion and old Practice Start await source-call shape; reconciled to intentional de-scope and4B2 exact-owner guard. No production weakening/resource restoration.

Media75 historical cases fully classified. A12 migrated to original geometry, C6 algorithms retained. B52 mapped to explicit no-resource/synthetic/offline behavior or proven obsolete performance characterization. D5 old Notation Lab resource expectations retired: source/history proves current Advanced overview bypasses hidden lab bridge; no new product feature invented. Factory metadata/direction/speed/fader and rejection behavior retained through explicit temporary original bundle. The short12stroke template was authored notation, not itself asserted to be an extracted recording.

Now run combined focused4C suite before4D. Fullgate/platform/integration/hardware NOT RUN. Donor0changes; no new/deleted source paths;16intended paths including4append-onlydocs. Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4c-20260928T003237Z. No commit/stage/push/install.


## Batch4C combined focused PASS; ReferenceTear known serialization check in progress

Combined software-p3vvi822:267methods534executions534passed0failed0skipped. XCTest211methods422executions422passed; SwiftTesting56methods112executions112passed. Both Debug configurations identical. Supervisor PASS, no timeout/infrastructure error. Following master4C.7, reassess the previously intermittent ReferenceTear raw JSON-byte assertion before4D. Only diagnostic before/after serialization logging added to that one test; no production change. Full gate and platform matrix NOT RUN.


## Batch4C ACCEPTED — automatic4D continuation

Combined267methods534executions534pass0fail0skip (XCTest422,SwiftTesting112), plus separate ReferenceTear1method2executions2pass0fail0skip. Union268methods536executions536pass0fail0skip. BothDebugconfigurations equivalent. No ReferenceTear byte mismatch reproduced; exact test assertion unchanged. Allknown reconciliation clusters resolved; productionownership/schemas/resources preserved. Donorunchanged;16intendedpaths,0added/deleted;HEAD/index/stagedunchanged;diffcheckPASS;originaldocprefixes retained. Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4c-20260928T003237Z/RESULT.md. Fullgate/platform/integration/hardware NOT RUN yet. Starting4D scripts/build.sh all exactlyonceinitially, defaultintegrationoptout, externalnative supervisor. Anyrequired4Dfailure hardstops; no4Drepair. Free16GiB following verified completed-cache archiving.


## Batch 4D running — Downloads permission checkpoint (2026-09-28)

4B and 4C are accepted; the single canonical `scripts/build.sh all` invocation is still RUNNING under its original external supervisor. Python suites passed 17/17 and 87/87 (104 total, zero failed/skipped). Partial first-configuration XCTest: 658 started, 650 passed, zero failed, seven skipped, one waiting. Swift Testing, second configuration, and all platform build legs NOT RUN yet. These are progress counts, not gate acceptance.

`CaptureReliabilityPhase1CoreTests/testPythonBytecodeCachesAreIgnoredAndUntracked` is blocked opening the worktree index at `/Users/karlwatson/Downloads/ScratchLab/.git/worktrees/source7/index`. The saved process sample and macOS TCC diagnostic confirm the test host is awaiting Downloads-folder permission. CUA prohibits interacting with UserNotificationCenter; user was asked to handle the prompt. No permission bypass, retry, source repair, process signal, device change, install, commit or push occurred.

Evidence: `/Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4d-20260928T005903Z`, including GATE-PENDING.md and downloads-permission-diagnostic.log. Native active evidence: `/private/tmp/scratchlab-native-gates/software-1ou65_66`; supervisor PID4589, xcodebuild4590, test host4777, unified exec session53004. Original supervisor timeout3600 seconds. Do not restart or rerun this gate. Check live status/receipt first. If permission is allowed before the deadline, continue the SAME invocation; otherwise preserve its timeout/infrastructure result and obey the 4D hard stop. Do not proceed to 4E unless 4D passes.

These four append-only workflow entries are the only intentional worktree edits during the pending gate checkpoint. Compare post-gate inventory against the original baseline while accounting for these documented append operations.


## Batch 4D HARD STOP — supervisor timeout (2026-09-28)

The original and only canonical `scripts/build.sh all` invocation ended PROCESS TIMEOUT / HANG, exit124, after its original3600-second native deadline. Child4590 exited via SIGTERM(-15), was reaped, and zero owned survivors remained. This supersedes the earlier RUNNING permission checkpoint without deleting it.

Fresh counts: Python17/17 and87/87 passed (104 total, zero failed/skipped); XCTest658 distinct methods/starts,657 completed,650 passed,zero failed,seven skipped,one interrupted. Swift Testing NOT RUN(0). Second native configuration NOT RUN. iOS/full macOS Release/macOS CXLRelease/watchOS NOT RUN(all four, no exit codes).4E NOT RUN. Real-device integration NOT RUN(0); physical capture/hardware acceptance NOT RUN(0).

Blocked method: CaptureReliabilityPhase1CoreTests/testPythonBytecodeCachesAreIgnoredAndUntracked, Data(contentsOf: Git index) in Downloads. Saved process sample and TCC logs establish Downloads permission wait. User subsequently reported 'allowed', after the completed timeout was discovered; this does not revive the terminated invocation or prove permission for a future unique test-host identity. No retry or in-gate repair authorized by the current hard-stop rules.

Evidence retained at /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4d-20260928T005903Z; native folder atomically relocated there after verified cleanup, preserving complete log/receipt/process identities/products and partial xcresult. The partial bundle lacks Info.plist; xcresulttool exit64 is evidence-reader incompleteness, not another test failure. Log ledger is authoritative for partial counts.

4B focused acceptance remains1052 executions1040passed0failed12skipped;4C final combined+Tear remains536executions536passed0failed0skipped. These do not establish full software verification. Post-gate source/donor audit: no source/test changes, no additions/removals; only four documented append-only workflow files changed; donor unchanged; HEAD/index/staged unchanged; git diff --check passed.

Final candidate status: BLOCKED — BUILD/RELEASE DEFECTS REMAIN. Here the blocker is gate infrastructure/release verification, not a newly demonstrated production defect. No commit/stage/push/install/device change/real integration/physical capture/media restoration/Learner change.

Next human action: authorize a bounded gate-environment/Downloads-permission preflight and a fresh4D attempt, preserving this timeout as historical evidence. Do not silently rerun. Full requested report: evidence/FINAL-REPORT.md in the package above.


## Batch4D retry PhaseP — PERMISSION BLOCKED / HARD STOP (2026-09-28)

New authorization permits bounded repository-access preflight, then one fresh full gate only after access PASS. Implemented scripts/native_repository_preflight.py and seven disposable regressions; supervisor can consume a PASS context once with the same native host identity/products and relevant input hashes. build.sh includes preflight regressions; isolated routing regressions strip the real reserved context. No production or Swift test changed. Actual canonical-index assertions retained; a temporary Git fixture alone would weaken that coverage.

Accepted Python infrastructure regressions24executions24passed0failed0skipped (new7+existing17). Initial new-suite development run7executions6passed1error0skipped was a /var versus /private/var fixture normalization issue, corrected before acceptance.

Native PhaseP bounded probe: host com.machelpnz.scratchlab.nativegate.2db3ca3aef71, PID8209; xcodebuild7996; supervisor7995. One unchanged XCTest started,zero passed,zero failed,zero skipped,one interrupted. External supervisor120-second deadline returned PROCESS TIMEOUT / HANG124; child reaped,zero survivors. TCC log proves kTCCServiceSystemPolicyDownloadsFolder AUTHREQ_PROMPTING for this exact host at17:37:55.836 local; process sample confirms index open at CaptureReliabilityPhase1Tests.swift4593. PhaseP classification PERMISSION BLOCKED(exit77), not software failure.

Fresh scripts/build.sh all NOT RUN(0 invocations).4D-R tests/platforms NOT RUN.4E NOT RUN. Historical hour-long4D timeout retained unchanged; its partial650passes are not fresh results. No security/TCC database/reset/permission modification. No commit/stage/push/install/real integration/hardware/media restoration/Learner change.

Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4d-retry-20260928T043511Z. Native retained context native/access-xnouy0b3. A future authorized confirmation must use this SAME host identity/products, preserve this failed preflight receipt under a separate attempt path, and not create another fresh identity merely to confirm its permission. Current prepared-context validation correctly rejects this non-PASS context.

Human action: grant Downloads-folder permission to this exact ScratchLab host through macOS privacy UI, then authorize bounded confirmation. Stop under P.3/P.7; no full gate until native access PASS. Final status BLOCKED — BUILD/RELEASE DEFECTS REMAIN (permission/infrastructure prerequisite, not a demonstrated app defect). See FINAL-REPORT.md in the evidence package.


## Retained-host preflight PASS; fresh4D deterministic failure / HARD STOP (2026-09-28)

User enabled Downloads access and explicitly required reuse of host com.machelpnz.scratchlab.nativegate.2db3ca3aef71. Reused its exact existing products/context without changing source. Preserved previous blocked preflight by verified atomic relocation recorded in evidence. Bounded native confirmation PASS:2executions2passed0failed0skipped; supervisorPASS0,reaped,0survivors. Fresh full gate later passed the formerly blocked Git-index method in0.030s. Downloads blocker resolved for this host.

Ran exactly one authorized fresh scripts/build.sh all, default integration0, original external3600-second supervisor. Python suites17+7+87=111executions111passed0failed0skipped. Fresh native XCTest753methods/753starts,752completed,744passed,1failed,7skipped,1interrupted. Swift Testing NOT RUN0; second native configuration NOT RUN. Required platforms0/4executed;4E NOT RUN. No retry.

Required failure: CaptureReliabilityPhase1CoreTests/testRoutineCaptureBuiltInMicrophoneGuardPrecedesRecordingPublication, CaptureReliabilityPhase1Tests.swift3176. First raw-source publication320331[utf8] (MacCaptureEngine6897) lies in #if DEBUG optional testOnly_routinePreparation hook; guard322176[utf8] is at6930; ordinary publication324469[utf8] is at6976. Likely stale source-order oracle matching the DEBUG seam introduced with earlier preparation ownership. Ordinary production guard still precedes ordinary publication; no production microphone-capture defect established. Newly observed in the full gate, not covered by searched4B/4C focused logs. No repair during4D.

To honor immediate hard stop upon observing the required failure, SIGINT sent to exact supervisor16024. Receipt records INFRASTRUCTURE ERROR70/interruptedBy2,child16025exit-15/reaped,0survivors. This is intentional cleanup after an actual deterministic failure, not a renewed permission timeout. One later running method testSessionExportCoordinatorSaveArchiveUsesChosenDestination was interrupted, not failed. Partial xcresult lacks finalized Info.plist; reader exit64, counts from retained native event log.

Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/batch4d-confirmation-20260928T085901Z. Full native logs/receipt/products/partial bundle remain in original retained context at batch4d-retry-20260928T043511Z/native/access-xnouy0b3. Historical hour-long gate and prior blocked preflight preserved. Completed old build caches archived with streaming SHA verification; current passing host/products untouched.

Pre/post-gate inventories show0source/test/donor drift; only this final append to four workflow documents is intentional. HEAD/index/staged unchanged; diffcheckPASS. No commit/stage/push/install/hardware/real integration/device changes/media restoration/Learner changes. Final status BLOCKED — SOFTWARE DEFECTS REMAIN (required deterministic test contract unresolved; not established production failure). Next human action: authorize bounded reconciliation of the source-order regression and focused guard/ownership verification, then separately fresh gate authorization. Do not repair or rerun under exhausted4D authorization.


## Bounded microphone-guard audit — DEBUG hook boundary HARD STOP (2026-09-28)

Read the new authorization and independently traced the failing assertion, ordinary start, DEBUG hook, microphone policy, publication and pending media arm. No code or test edits made. The prior characterization as only a stale/over-broad text assertion is insufficient under this authorization's stricter DEBUG-hook invariant.

MacCaptureEngine.swift6895–6921: the installed testOnly_routinePreparation branch queues isRoutineRecording=true at6897, invokes the hook on sessionQueue, records prepared take/media identity, opens the take MIDI window, arms PendingRoutineMediaStart at6910, then returns at6921. The ordinary microphone policy is evaluated only later at6930. publishRoutinePreparation checks request ownership/liveness, not microphone suitability. armPendingRoutineMediaStart checks the same liveness and sets pendingRoutineMediaStart; it does not evaluate microphone policy. Thus the DEBUG branch can publish/arm without the policy evaluation. This directly violates the user's Phase2/Phase4 required hook boundary; HARD STOP before test reconciliation.

The ordinary path still evaluates/refuses at6930 before its active publication6976 and later media work. The hook and branch are #if DEBUG; checked Release/CXLRelease configurations do not define DEBUG. No shipping-release microphone-policy bypass or macOS TCC bypass is established. The named guard is an application capture-suitability policy: builtInMicrophone + calibrationNoClick + silent; it is not macOS authorizationStatus. Hook preparation does not by itself prove finalized successful media; active UI publication and pending media arm already violate the required invariant. Existing ownership-test source uses hook→frame claim→writer confirmation successfully, corroborating that this is not merely a held preparation barrier. These tests were read, not rerun.

Fresh tests/builds/preflight/4D/4E NOT RUN (0executions/0invocations). Retained host com.machelpnz.scratchlab.nativegate.2db3ca3aef71 unchanged; prior Downloads preflight2/2PASS remains historical.4B0–4B3 and all completed work remain source-preserved; no new verification claimed.

Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/microphone-guard-audit-20260928T103522Z includes authorization, exact source excerpts, compilation conditions and inventories. Only append-only workflow docs changed. No commit/stage/push/install/hardware/real integration/TCC/security/device/media restoration/Learner changes. Final status BLOCKED — SOFTWARE DEFECTS REMAIN. Next human action: authorize a bounded DEBUG preparation/admission boundary repair, preserving ordinary microphone policy and4B0–4B3 ownership, before behavioral guard tests and another gated verification sequence.


## Bounded DEBUG suitability admission repair — focused PASS (2026-09-29)

New explicit authorization permits the boundary repair and conditional preflight→one fresh4D→read-only4E. Canonical main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c; entry source/donor inventories have0drift. Moved the existing DEBUG deterministic-preparation block intact after the existing shared input-suitability refusal. Added a DEBUG-only raw device-description fixture; classifier/predicate/error wording stay one production source of truth. Ownership, reservation, ordinary non-DEBUG sequencing, timing, Stop/drain and export schemas unchanged. No safety assertion changed. CXL already uses the same media-admission method; no new policy route introduced. Structural Release projection unchanged aside from local let→var/comment/whitespace; Release builds not yet verified.

MacCaptureEngine.swift and ReferenceBeatPilotTests.swift are the only source/test edits. Four new behavioral methods cover refused built-in isolated/silent input with no publication/arm/metadata/callback promotion; allowed routed input; allowed built-in input outside isolated/silent mode; admitted held preparation cancelled by Stop. Explicit holds/completion barriers; no sleeps. Original guard-order method and existing4B0–4B3/invalidStop/MIDI/lifecycle suites included. Focused664XCTest executions662passed0failed2skipped332distinct methods; bothDebugconfigurations332executions331passed0failed1skip,identicaloptions. New4methods8/8passed; originalmethod2/2passed. Onlyskip is excludedphysicaloutputreadback integration. SwiftTesting/PythonNOTRUNfocused. SupervisorPASS0,reaped,0survivors.

Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/debug-admission-repair-20260928T110827Z. Retained host com.machelpnz.scratchlab.nativegate.2db3ca3aef71 reused without regeneration. Prior consumed gate/preflight receipts/logs/bundles preserved by hash-verified relocation under retained history, recorded in retained-history-relocation.json. Bounded120sDownloads preflight currently running; do not start4D unlessPASS. IfPASS, exactlyonefreshscripts/build.sh all in deterministic mode with external supervisor; stoponfirstrequiredtestfailure/timeout/infrastructure/buildfailure,no4Drepairorretry.4Eonlyaftercomplete4DPASS. No commit/stage/push/install/hardware/integration/TCCreset/mediarestoration/Learner.


## DEBUG admission repair accepted focused; fresh4D HARD STOP (2026-09-29)

Supersedes the preceding running checkpoint. Bounded Downloads preflight PASS:2executions2passed0failed0skipped; identical retained native host com.machelpnz.scratchlab.nativegate.2db3ca3aef71,120sbound,supervisorPASS0,reaped,0survivors. Ran exactlyONEfreshscripts/build.sh all,defaultdeterministic,external3600ssupervisor. No retry.

Python: test_mac_test_gate17/17;test_native_repository_preflight7/7;test_capture_pipeline87/87=111executions111passed0failed0skipped. XCTest:firstconfigurationTestSchemeAction1510starts/distinctmethods,1509completed,1495passed1failed13skipped1interrupted. Configuration2NOTRUN. SwiftTestingNOTRUN0. FourrequiredplatformlegsNOTRUN0/4;4ENOTRUN. RealintegrationNOTRUN0;physicalhardwareNOTRUN0.

Failure:LivePerformedNotationTrackerTests/testEarlyReturnFinalizationPathsReleaseTheWindow,LivePerformedNotationTrackerTests.swift3181,firstconfiguration. XCTUnwrap of literal self.scratchPlaybackController.cancelRoutineOutputCapture() returnednil. Its preceding runtime release/preview-rearm assertions passed. Existing4B1 moved this cleanup into failRoutinePreparation→releaseRoutinePreparationResources; that helper conditionallycancelsoutput and releasesexactMIDIowner. The literal was absent before and after the currentrepair and the cleanuphelper is unchanged. Saved4B1candidate.diff proves earlier helperextraction removedtheinlinecall. Likely stale source-text safetyoracle, newly reached inthisfullgate; no newlydemonstratedMIDIleak. Failedtestunchanged; no4Drepair.

Automatichardstopmonitor observedfailure andSIGINTed exact supervisor21613 withverifiedkernelbirth. Cleanupreceipt INFRASTRUCTURE ERROR70/interruptedBy2:child21615exit-15,reaped,0survivors. Intentional interruption afterdeterministicfailure,notatimeoutorTCCdenial. LivePerformedNotationTrackerTests/testLiveCardInvalidOrStaleLoopContextKeepsDenseUnwrappedGeometry wasinterrupted,notfailed. Partialxcresult lacksfinalizedInfo.plist;readerexit64;eventledgerauthoritative.

Theboundedrepair remainsfocusedPASS664executions662passed0failed2skipped332methods,bothDebugconfigurations. Newfourmethods8/8PASS,originalguard2/2PASS; freshfullgateoriginalguardpassedagain. Existing4B0timing42/42,4B1preparation46/46,4B2outerStart48/48,4B3CXL54/54,MIDIStop/drain42/42focusedexecution subsets passed. Theseoverlap664andarenotadditive.

Freshpartialskipinventory:13distinctexecutions=9optionalexternalfixtures(A),2explicitintegrationexclusions(G),2conditionalexternalfixtureexportprerequisites(H). take003realstreammethodNOTRUN;itprovidesrealcapturedCC6livegeometryflatteningcoverageandisnotcleared. Freshwarninginventory:3taggedwarnings(destination+2testmediaMainThreaddiagnostics),plus1831AVFoundationnoninterleavedfixtureformatnotices;allretained,noneestablishnewcapture/exportdefect. ReleasebuildwarningsNOTRUN.

Pre/postgatecheckoutinventoriesbyteidentical;afterthisappendonlyfourworkflowdocschangedbeyondthetworepairfiles. HEAD/index/stagedpreserved;donor/protectedJSON/resources/removalspreserved;diffcheckPASS. No4Dsource/test/infrastructureedits. No commit/stage/push/install/integration/hardware/TCCchange/mediarestoration/Learner. Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/debug-admission-repair-20260928T110827Z. FinalcandidateBLOCKED — SOFTWARE DEFECTS REMAIN(requiredtestcontractunresolved;notaprovenproductionMIDIleak). Nextauthorization:boundedreconciliationofbothfailure/no-sidecarcleanupcoveragewithcurrenttoken-scopedhelpers,retainsafetyintentandbehavioralproof;onlythenfocusedverificationandseparatelyauthorizedfreshgatewithsamehostidentity. Do notrepairorretryunderthisexhausted4Dauthorization.


## Early-return cleanup reconciliation audit — ownership HARD STOP (2026-09-29)

The new authorization required verifying helpers before modifying the stale structural test. Read-only tracing confirms that the historical inline catch cleanup was extracted by 4B1 into failRoutinePreparation -> releaseRoutinePreparationResources. releaseAbandonedTakeMIDIWindow checks both take ownership and exact token under midiCaptureLock; stale/duplicate calls do not release or publish. Preparation cleanup is serialized before successor resource preparation on sessionQueue, with token-scoped MIDI release, sidecar media identity checking, and owner-checked preparation publication.

A separate no-sidecar finalization publication defect triggers the explicit Phase 2 HARD STOP. finalizeRoutineRecording validates A's MIDI token, then its no-sidecar early return releases A's MIDI window and queues publishRoutineFinalization. It does not set isRoutineFinalizationPending on that path. performRoutineMovieStop can already have set isRoutineRecording=false. beginRoutineStart therefore can admit successor B after A's release. publishRoutineFinalization's deferred MainActor task has no current-owner/URL/generation check before unconditionally clearing isRoutineRecording and isRoutineFinalizationPending and publishing A's status/session state. Its ledger completion is token-scoped, but that does not guard the later global writes. MainActor serialization alone does not establish freshness across that asynchronous handoff.

This is a source-established missing successor-ownership guarantee in the actual no-sidecar path. It is not evidence that releaseAbandonedTakeMIDIWindow releases B, nor a claim that physical capture corruption was observed. A forced A-publication/B-successor interleaving was NOT executed. The existing no-sidecar test drains publication before checking idle/release-count and does not cover the successor interleaving. Per Phase 2, no production/test edit or verification run was made after identifying the unscoped publication. The original stale assertion remains untouched.

Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/early-return-cleanup-audit-20260928T122831Z. Entry source/donor inventories have zero drift. Only this append to TASKS.md, DEV_LOG.md, AI_HANDOFF.md and AI_HANDOFF/next_prompt.md changes checkout files; historical prefixes are preserved. HEAD/index/staged state, prior DEBUG admission repair, donor, protected JSON and intentional media removals remain preserved. No source/test/infrastructure change. Current focused tests, Downloads preflight, fresh4D and4E: NOT RUN, zero executions/invocations. Retained host com.machelpnz.scratchlab.nativegate.2db3ca3aef71 unchanged. Prior focused/gate results are historical only.

Final candidate: BLOCKED — SOFTWARE DEFECTS REMAIN. Next human action: authorize a bounded no-sidecar deferred-finalization publication ownership repair with an explicit A->B interleaving regression, then resume early-return test reconciliation and conditional verification. Do not repair, reconcile the test, run preflight/full gate, commit, stage, push, install, capture hardware, enable integration, modify TCC, restore media or change Learner under this hard-stopped authorization.


## Owner-scoped finalization publication repair — focused PASS (2026-09-29)

Authorized repair implemented in MacCaptureEngine.swift: MainActor-confined exact recording-request ownership now gates all current finalization publication, including notation and delayed artifact-status refresh. Ledger completion is recorded first for the historical token; stale/duplicate publication cannot overwrite successor flags, status, URL or session state. Admission and synchronous publication commit share MainActor isolation. Exact MIDI release primitive and ledger code remain byte-identical. DEBUG-only publication holds exercise real finalization; shipping configurations omit them.

ReferenceBeatPilotTests.swift adds five deterministic regressions covering no-sidecar A release -> B -> late A, ABA with repeated semantic identity, historical error/duplicate completion, normal sidecar completion, pending successor/cancellation, and successful B Stop/finalization. LivePerformedNotationTrackerTests.swift retains its original early-return behavioral assertions and replaces stale inline-cleanup text with shared real-helper and held-publication behavior. Its unchanged MacPractice readiness path uses await -> ownership guard -> readiness guard; the same-file obsolete guard-await assertion now verifies that actual sequence. No Practice production change.

Initial phase12 run: 928 XCTest executions,922 passed,2 failed,4 skipped,464 distinct methods; sole failing method was the stale MacPractice source-shape assertion in both configurations. Five new ownership methods passed10/10. Original early-return method was explicitly deferred until repair verification. Fresh reconciled containing/finalization run:930 executions,926 passed,0 failed,4 skipped,465 distinct methods. Each Debug configuration:465 executions,463 passed,0 failed,2 skipped; configuration options identical. Five new methods10/10; original early-return method2/2. Skips: excluded physical output integration and optional take-003 real-stream fixture, each twice. Swift Testing0; Python NOT RUN focused. Supervisor PASS0,child reaped,zero survivors. Initial failure evidence retained; counts are separate, not additive acceptance totals.

Evidence: /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/finalization-publication-repair-20260928T123310Z. Next: bounded120-second Downloads preflight with retained host com.machelpnz.scratchlab.nativegate.2db3ca3aef71; only ifPASS, exactlyone fresh scripts/build.sh all with default deterministic mode and external supervision. Stop on any required failure/timeout/infrastructure/build error; no4D repair/retry.4E only after complete4D PASS. No commit/stage/push/install/hardware/integration/TCC/device changes/media restoration/Learner.


## Owner-scoped finalization repair — fresh4D and read-only4E PASS (2026-09-29)

- [x] Authorized owner-scoped no-sidecar finalization publication repair, behavioral early-return reconciliation, retained Downloads preflight, one fresh complete4D and read-only4E completed.

Current repair:MacCaptureEngine.swift exact request-token current owner on MainActor; historical ledger completion remains independent; atomic owner validation/current writes; duplicate suppression; guarded notation/artifact refresh. Exact MIDI release primitive and ledger unchanged. ReferenceBeatPilotTests.swift adds5 deterministic ownership regressions; LivePerformedNotationTrackerTests.swift preserves original assertions and exercises actual cleanup/A-B-finalization behavior,plus reconciles obsolete readiness/ownership source shape. No Practice production change. Source/test change scope3files; workflow documents append-only4files.

Accepted focused:930XCTest executions926passed0failed4skipped465methods; bothDebugconfigs465executions463passed0failed2skipped. Initial focused928executions922passed2failed4skipped retained separately; failures were one stale readiness source assertion twice,not a4D retry. New5methods10/10;originalcleanup2/2. Downloads preflight2/2PASS,120sbound,identical retained host com.machelpnz.scratchlab.nativegate.2db3ca3aef71,noTCCreset/regeneration.

ExactlyONEfreshscripts/build.sh all:exit0. XCTest9262executions9138passed0failed124skipped4631methods;eachconfig4631/4569/0/62. SwiftTesting1064executions1064passed0failed0skipped532methods;532perconfig. Python17+7+87=111passed0failed0skipped. Native supervisorPASS0,childreaped,0survivors,no timeout/infrastructure error. All4platformlegsRUN/PASS/exit0:iOS,fullmacOSRelease,CXLRelease,watchOS. Noadditionalleg. Watch canonical signing disabled;distribution/AppStoreuploadNOTRUN.

Fullgate preservation subsets:4B0 42/42,4B1 46/46,4B2 48/48,4B3 54/54,DEBUGadmission8/8,publication10/10,originalcleanup2/2,C6 8/8,invalidStop4/4,MacAnalyzerSlice1 24/24,Slice2 28/28,Slice3 34/34,Slice4 52/52,Slice5A38/38,Slice5B18/18,ReferenceTear82/82. Subsets overlap full totals;not additive.4Acontainment24Pythonpasses;4Bresponsiveness38/38;4C included in complete gate.

Skip audit124executions62methods:A86/43optionalexternalrecordings,G16/8explicitintegrationexclusion,H22/11conditionalprerequisite. take0032skips leaves realCC6livegeometryreplayunverified. Conditionalnotationoverride branch is not exposed by the onlyDEBUGappcaller,whichpassesfalse;separateplaybackoverridecoverageisnotclaimedassamebranch. No required default software path waived. Freshwarnings84occurrences19messages:A0B36C10D10E7F21;5480fixtureformatnotices separately. Concurrency/API/CoreAudio risks retained,no actual unresolvedcapture/exportdefectestablished. Fullwarning/skip inventories retained.

Read-only4E:softwarecandidatePASS. main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c,indexunchanged,0staged.82dirtypaths56modified2existingdeletions24untracked;categoriesA16B17C4D45E0F0. Pre/postgate source/donor drift0;protectedJSONSHA459264664bbd116610440ac179c1060e6b81d0a0ef1923016605ef5d36fed309 unchanged;historicaldocprefixesintact;diffcheckPASS. Preserve unrelateddirtyhunks,recordedmediaremovals,boundaryFindings,derivedInspectionIssues,offline tests and all earlier evidence.

REAL-DEVICE INTEGRATION — NOT RUN (0admitted);PHYSICAL HARDWARE ACCEPTANCE — NOT RUN (0sessions). No commit/stage/push/install/deviceconfiguration/CoreAudioreset/driver/TCCchange/mediarestoration/Learner. Finalcandidate SOFTWARE VERIFIED — READY FOR COMMIT + HARDWARE ACCEPTANCE. Next:review selective commit boundaries,then manual canonical SL Capture routing/AHHH/Load-Re-cue/MIDI/shortcapture/Stop/review/duration/correction/export/archive/reopen acceptance. PreparedCXLcancel/successorcheckonlywhereused. No autonomous furtherdevelopment or execution authorized by this completed report.

Evidence /Users/karlwatson/Developer/ScratchLab-Capture-Reconciliation-Evidence/finalization-publication-repair-20260928T123310Z;FINAL-REPORT.md,4D-RESULT.md,4E-RELEASE-AUDIT.md,exactrepairdiffs,fullaccounting,supervisorreceipt,skip/warningaudits,82pathcategoryledger. Priorreports preserved.


## 2026-09-29 — Selective commit preparation: BLOCKED — COMMIT INTEGRITY

New finalization authorization read in full, including local-storage override. Canonical main/79fb3ecd74d261de5f3fd1f8b1434b620077ae3c preserved. Entry inventory matches final verified source receipt with zero hash drift:82 paths,56 modified tracked,2 existing deletions,24 untracked,zero staged. New evidence destination verified outside iCloud/File Provider roots: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-commit-preparation/. Historical evidence read only; no relocation/deletion/rewrite. No verification worktree created.

Stopped before staging at a demonstrated prerequisite-scope dependency. September26 shipping-media de-scope predates reconciliation:MainMenuView.swift and project.pbxproj are byte-identical to Batch1 entry snapshots. Batch4C changes accepted CaptureReliabilityPhase1Tests assertions to require absence of MainMenu ScratchCoachCardContent/animationStateProvider; both strings remain in HEAD and are absent in the verified dirty MainMenu. Thus excluding that pre-existing work changes the tested candidate; including it needs explicit prerequisite scope resolution under the batch rule prohibiting commits requiring pre-existing work. DemoAudioResolverTests similarly contains a pre-existing suite replacement plus a later4C hunk. Not a new production defect or a current failed test.

Full82-path inventory saved, classification/hunk/secret/untracked audit explicitly incomplete at first hard stop. No stage/commit/push,source/test/infrastructure edit,build,test,install,launch,hardware capture,real integration,TCC/device change or media restoration. Historical complete gate remains valid only for the dirty candidate; no committed-candidate verification claimed. Only four append-only workflow notes added; prior text preserved. Report and exact dependency proof:external REPORT.md and prerequisite-proof.json.

Next human decision:authorize or exclude a separately audited prerequisite commit for the previously verified September26 shipping-media de-scope. Do not infer permission for offline derived-inspection work,passive diagnostics,protected cxl_baby_target.json or other pre-existing hunks. After scope resolution,resume complete selective audit before staging; keep every new verification artifact under the local evidence root and clean verification worktrees under its worktrees/ directory. No production repair or test weakening. Final status BLOCKED — COMMIT INTEGRITY.


## 2026-09-29 — Authorized shipping-media prerequisite staged; verification HARD STOP

The user explicitly authorized the exact previously verified September26 shipping-media de-scope as a separate prerequisite; that scope decision is resolved. Audited22paths/120hunks (20modified,2intentional source/testdeletions), staged only those through an explicit cached patch. Everyselectedmodifiedblob matches its historicalshippingmediahash. MacAnalyzermedia snapshot reconstructed by excluding the laterpassiveMIDIdiagnosticUIhunk, yielding exact76ebdbd2edb0f4bbe884138b95b0d1dc9f793a39732469fd19075f79b6e7e584. Offlineinspection,passivediagnostics,protectedJSON,andlaterreconciliation stayexcluded. Canonical workingfilesunchanged bystaging. Index treeb6790bf94061c3fabb657006d4cd9ebfb131d1cf;cachedcheckPASS;credentialpatternscan0findings;nonewmedia/binary/evidenceorunrelateddeletion staged.

Local-only evidence:/Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/shipping-media-prerequisite/. Exactstagedtree verified in /Users/karlwatson/ScratchLab-Local-Evidence/worktrees/commit0-verification-20260929. Staticprojectresource/runtimeconsumerchecksPASS. Focusednative196executions98methods:72XCTest+124SwiftTesting,allPASS,0failed0skipped,twoDebugconfigurations. Native supervisorPASS0,reaped,0survivors. No realdeviceintegration.

Affectedappbuildsequence HARDSTOPatfirstleg. iOSxcodebuild BUILD SUCCEEDED/childexit0,but supervisorINFRASTRUCTUREERROR70:"Child exited leaving owned processes". Twoownedibtooldworkers17994/17997remained;supervisorSIGTERMcleanupcompleted,childreaped,0survivors;read-onlypsconfirmedbothabsent. ExpectedservicevscontainmentpolicycauseNOTDETERMINED. No timeout,compileerrororfailedtestestablished;failure not waived. macOSRelease/CXLRelease notrun;shippingbundleauditincomplete;standalonewatchnotrun. No retry,policychange,productionrepair,downstreamcommit/installorhardwareaction.

Commit0NOTCREATED;mainHEAD79fb3ecd74d261de5f3fd1f8b1434b620077ae3c unchanged. Keep22auditedpathsSTAGED;44trackedpathsretainunstagedhunks and24untrackedpaths remain. Original selectivebatch stopped atverificationhardstop;fullcommittedcandidategateNOTRUN,installreadinessNOTESTABLISHED,hardware/integrationNOTRUN,nopush. Fourappend-onlyworkflowcheckpointnotes are the onlyworkingfileedits;historicalprefixespreserved. Historicalevidence untouched.

Next humanauthorization:bounded investigationofibtooldworkerownership/lifetime andsupervisorcontract,thenexplicitconditionalretryaftercauseunderstood. Do not askagainfor shipping-media prerequisite permission. Do not weaken containment,adddelays/retriesorrepairproductiontomakeverificationpass. Exact report,patch,per-hunkaudit,testsandfailure receipts reside in the localevidence directory above.


## 2026-09-29 — ibtoold ownership resolved; media prerequisite committed

The bounded authorized investigation proved that the reproduced actool workers were registered shared IBCLIServer services: selected Apple-signed toolchain, distinct session/group, reparented to PID 1, and all four registry FIFO channels open by the same kernel-birth identity. Both exited naturally about 86 seconds after xcodebuild, without signals. The previous ancestry-only normal-exit leak classifier was too broad. Timeout/forced cleanup remains unchanged; no process-name exemption or sleep-based acceptance was added. Original failed receipts remain untouched.

Only scripts/run_mac_test_gate.py and scripts/test_mac_test_gate.py were repaired; both remain outside the media commit. Supervisor regression suite: 25/25 PASS. One disposable reproduction and exactly one conditional Commit 0 retry were used. Retry: focused 196/196 PASS, 0 failures/skips; iOS, full macOS Release, CXLRelease, resource/reference audits and supervisor PASS; child reaped, zero invocation-owned survivors.

Commit 0: bbe362b0507d2c33c7ba2fea44b2c0175a3d39e9, parent 79fb3ecd74d261de5f3fd1f8b1434b620077ae3c, 22 paths / 120 audited hunks, fix(resources): remove retired recorded media from shipping. Exact candidate tree b6790bf94061c3fabb657006d4cd9ebfb131d1cf; working file contents preserved; index empty after commit. 44 tracked modified and 24 untracked paths remain.

Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/ibtoold-investigation/ . Reuse clean detached verification checkout /Users/karlwatson/ScratchLab-Local-Evidence/worktrees/commit0-verification-20260929 now at Commit 0. Canonical checkout remains in place. Continue all-path classification and exact hunk isolation, focused staged verification and remaining reconciliation commits, then clean committed full gate before any install. No full committed gate/install/integration/hardware acceptance yet. No push/reset/clean/stash/rebase. Stop at the first original hard-stop condition.


## 2026-09-29 — selective finalization HARD STOP: omitted actor-isolation test dependency

Three verified commits were created without push: bbe362b0507d2c33c7ba2fea44b2c0175a3d39e9 shipping-media prerequisite (196/196 focused; iOS/full macOS Release/CXLRelease/resource/supervisor PASS); b50f8f603aeebb32cf34498dbd391882671f1b2a approval bounds (316/316 focused PASS); e19ec4c74cb53f35d96cfc3d6066c353e5d2912c deterministic native ownership/admission/preflight (25 supervisor +7 preflight +12 native admission PASS). HEAD is e19ec4c74cb53f35d96cfc3d6066c353e5d2912c.

The next 17-path /290-hunk capture/start/audio/MIDI candidate is STAGED, not committed. Tree edb638d20861373bc7591074fb338e5b3d83eeee. Its isolated focused invocation failed compilation before test execution: LivePerformedNotationTrackerTests.swift:3583 calls @MainActor startRoutineRecording from nonisolated testAFailedStartCannotAbandonAnotherTakesStoppedEvidence. The accepted canonical file already has the needed @MainActor hunk at that method; the commit grouping erroneously deferred its remaining changes. This is an omission in selective staging, not a newly required production repair.

Per the user's original Phase8 hard-stop requirement, no repair, restaging or retry was performed after the failure. Supervisor TEST FAILURE/exit65, xcodebuild reaped, zero owned survivors. Preserve the exact failed candidate and receipt. Next authorization should permit auditing/regrouping the already-accepted LivePerformedNotationTrackerTests hunks with capture, then a fresh focused verification including the omitted dependency before creating that commit. Do not assume authorization to rerun from this checkpoint.

Status:60 dirty paths total;17 staged,28 unstaged tracked (overlap4),19 untracked. All19 untracked are preserved pre-reconciliation offline/diagnostic/media work. Current 82-path classification and exact candidate receipts: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/ . Failure: commit3-capture/native/output.log and receipt.json; omitted-test-dependency.diff retains the current accepted test changes.

Canonical source remains at its required path, production working bytes unchanged, unrelated source/fixtures preserved. Only the authorized supervisor scripts and append-only workflow records changed during this turn. Verification worktree /Users/karlwatson/ScratchLab-Local-Evidence/worktrees/commit0-verification-20260929 has detached HEAD e19ec4c and the same staged capture tree, no unstaged changes. Historical evidence remains untouched. Remaining review/export, deterministic fixture migrations and documentation commits, clean final full gate, install, software smoke, real-device integration and physical acceptance are NOT COMPLETE/NOT RUN. Do not install this partial series. Final status: BLOCKED — COMMIT INTEGRITY (staged candidate dependency omission).


## 2026-09-29 — Authorized capture regrouping; verification invocation HARD STOP

Audited the complete LivePerformedNotationTrackerTests diff: all11 existing hunks are C1 capture dependencies (Start-owner assertions, exact MIDI endpoint/drain fixtures, actor isolation and real early-return publication cleanup coverage). The omitted @MainActor on testAFailedStartCannotAbandonAnotherTakesStoppedEvidence entered the finalization-publication repair and is present in the final successful4D hash a6ed492a3fa8de74eb890c4d28b0a5ae36285270b679e40acf3efa58dc02cf3b. No new production repair. Added only these existing11 hunks; original17 staged paths unchanged. Reconstructed candidate18paths/301hunks, tree 4ad773e708cf12219f864aff2435a836639d8254; source working bytes preserved. Canonical and local verification indices match. Cached check and hash/secret/resource audits PASS.

Fresh focused command compiled and supervisor exited0/reaped/zero survivors, but executed ZERO TESTS in both configurations. Executor supplied target-prefixed selectors to native_invocation, which already adds ScratchLabDesktopTests/, producing duplicate target components. This is an invocation error, not a test pass or established production failure. Result accounting caught it. No capture commit or retry occurred. HARD STOP: BLOCKED — CAPTURE COMMIT INTEGRITY.

HEAD remains e19ec4c74cb53f35d96cfc3d6066c353e5d2912c; bbe362b, b50f8f6 and e19ec4c unchanged; no push. Preserve staged18-path candidate and both runs. Current60 dirty paths:18staged,27unstaged tracked (overlap4),19untracked. Four workflow files receive only this append-only checkpoint; all other working bytes unchanged.

Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/commit3-capture-regrouped/ . AUDIT.md, hunk-receipt.json, tracker-hunk-audit.json, green-comparison.json, staged.patch, native/accounting.json, native/receipt.json and REPORT.md. Earlier commit3-capture failure evidence remains byte-identical. New evidence/cache/worktree paths confirmed outside iCloud. Canonical checkout remains fixed.

Next authorization: one corrected-selector focused invocation against this unchanged staged tree; pass class/method selectors WITHOUT the target prefix to the existing helper. Exact proposed command is retained as proposed-command-NOT-RUN.txt. Require nonzero complete selected suite coverage in both Debug configurations, including complete LivePerformedNotationTrackerTests, and independently audit any existing external-fixture skips. Do not alter source, pull additional hunks, or retry after any failure. Only after successful verification may capture commit and remaining review/export, deterministic fixture and append-only documentation commits resume. Clean committed fullgate, platform builds, install, smoke, real-device integration and hardware acceptance remain NOT RUN for this candidate. Do not install this partial series.


## 2026-09-29 — One corrected invocation executed; redundant selector HARD STOP

The user accepted the unchanged18-path/301-hunk candidate and authorized exactly one prepared corrected-selector invocation. Candidate tree 4ad773e708cf12219f864aff2435a836639d8254, HEAD e19ec4c74cb53f35d96cfc3d6066c353e5d2912c; no source/test edits, regrouping or restaging occurred. Exact emitted command and prefix checks are recorded under /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/commit3-capture-selector-corrected/ . Duplicate target prefixes were absent. The earlier zero-test invocation remains INVALID AS VERIFICATION, not a test failure; its evidence is unchanged.

One invocation completed:436 distinct XCTest methods,872 executions (436/configuration),870 passed,0 failed,2 existing skips. Each Debug configuration:435 passed/0 failed/1 skipped. Complete LivePerformedNotationTrackerTests:128 methods each configuration, including one missing-external-take003 skip. SupervisorPASS0,childreaped,zero survivors,zero signals; fresh kernel-birth survivor check also zero. No Swift Testing methods were selected by this XCTest-focused command.

HARD STOP under the user's explicit mistargeted/zero-selector rule: ReferenceMotionReviewViewportTests/testBackingPreviewHeldBindingCanBeStoppedWithoutLateReadiness resolved to zero methods. The method actually belongs to extension ReferenceAuthoringViewModelTests and PASSED in both configurations through the separately selected complete class. The executor's preflight incorrectly checked class and method presence in one source file without verifying class membership. This is a redundant selector error, not an executed test failure or evidence of a production defect. All436 intended methods match the final4D expected method set in both configurations; no intended coverage is missing, but the explicit selector contract is not satisfied.

No retry, source repair, test repair or capture commit. Existing bbe362b/b50f8f6/e19ec4c commits unchanged, no push.18paths remain staged;27tracked paths retain unstaged hunks (4overlap);19untracked unrelated paths preserved;60dirty unique. Required workflow records receive only this append-only checkpoint. Canonical and verification indices still match. All new evidence remains outside iCloud; historical evidence preserved.

Next human decision: whether to accept the demonstrated complete executed coverage and waive only the redundant mistargeted selector, authorizing the exact staged capture commit and continuation WITHOUT another test run. Do not infer that waiver. If instead another invocation is authorized, source-class membership must be validated; the actual backing-preview method already resides under the selected ReferenceAuthoringViewModelTests class. Full committed-candidate gate/platform builds/install/smoke/integration/hardware acceptance remain NOT RUN for this partial series. Final status BLOCKED — CAPTURE COMMIT INTEGRITY (selector contract). See REPORT.md, selector-accounting.json, native/accounting.json, command.txt and pre-run.json; preserve pre-run.json as evidence of the inadequate preflight rather than rewriting it.


## 2026-09-29 — Capture committed; review/export dependency HARD STOP

The explicit redundant-selector waiver was accepted without rerunning capture tests. Capture commit 77339da72eb6701ea733e7f11d2a96a2ee064312 descends from e19ec4c74cb53f35d96cfc3d6066c353e5d2912c. Exact18 paths/301 hunks and staged diff hash match; post-commit index cleared and unrelated working bytes preserved. Verification remains436 distinct methods/872 executions:870 passed,0 failed,2 existing missing-take003 skips. The invalid ReferenceMotionReviewViewportTests selector is INVALID/waived only; the actual ReferenceAuthoringViewModelTests method independently passed twice. Existing bbe362b/b50f8f6/e19ec4c commits unchanged; no push.

Automatic continuation prepared the7-path/136-hunk review/export candidate, with canonical and local verification indices matching. Its single focused invocation (109 intended methods per Debug configuration) FAILED COMPILATION before any test executed: CaptureReliabilityPhase1Tests.swift:25258 and25265 in the staged verification tree call newly throwing builder.reviewDocument without try. The exact existing canonical hunk already supplies both try keywords in SessionArchiveReferenceTearEvidenceTests.testSnapshotDrivenDocumentsRetainOriginalReviewReplayAndMetadata. Executor incorrectly deferred this API-dependent hunk to the later fixture commit. This is a selective staging omission, not an established need for new production code. Supervisor TEST FAILURE/exit65, child reaped, zero surviving owned processes,0 test executions.

HARD STOP: no repair, regrouping, restaging, retry or review/export commit after failure. CanonicalHEAD remains77339da; the failed candidate remains staged identically in both checkouts. All source/test/untracked working bytes remain unchanged. Only these four workflow records receive this append-only checkpoint. Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/commit4-review-export/REPORT.md, native/output.log, native/receipt.json, native/test-summary.json, staged.patch, omitted-review-document-dependency.diff and stopped-state.json. All new verification artifacts are outside iCloud; historical evidence is untouched.

Review/export, deterministic fixture and documentation commits remain pending. Clean committed full gate, all four final platform builds, final reconciliation SHA, installation and software smoke are NOT RUN/NOT ESTABLISHED. Real-device integration and physical hardware acceptance are NOT RUN. Preserve unrelated derived-inspection/media, passive MIDI diagnostics and pre-reconciliation documentation hunks. Do not install the partial series. Next human decision: authorize bounded review/export regrouping of the already-existing dependent test hunk, full dependency audit and a fresh focused verification; do not infer permission to retry from this checkpoint.


## 2026-09-29 — Review/export and deterministic fixtures VERIFIED; final committed gate pending

User-authorized composition-only dependency audit/regrouping completed. No new production repair. The original review/export compile failure/zero-test receipt remains untouched. reviewDocument must throw for conflicting/invalid saved human decisions; its archive writer/validator and shared Share/Save/Upload paths propagate that contract. Audited the entire changed API surface and every remaining test hunk: selected three R1 hunks (both try tokens in one hunk, selected-sidecar persistence assertion, persisted reload assertion), left39 independent fixture hunks for the following commit. No ambiguous hunk remained.

Review/export commit0822538a597bd1973128362cdb79362e46b8da9c, parent77339da72eb6701ea733e7f11d2a96a2ee064312:8paths/139hunks. Compile-only full Debug host/test target PASS. Focused194methods,194/configuration,388executions,388passed,0failed,0skipped. Every selector executed in both configurations. SupervisorPASS,reaped,zero survivors. Exact tree/diff/parent/path auditPASS; canonical working bytes preserved. Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/commit4-review-export-regrouped/REPORT.md.

Fixture commit565cec614e83cc89099b18219bbad5b6c8a94771, parent0822538:8paths/69hunks. All shared SyntheticNotationFixture callers and the existing DVSLiveLogger completion seam/test adaptations grouped coherently; no new source behavior repair. Compile-only PASS. Focused181methods,181/configuration,362executions:360passed,0failed,2existing skips. XCTest342executions340pass2skip; SwiftTesting20/20pass. Skips are the absent20260731 hardware fixture, matching historical final-green evidence, not waived physical coverage. SupervisorPASS,reaped,zero survivors. Exact commit auditPASS. Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-09-29/selective-reconciliation/commit5-fixtures/.

Preserved chain:bbe362b ->b50f8f6 ->e19ec4c ->77339da ->0822538 ->565cec6. Accepted capture coverage remains872executions870pass2take003skips; no capture-focused rerun. No push/amend/rebase/reset/clean/stash. Canonical checkout stays fixed. All new evidence/cache/worktree output stays outside iCloud under /Users/karlwatson/ScratchLab-Local-Evidence/. Historical evidence and unrelated source/offline fixtures/passive diagnostics remain unchanged.

Selected documentation is insertion-only reconciliation history relative to committed records; pre-reconciliation insertions are preserved in the working tree but excluded from this commit using exact baseline-to-current line mapping. This record does not claim completion of the next gate. Continue automatically: commit/audit documentation, classify remaining dirty paths, verify the clean final committed tree with scripts/build.sh all (real-device integration disabled), require XCTest/SwiftTesting/Python and iOS/fullmacOSRelease/CXLRelease/watchOS PASS, then stage/install the canonical Mac app only non-destructively and smoke it. STOP for Karl's physical hardware input afterward. No final gate/install/smoke/hardware acceptance has run at this checkpoint. Stop on any genuine gate failure; no repair or retry.

- [x] Review/export composition audit, focused verification and exact commit audit.
- [x] Deterministic fixture dependency audit, focused verification and exact commit audit.
- [ ] Clean committed-candidate full gate and all required platform builds.
- [ ] Verified canonical macOS staging/install and software smoke.
- [ ] Karl's physical hardware acceptance; software success is not hardware proof.


### 2026-10-03 — Verified fader checkpoint (commit/push authorized)

Karl requested a checkpoint, commit and push. Source commit 876f70f43cd963fa46190e470dd846543bbfb883
(`fix(cxl): preserve separate fader evidence across capture and export`)
contains the exact 12-file candidate previously verified in isolation. It adds
separate Crossfader/Right channel evidence and notation, combined mute spans,
and retention of real held observations and actual gain at normal capture
boundaries. Real reconnect/mapping changes still invalidate state. Missing
observations remain unknown. No audio DSP, motion decoder, scoring or Store
signing changes were added during checkpointing.

Validation retained without repeating unchanged tests: scripts/build.sh all
PASS — 9,158 XCTest passed, 124 skipped, 0 failed; 1,064 Swift Testing passed;
122 Python passed; iOS/full macOS Release/CXLRelease/watchOS builds PASS.
Focused startup/persistence coverage: 124 executions PASS. Source commit tree
and staged patch match the passed candidate exactly; all process receipts
show reaped children/no survivors. This is software proof, not physical
startup acceptance.

Installed candidate: /Users/karlwatson/Applications/SL Capture fader start 20261003.app.
It was built before the Git checkpoint from source identical to the committed
candidate. Existing Developer-ID overlay, Hardened Runtime, signature,
entitlements and Store/local functional payload parity verified. The Store
contract is unchanged. New-app launch and physical startup acceptance were
NOT RUN at the installation handoff. Earlier independent fader cuts were
recorded/operator accepted; both-closed/reopen-one was operator-confirmed
only and was absent from that recorded take. Do not promote these to complete
hardware acceptance. MOTION UNKNOWN before AHH and physical calibration
remain unresolved.

Next operator action: save/quit the old app and open the installed update.
One approximately 15-second Movement Check, no beat or Watch required:
move both faders once and park both closed before Record; scratch through
AHH without touching faders; open crossfader only (still muted), then right
channel (audio returns); stop/save/export one ZIP. Both lanes must be known
from the start; platter motion must remain shown while muted.

Publication branch: codex/cxl-fader-checkpoint-20261003 on origin
(https://github.com/mastak007/ScratchLab.git). Source and checkpoint notes
are separate commits. This branch retains the 14 existing local ancestor
commits through c96b88e; publication does not advance remote main. Unrelated
dirty/untracked work and historical workflow entries remain local and
unchanged. Only the new checkpoint entry is staged in each workflow file.
No media, generated artifacts or machine credentials are added.

Verification/report: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-03/recording-arm-fader-state/REPORT.md.
Commit/publication receipts: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-03/fader-checkpoint-publish-20261003T004015Z.
All new checkpoint artifacts are outside iCloud; canonical checkout remains
at its original path. Read publication-result.json for the final remote SHA
rather than inferring remote success from this pre-push checkpoint entry.


### 2026-10-03 — Startup accepted; fader review warnings repaired and verified

This entry supersedes the earlier startup NOT RUN and warning-repair-in-progress statuses.
Karl supplied A7F4D464 and explicitly confirmed that opening only the crossfader
kept sound muted, then opening the right channel restored it. The recorded take
preserves both genuine held observations, complete separate-control coverage,
and a closed combined gate until 11.526655s. All 868 in-take mixer messages match
raw MIDI, all 55 canonical records agree with the controls, and saved draft,
source binding, media hashes and ZIP integrity checks pass. The internal WAV is
post-software-fader audio, not an external master-return measurement. Independent
cuts and startup behavior are accepted; this does not claim full calibration or
complete hardware acceptance. No repeat fader take is needed for this repair.

Selected bounded task: correct stale fader-specific review warnings. Root cause:
applyingMixerFaders updated the intervals but retained crossfader-only reasons.
Source commit fea656ffacbf16ba98d68307fb84085d9459fbe6 changes only ReferenceTake.swift,
ReferenceAuthoringView.swift and MIDIUserMixerGainTests.swift. Reasons now follow
actual separate-control coverage and combined muted motion; an unobserved other
control remains explicit even if a known closure already mutes the output.
Restored snapshots use a read-only presentationReasons getter, preserving stored
JSON and source evidence. Motion geometry, decoder thresholds, audio, schemas,
calibration and the verified Store signing contract are unchanged.

Verification: focused 132 named XCTest executions passed with zero
failures/skips. Required scripts/build.sh all PASS: 9,166 XCTest
passed, 124 skipped, 0 failed;
1,064 Swift Testing and 122 Python passed.
Each of the four new regressions ran twice. iOS, full macOS Release, CXLRelease
and watchOS builds PASS. Process receipts prove child reaping and no survivors.
The isolated verifier was aligned by normal checkout to the source commit after
proving every frozen candidate blob identical; no source was changed after tests.

Existing Developer-ID overlay build and Store/local functional payload parity
PASS. Runtime/data/resources are exact; signature, UUID and explicitly classified
debug-root paths account for nonfunctional differences. Signature, team,
entitlements, Hardened Runtime and timestamp verified. Gatekeeper accepted under the preexisting security-disabled override; policy was not changed and this is not notarization or normal-policy acceptance proof.
Installed side-by-side:
/Users/karlwatson/Applications/SL Capture fader review 20261003.app
Previous apps and Store products remain unchanged; user-data metadata was
unchanged during installation. New app launch/visual acceptance is NOT RUN;
do not interrupt the running capture app. Karl can save/quit it and open this
update when convenient. No additional hardware recording is required solely
for the review-warning change.

The screenshot's grey motion regions at 3.645674-3.769341s and
9.981029-11.474561s are separate retained decoder/normalization uncertainty.
Whether Karl paused/slowed there remains unconfirmed. Do not invent holds,
remove those gaps, or tie physical notation to AHH audio playback. This remains
an open observation rather than a demonstrated decoder defect.

Correction to the in-progress numeric note: generic notation endpoint differences
are reproduced exactly by the existing boundedSnapshot interpolation formula,
not JSON serialization. Thirteen derived endpoint values differ from original
source, maximum absolute difference 5.551115123125783e-17. Raw and source-bound
evidence remains exact; no tolerance or exporter change was introduced.

Evidence and all new build output: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-03/fader-review-warning
Hardware report: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-03/fader-start-hardware-A7F4D464/REPORT.md
All destinations were checked outside iCloud. Historical evidence and canonical
checkout location are preserved. Unrelated dirty/untracked source and workflow
history remain unstaged. Commit/push authorized by Karl; publication is limited
to codex/cxl-fader-checkpoint-20261003, with remote main unchanged. Read
publication-result.json for the final independently verified remote SHA.

- [x] Accept the recorded startup fader behavior and operator confirmation.
- [x] Repair and verify stale fader warnings while preserving historical snapshots.
- [x] Build, sign, compare and install the corrected local CXL app side-by-side.
- [ ] Open the new app when convenient; launch/visual acceptance remains NOT RUN.
- [ ] Clarify continuous movement versus pause in the grey motion interval.

### 2026-10-03 — Dense muted trace rendering repaired and verified

Root cause: ScratchMotionRenderer stroked each tiny canonical segment separately.
Overlapping translucent round caps compounded intended 45% muted opacity to
99.6% brightness, and each segment restarted the dash pattern. Prior semantic
state/style checks missed the composited appearance. The recorded fader states
and earlier A7F4D464 startup/audio acceptance remain valid.

Selected bounded task: keep muted platter motion visibly dim when either fader
closes. Source commit 35bc27f3b9c7caae575a78931871f917fcf9b262 changes only
ScratchLab/Models/ScratchMotionRenderer.swift,
ScratchLabDesktopTests/ScratchNotationPanelTests.swift and
ScratchLabDesktopTests/DemoTimingFoundationTests.swift. The shared renderer now
strokes compatible canonical segments together, retaining every vertex and
lifting the pen at exact time/position discontinuities. It does not bridge gaps
or loop wraps. Evidence, width and color changes remain separate; legacy strokes
retain independent drawing. The optional glow follows canonical mute opacity.
No audio, capture, decoder, raw/canonical data, schema, calibration, resources,
Store signing, or export changes. The same renderer covers shared consumers.

Regression proof: the original production renderer failed the new dense pixel
check in both configurations (sparse0.450980, dense0.996078, open1.0). With the fix,
dense and sparse muted brightness agree within one pixel channel value. The
first focused run exposed a new assertion comparing Path-converted coordinates
with model Doubles. It was corrected to compare exact before/after drawing Path
endpoints; no tolerance or geometry weakening was introduced. The initial
failing runs and before/after ImageRenderer attachments are retained. Additional
checks cover either control, both closed, missing-control evidence, every line,
pen-up at gaps/wraps, direction colors and legacy drawing. Synthetic images are
software evidence, not a physical capture.

The first full gate stopped on an old renderer source-wiring assertion requiring
the previous per-segment loop spelling. Its receipt remains in full-gate/.
That assertion now verifies batched-renderer wiring and actual hidden legacy
padding versus visible canonical hold paths. Existing semantic checks remain.
The corrected full gate receipts are under verification-2/.

Verification: focused 98 XCTest executions and
14 Swift Testing executions PASS, zero failures or skips. Required scripts/build.sh all PASS: 9,174 XCTest passed,
124 skipped, 0 failed;
1,064 Swift Testing and 122 Python passed.
All four new regressions ran twice. iOS, full macOS Release, CXLRelease and
watchOS builds PASS. All child processes reaped with no survivors. Frozen source
hashes equal the commit; the verifier was aligned by a normal non-forced checkout.

Existing local Developer-ID overlay build PASS; only the expected five signing
settings differ from the Store contract. Store/local functional payload comparison
PASS for both architectures: runtime/data/resources exact; signing, build UUID
and 158 explicitly classified debug-root path differences per architecture.
Signature, team, entitlements, Hardened Runtime and timestamp verified.
Gatekeeper accepted under the preexisting security-disabled override; policy was not changed and this is not notarization or normal-policy acceptance proof.
Installed side-by-side: /Users/karlwatson/Applications/SL Capture muted trace 20261003.app
Previous apps and Store products unchanged; user-data metadata unchanged during
installation. New installed app launch/visual acceptance remains NOT RUN.

Next operator action: save/quit the current app, open the muted-trace update and
use Saved drafts > Open for Review on the existing finalized take. Muted portions of the main platter trace should
now be visibly dim/dashed while separate control lanes remain visible. No new
hardware recording is needed solely to verify this drawing correction. Preserve
current running capture state; do not launch a competing capture instance.
The separate grey MOTION UNKNOWN observation remains unresolved and unchanged.

Evidence: /Users/karlwatson/ScratchLab-Local-Evidence/2026-10-03/muted-trace-rendering
Read full-verification-summary.json, local-acceptance/install-receipt.json and
publication-result.json for exact receipts and the independently verified remote
commit. Publication is authorized on codex/cxl-fader-checkpoint-20261003; remote
main is unchanged. New evidence/build output is local outside iCloud. Historical
evidence, canonical checkout location, unrelated dirty/untracked files and older
workflow entries are preserved. Only these new checkpoint entries are staged.

- [x] Reproduce dense muted trace brightness failure with actual renderer pixels.
- [x] Repair shared rendering and verify geometry, either-fader gating and legacy behavior.
- [x] Complete focused/full software gates and signed side-by-side installation.
- [ ] Open the installed update and visually check the existing take; no new recording required.
