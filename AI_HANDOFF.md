# AI Handoff

## 2026-08-31 (latest) - stale Review take and missing upfader notation fixed; physical retest pending

- Physical session `8ad16543-5165-41e8-993d-1d00c1ce5fd8` proved capture data was not lost. Take 1 persisted 33 movement events and 8,911 raw CC6 events; take 2 persisted 71 movement events, 14,565 mixer MIDI events, 561 mapped crossfader CC8 events, and 18 derived fader events (4 cuts). Review was visibly showing `Take 1` while `take-002` was the newest completed take.
- Take 2 also persisted 125 RANE CC28 channel-1 events spanning 0...127, but every event had `mappedControl: nil` despite the complete 11-control `midi_1737453891.json` mapping existing before both takes. Root cause: the CoreMIDI packet loop persisted only the legacy crossfader classification; shared notation derivation also filtered only `crossfader`, so upfader evidence could never reach Review notation.
- Source fix: entering Review now rescans completed captures before loading metadata; the CoreMIDI path persists exact active-mapping identities for `crossfader`, `leftUpfader`, and `rightUpfader`; shared fader derivation processes each mapped control independently and labels its events with the truthful control identity. Unmapped MIDI remains ignored. Renderer/audio scheduling, platter projection, RANE routing, and cue tolerance are unchanged.
- Environment finding: two ScratchLab processes were running simultaneously: current DerivedData product PID 39593 and stale `build/CodexProducts-ios-save-tests` PID 40234. This can leave one window showing another process's stale in-memory take. Both must be closed before launching only the validated product.
- Verification: two new focused regressions passed 2/2 twice; surrounding latest-take, fader-derivation, and all 40 `MIDIUserMixerGainTests` passed 49/49 in each configured repetition; macOS test build, isolated iOS Simulator with embedded Watch validation, and standalone Watch Simulator builds succeeded; `git diff --check` passed before record updates.
- Existing sidecars were inspected read-only and not repaired. Physical retest remains required: record one fresh take, open Review and confirm it names that newest take, platter notation is visible, and crossfader plus right-upfader on/off cuts appear under their own identities.

## 2026-08-31 (latest) - Standalone-only audio and export reliability validated; physical RC remains

- Karl explicitly retired the `External Serato` product mode because the ownership choice confused users. This supersedes earlier workflow instructions that required External Serato as the safe default or as a physical RC case.
- Source now has one `ScratchAudioOwnershipMode` case, `scratchLabStandalone`, and defaults to local AHHH playback. Legacy persisted `externalSerato` values migrate to standalone on load. iOS and macOS ownership selectors and Serato-specific copy were removed; Load/Test AHHH actions remain available through their existing hardware gates.
- Renderer/audio scheduling, RANE channel routing, signed/unwrapped `PlatterSamplePositionProjection`, and the 5 ms cue tolerance were not changed.
- Export reliability fixes in the pending batch are now validated: cross-session Review/export uses persisted sidecar identity unless mutable UI configuration matches the recorded session; AVFoundation's documented successful-stop marker no longer creates a false failed take; multichannel RANE audio is read as deinterleaved Float32 and projected from the audible pair into a playable stereo export; missing source audio still fails closed; export progress remains visible.
- Focused evidence passed twice for canonical export parity, recorded-BPM subset export, mono-to-stereo duplication, 14-channel RANE audible-pair projection, and missing-audio rejection. Capture fixtures passed 47/47. The final configured gate ran 377 XCTest cases per repetition and reproduced exactly the established 11 failing invocations / 9 unique names, with no new export/ownership failure; Swift Testing passed 366/366 in each repetition.
- Isolated `ScratchLabDesktop` macOS, `ScratchLab` iOS Simulator (including embedded Watch validation), and `ScratchLabWatch` Watch Simulator builds all succeeded. The earlier iOS/Watch attempt failed only because concurrent Xcode processes contended for the shared build database; sequential reruns succeeded.
- Diff accounting: local `HEAD` is nine commits ahead of `origin/feature/ios-capture-camera-ux`. The full branch delta is 73 files, 37,527 insertions, and 14,676 deletions; the actual unstaged worktree before this change was 28 files, 8,654 insertions, and 1,812 deletions. Do not reset or squash this history blindly.
- Physical RC is still required on the exact candidate: prove standalone local AHHH through the RANE; cyan playhead audible alignment through `BEFORE START` and `PAST END` without wrapping; compact-landscape Capture/Review reachability, scrolling, and fixed actions; Watch relay association; and successful end-to-end export. The retired External Serato switch/silence cases are no longer release requirements.
- Publication: Karl explicitly authorized the destination after review; the validated 27-file batch was committed as `b9afd4671afd263e7b3409075b6a34320f88b91a` (`Finalize capture reliability and standalone audio`) and pushed to `origin/feature/ios-capture-camera-ux`. A documentation-only closure commit follows this record. Physical RC remains open and is not implied by publication.

## 2026-08-31 (latest) — RANE audio captured; Review/export crossed session identities

- Running app remains the stale 2026-08-29 binary at `build/CodexProducts-ios-save-tests/Debug/ScratchLab.app`, not the 2026-08-31 rebuilt product.
- Live Review reproduced an identity split: primary evidence showed 36 strokes from newest session `72b7923d-7086-46d8-b1a9-b7c05af7d75d`, while stale review status named session `82223c61-938e-421e-9f5f-ae29d47106c8` take 2. Export failed with `ScratchLab could not validate the canonical export artifacts.`
- Both new takes truthfully captured `Rane ONE MKII` as 14-channel 48 kHz audio. Strong program signal exists on channels 13/14; the hardware channel/master LEDs not lighting did not mean capture silence. ScratchLab does not drive those hardware meter LEDs.
- Minimal source fix in `MacAnalyzerView.swift`: mutable `routineSessionSetup.config` and session name are supplied to export/upload only when their session ID matches `lastRoutineRecordingSessionID`; otherwise the builder must derive truth from the persisted sidecar. Review reload now clears stale message/decision state before loading the current sidecar.
- Previously pending stereo projection and export-progress changes remain in `SessionExportCoordinator.swift`, `MacAnalyzerView.swift`, and focused tests. All current edits are unverified; no tests/build were run after Karl had not yet authorized validation.

## 2026-08-31 (latest) — attached FTR ZIP proves built-in mic capture, not isolated RANE scratch

- Inspected `/Users/karlwatson/Downloads/session_2026_08_31_ftr_baby_scratch_95_bpm.zip` as data only. Session `82223c61-938e-421e-9f5f-ae29d47106c8`, take `take-001` is a failed isolated-scratch RC capture.
- Manifest truth: `audioDeviceName: MacBook Pro Microphone`, `audioDeviceUniqueID: BuiltInMicrophoneDevice`. `scratch_only.wav` is mono 44.1 kHz microphone audio, so TV/room sound is expected and the file is not isolated Serato/RANE program audio.
- Beat truth: `captureMode: timed_click`, `beatEnabled: true`, `beatEngineMode: boom_bap_trainer`. The archive intentionally contains `beat_only.wav` and `scratch_with_beat.wav`; export metadata still says `exportMixMode: scratch_only`. The isolated file to inspect is `scratch_only.wav`, but in this take it is still the wrong microphone source.
- Required retest configuration: choose `Rane ONE MKII` as Capture audio input, use External Serato ownership, use no-click/beat-disabled capture for isolated scratch, and verify the input meter responds to platter audio but not TV/room sound before recording.
- Treat this as a capture preflight/UI safety failure. Do not relabel or repair this archive as isolated scratch.
- Pending unverified production edits from the immediately preceding investigation project multichannel RANE exports to playable stereo and show export progress. They have not been built or tested because permission was requested but not granted yet.

## 2026-08-31 (latest) — physical relay/UI retest failed; take data intact and backend-exportable

- New physical Mac-led take: session `af2f4238-228b-4847-b7dc-ac9ec3c4f537`, `take-001`. Watch stopped and notation rendered live, but the user reported no notation in Review and could not export through the UI.
- Persisted truth is healthy: `recordingStatus: completed`; MOV 65,527,963 bytes; WAV 55,771,136 bytes; `detectedNotation` contains 70 final record-movement events and 4 audio events. The movement funnel reports 70 fused/trusted/final events with no trust drops.
- The Watch leg failed: `watchSyncState: timedOut`, `linkedMotionFileName: null`, and no new relayed Watch artifact was stored. Watch stopping does not prove linked motion returned.
- Exact artifact test passed twice, 1/1 each run: all 70 events decode, gesture-relative Review presentation is non-empty, export validation returns no issue, package preparation succeeds for the correct session/take, and ZIP archive creation succeeds. Result: `build/DerivedData-latest-physical-take/Logs/Test/Test-ScratchLabDesktop-2026.08.31_04-19-50-+1200.xcresult`. The temporary artifact-specific test was removed afterward.
- Review's raw captured chart is currently inside the collapsed `Technical evidence & diagnostics` disclosure, but the primary Target/My Performance card should still represent saved presentation events. User-visible blank notation therefore remains an open UI failure, not missing data.
- UI export failure remains open because the exact on-screen status/validation text was not captured. Backend export is proven good; do not mutate or recover this sidecar. Re-scan/relaunch, reopen Review, expand Technical evidence, and retry `Save ZIP...`; capture the exact status if the UI still fails.
- No new production code was changed for this retest. Nothing staged, committed, or pushed.

## 2026-08-31 (latest) — macOS normal-stop export defect fixed; recovered take exports; Watch relay retest open

- Physical macOS capture exposed a reproducible release defect: `AVCaptureMovieFileOutput` returned a non-nil `Recording Stopped` completion error carrying `AVErrorRecordingSuccessfullyFinishedKey == true`, but `MacCaptureEngine` treated every non-nil completion error as fatal. The sidecar was therefore persisted with `recordingStatus: failed`, and export correctly refused it.
- Production fix is intentionally narrow: `MacCaptureEngine.routineCaptureFailureDescription(for:)` accepts only the documented AVFoundation successful-finish marker as success. Every AVFoundation error without that marker, and every non-AVFoundation error even if it spoofs the key, remains fail-closed.
- Permanent regression coverage in `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift` passed twice: 3/3 tests, 0 failures per run. The selected macOS test action built successfully.
- Affected take `0c813395-28b1-42d6-9061-e2399c312a1f` / `take-001` was validated before recovery: MOV 99.696563 s / 291,314,513 bytes; WAV 100.693333 s / 270,667,776 bytes; duration delta 0.996770 s. Original sidecar is backed up as `0c813395-28b1-42d6-9061-e2399c312a1f_take001_routine.json.pre-stop-recovery.bak`.
- Recovery changed only `recordingStatus` to `completed`, cleared `errorDescription`, and appended audit event `2DAA3C48-907A-4E32-B5A9-0F6C5C794A83`; the original `recording_failed` audit entry remains. The recovered take then passed actual package preparation and archive creation twice, exporting 4,833,280 scratch-audio frames each time.
- The reported validation warnings are advisory, not export blockers: median peak 0.01 is below 0.10, and onset-spacing stdev 6.415 s exceeds 0.6 x mean gap 3.828 s. `Saved review notes.` confirms notes persistence only.
- Watch behavior is not yet a reproduced code defect. This take recorded `watchSyncState: unavailable`, no `linkedMotionFileName`, and no relayed Watch artifact. For the next short physical run, keep ScratchLab open on iPhone with relay connected and Watch reachable, start only from macOS, confirm Watch acknowledgment, stop only from macOS, confirm Watch stops automatically, confirm linked motion returns, then export.
- Physical RC matrix remains incomplete. A7/A8/A9 and the previously open hardware checks remain open. Nothing staged, committed, or pushed.

## 2026-08-30 (latest) — macOS upfaders + hot cues working; A8/A9 open

Karl: "11 controls mapped now, upfaders and pads working". Fixed by **Refresh MIDI + explicitly selecting "Rane ONE MKII"** — the 11-control mapping was already correct on disk; the app simply had `currentMIDIDeviceMapping` nil, so `evaluateUserMixerGainForCC` bailed before any upfader/hot-cue dispatch. Crossfader kept working via the separate legacy `crossfaderCCMapping` path.

**If this recurs: re-select the MIDI source first.** It is a load/selection problem, not a mapping problem.

### New open anomalies
- **A8** — `MIDILearnedMappingStore.fileURL(for:)` accepts an empty device identifier, so a "Not Connected" session writes a loadable mapping file literally named `.json` containing crossfader only. Found on disk during diagnosis; matches Karl's "only crossfader shows" symptom exactly. Not fixed.
- **A9** — `MIDILearnedMappingStore.save` uses `try?` on both encode and write, so a failed save reports success to the caller. Not the cause here, but it hides real failures. Not fixed.
- Mapping stores exist in **both** the sandboxed container and plain `~/Library/Application Support` — two builds with different sandbox states. Future confusion risk.
- `installVerifiedRaneOneMKIIMapping` pushes resolved curves for crossfader and rightUpfader but **not** leftUpfader.

### A7 status — likely explained, NOT yet confirmed
A7 (RANE not playing AHHH, CH 3/4 silent) was reported when the macOS build had **no Audio-ownership picker at all** (it is uncommitted work, absent from `HEAD` — `git log -S` finds no commit adding it). With no control and `defaultMode = .externalSerato` blocking every local AHHH route, silence was expected behaviour. The picker now renders after relaunch. **Karl has not yet confirmed AHHH is audible**, so A7 stays open.

## 2026-08-30 (later) — macOS ring fills camera view; RANE AHHH silent (A7, OPEN)

**Branch** `feature/ios-capture-camera-ux`, **HEAD `7761c09f`** — still nothing committed, staged, or pushed.

### Done since the previous entry
- **macOS notation ring fills the camera view.** `CameraNotationOverlayCalibration.platterRadius` default 0.35 -> 0.5 (property and `reset()`). No clamp/slider change needed — `radiusRange` already allowed 0.5. Three tests updated from 0.35 to 0.5. Failing set for `CameraNotationOverlayTests` is byte-for-byte identical before and after (same 9 bundle-resource cases), so for that class the failures are now **proven** pre-existing.
- **Karl must press Reset** in the calibration controls to see it — his persisted `scratchlab.mac.cameraOverlay.platterRadius` overrides the new default.
- macOS app rebuilt 20:12; earlier rebuild 16:36 carries the crossfader fix.

### A7 (NEW, OPEN, HIGHEST PRIORITY) — RANE not playing AHHH
Regression against Case 3, which passed earlier the same day. Karl's 14 ch @ 48 kHz analysis: **CH 3/4 silent** (the established AHHH right-deck route); only CH 13/14 carries signal (R -4.8 dBFS RMS / -0.0 peak, L flagged `dcHeavy` with DC **-0.14937**); 7/8 through 11/12 are true `-inf`; tool reported "no pair looks like program audio".

**Check these before assuming a code defect, in this order:**
1. **Which app** — iOS or macOS? Karl had just relaunched the rebuilt macOS app.
2. **`ScratchAudioOwnershipMode`** — if it reads External Serato, silent AHHH is *correct by design*; that mode blocks and unloads every local AHHH route. A relaunch starting on the safe default would fully explain the symptom.
3. **Is the AHHH sample loaded?** (`"Standalone audio enabled — load AHHH to arm the platter."`)
4. Is the measurement input-side or output-side?
5. Separately explain the **DC offset of -0.14937** on CH 13 L — anomalous regardless of AHHH.

This session's changes are **not a plausible cause** (reasoning, not proof): the notation derivation and calibration default touch no audio path, and the one edit near audio — `iOSMIDIManager` `.upfader` — was re-inspected after the report, with `setRightUpfaderGain(...)` byte-for-byte unchanged and the new capture block sitting strictly before it.

### Still outstanding
- **iOS hardware judgement never given**: build 2760 is on `K`; Karl has not reported whether cut ticks now read correctly, and specifically **whether any tick appears where he did not cut** (the false-positive risk from widening the gate).
- **macOS crossfader confirmation**: fresh take should show ~44 fader events / ~31 drawn (was 0).
- **Upfader capture confirmation**: next iOS export should carry CC28 with `mappedControl: "leftUpfader"/"rightUpfader"`.
- **Physical RC matrix INCOMPLETE**: Case 1 PASS, Case 2 NOT TESTED, Case 3 PASS (now contradicted by A7 — re-run it), Cases 4-8 NOT OBSERVED.
- Requested, not started: macOS AHHH sample playhead display (Figma first), upfader notation lane (architect slice).
- Anomalies A1-A4 unchanged and unfixed.

### Files changed this session (all uncommitted)
`ScratchLab/Models/CaptureCore.swift`, `ScratchLab/MIDI/iOSMIDIManager.swift`, `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`, `ScratchLabDesktop/Models/CameraNotationOverlayCalibration.swift`, `ScratchLabDesktopTests/CameraNotationOverlayTests.swift`. The other 24 pre-existing dirty files and the untracked `CalibrationCameraOverlayTests.swift.plist` were not touched.

## 2026-08-30 — RC smoke halted at Case 4; crossfader notation fixed on both platforms

**Branch** `feature/ios-capture-camera-ux`. **HEAD `7761c09f`** — nothing committed, staged, or pushed this session. Local is 9 commits ahead of `origin/feature/ios-capture-camera-ux` (`9b2b445f`).

### Status: physical RC matrix is INCOMPLETE — do not mark it complete
- **Case 1 PASS** (External Serato selected on entry, no local AHHH through the RANE). Caveat recorded: confirms *selected on entry*, not *first-run default*.
- **Case 2 NOT TESTED.** Serato does not run on iOS; both exports were recorded in `ScratchLab AHHH` mode. Requires Serato on a Mac via the RANE's second USB port, ownership held on External Serato for the whole take.
- **Case 3 PASS** by control authority (right upfader controls AHHH, left does nothing, crossfader cuts it, smooth). **No channel meter LEDs lit at all** — meters recorded as unavailable evidence, not as pass or fail; whether they light for any source was never tested.
- **Cases 4-8 NOT OBSERVED.** Case 4 was queued and never run.

### Work completed instead (Karl redirected: "stop the matrix and fix the crossfader notation bug")
Three defects found and fixed, all evidence-backed from Karl's own exports. Full detail in `DEV_LOG.md`.
1. **Crossfader gestures never became notation.** `deriveDetectedNotationFaderEvents` gated primitives on adjacent-sample delta (0.10) while the RANE streams CC8 at ~800 Hz — measured max adjacent delta **0.0236**, so it always returned `[]`. Now segments monotonic runs like `decodePlatterCore`. Hardware-confirmed **0 -> 78** fader events.
2. **Detected but invisible.** Renderer draws only cut-family kinds, so 58 of 78 were `.unknown` and drew nothing. Cut gate widened to 0.25/0.25 on Karl's approval, from measured evidence (39 closes, median 0.110 s / 0.409 travel). **19 -> 31 of 39** now render.
3. **Upfader evidence never captured.** No CC28 in any iOS export. Now recorded as raw evidence only.

### Immediate next actions
1. **Relaunch the macOS app** — rebuilt 16:36 with the fix. Karl's 16:30 macOS take predates it and shows the old signature (1599 crossfader events, 0 fader events, max adjacent delta 0.0236). A fresh take should yield ~44 events / ~31 drawn.
2. **Confirm iOS on hardware** — build sequence **2760** is on `K` with all three changes. Karl has not yet reported whether the ticks read correctly, and specifically whether any tick appears where he did NOT cut (the false-positive risk from widening the gate).
3. **Confirm upfader capture** — next iOS export should carry CC28 with `mappedControl: "leftUpfader"/"rightUpfader"`.
4. **Resume the RC matrix at Case 4**, then 5-8.

### Requested but not started (Karl, this session)
- **macOS notation should fill the entire camera view.** Layout work, not yet scoped.
- **macOS has no AHHH sample playhead display like iOS.** New surface; Karl's steer is Figma first, then wire code. iOS equivalent is `PlatterSamplePositionProjection` with BEFORE START / PAST END (Cases 5-6, never run).
- **Upfader notation lane.** "upfader" exists nowhere in `CaptureCore.swift`, `ScratchMotionRenderer.swift`, `ScratchMotionLane.swift`. Spans capture + canonical model + renderer — a proper architect slice.

### Open anomalies (banked, none fixed)
- **A1** periodic 8 s pop from the iPhone speaker, idle on Practice. Continues backgrounded, **stops on force-quit** — ScratchLab owns it. No 8 s timer exists in the app. Absent from captured audio. Root cause not investigated.
- **A2** `audioEvents: []` on iOS across both takes despite -0.2 dBFS peaks. `iOSMIDIManager.detectedNotationSnapshot` hardcodes `audioEvents: []`. macOS produces them, so this is **iOS-specific**. Sits on the path PROFILE.md calls the reliable one.
- **A3** `SessionExportCoordinator.swift:4272` hardcodes `audioSource: "serato"` regardless of ownership — mislabelled dataset provenance.
- **A4** `CaptureCore.swift:14-16` doc comment wrong: capture is an `inputNode` tap, not the output bus, and is not silent under Serato ownership.

### Verification caveat carried forward
Full bundle via `xcrun xctest`: 3180 tests, 208 failures / 92 cases, 78 of them `XCTUnwrap`/bundle-resource failures from running without the app host. None on the fader path. **No baseline run was captured before editing**, so they are "unrelated, almost certainly pre-existing" — not proven so.

## 2026-08-30 — Physical RC smoke command reached iPhone K build/install/launch twice

Unlock confirmed; `./scripts/run-on-phone.sh 1F80398A-96C8-537A-B0EE-821E186918B9` now reaches build/install/launch on `K`.

- Retry evidence after Karl confirmed the phone was unlocked: the same command exited `0` in about 8 seconds, reported `** BUILD SUCCEEDED **`, installed `com.machelpnz.scratchlab` at `file:///private/var/containers/Bundle/Application/EC170B5E-8286-466B-82C3-49C437724A1D/ScratchLab.app/` with install database UUID `91F773FB-990B-4254-A7D6-CDD841AE068C` and sequence `2744`, then reported `Launched application with com.machelpnz.scratchlab bundle identifier.`
- Scope of the retry: second pass of the build/install/launch gate only. It does not establish any audible RANE, signed/unwrapped playhead, compact-landscape reachability/scrolling, or fixed Review action result.

- Pass/Fail: **PASS at script gate** (build/install/launch), with all required feature checks still pending by design.
- Evidence:
  - `Using device: 1F80398A-96C8-537A-B0EE-821E186918B9`
  - `Build settings from command line:`
  - `SDKROOT = iphoneos27.0`
  - `** BUILD SUCCEEDED **`
  - `Installing com.machelpnz.scratchlab...`
  - `Launched application with com.machelpnz.scratchlab bundle identifier.`
  - `Done.`
- Remaining required checks still not executed (manual):
  - External Serato produces no local AHHH
  - Standalone loads/plays local AHHH
  - External re-select silences an already armed sample
  - Playhead remains aligned across `BEFORE START` / `PAST END` without wrapping
  - Capture + Review fixed landscape action reachability and scrolling behavior
- Next action: perform the operator RC checks on-device with RANE connected and log concrete pass/fail evidence for each item.

## 2026-08-30 — RC smoke attempt blocked by device lock on iPhone K

Execution attempt made with the user-specified iPhone `K` UUID `1F80398A-96C8-537A-B0EE-821E186918B9`.

- Pass/Fail: **FAILED at unlock gate** during smoke-preparation.
- Evidence:
  - `./scripts/run-on-phone.sh 1F80398A-96C8-537A-B0EE-821E186918B9` output:
    - `Using device: 1F80398A-96C8-537A-B0EE-821E186918B9`
    - `Checking lock state...`
    - `Phone is locked. Unlock it and rerun.`
  - `xcrun devicectl device info lockState --device 1F80398A-96C8-537A-B0EE-821E186918B9` output:
    - `passcodeRequired: true`
- Result: smoke could not proceed to build install, app launch, or manual checks because the phone is locked.
- Remaining required checks not run (all blocked): External Serato no-local AHHH, Standalone local AHHH, External→Standalone transition silence, signed cyan playhead with `BEFORE START`/`PAST END`, landscape Capture/Review scroll/fixed action behavior.
- Next action: unlock iPhone `K` and rerun the same smoke flow before ARC/ASC physical-release signoff.

## 2026-08-30 — Capture-integrity Slice H COMPLETE (uncommitted; current)

Started from committed HEAD `7761c09f43` on `feature/ios-capture-camera-ux`. Nothing was reset, amended, staged, committed, or pushed. Existing dirty work was preserved. The protected `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and `CalibrationCameraOverlayTests.swift.plist` remain byte-for-byte unchanged from the recorded task-start hashes.

**Root cause.** Audio/render semantics already kept a signed, unwrapped playhead and correctly distinguished travel before cue and beyond sample end, but the classification was trapped in iOS engine code and guarded only by a source-string test. On iPhone landscape, Review's detail stack could exceed its finite height while take actions must remain reachable, Capture treated the leading safe-area inset as both edges, and the toolbar needed a compact form that never hides Export. External Serato also inherited Standalone's `LOAD AHHH` empty-waveform instruction.

**Figma and implementation.** In Figma file `AgrnQXwRvkAKlORTQ2U25z`, `SamplePositionWaveform` set `457:3817` now includes reviewed Before Start `493:262` and Past End `493:277` variants using the existing warning token and explicit signed-time/boundary/fill semantics. Production adds pure shared `PlatterSamplePositionProjection`; the iOS engine delegates its unchanged 5 ms-tolerant classification to it, and renderer/audio scheduling remain untouched. External mode now says Serato owns scratch audio. Capture uses separate horizontal safe-area insets and `ViewThatFits` while retaining every action; Review gives only the detail column a finite-height scroller, keeping media and Keep / Keep and Next / Retry / Discard fixed.

**Files changed for Slice H.** `ScratchLab/Models/ScratchSoundBank/ScratchPlatterTracker.swift`; `ScratchLab/Audio/iOS/IOScratchPlaybackEngine.swift`; `ScratchLab/Views/ScratchMotionLane.swift`; `ScratchLab/Views/CompanionCameraView.swift`; `ScratchLabDesktopTests/ScratchPlatterTrackerTests.swift`; `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`; Figma file `AgrnQXwRvkAKlORTQ2U25z`; and the workflow records. Other hunks in overlapping files predate this slice and were preserved.

**Verification.** Focused tests passed 26/26 in both configured executions; relevant waveform/notation/review/motion regressions passed 60/60 in both. Isolated iOS Simulator Debug with embedded Watch and explicit macOS Debug builds succeeded. Fixtures passed 47/47. The full configured gate ran 3,545 tests across two configurations and retained exactly the established 11 failing invocations across 9 unique names, with no Slice H failure; 366/366 Swift Testing cases passed. `git diff --check` passed before the record update; protected hashes were unchanged.

**Next release work.** Three release-critical batches remain before App Store Connect readiness: (1) one physical iPhone/RANE smoke covering Slice G ownership switching plus Slice H landscape/actions/signed playhead, (2) the final cross-platform release-candidate audit and manual smoke/screenshots, and (3) archive/distribution validation for that exact candidate. The unchecked capture-movement trace item is DEBUG-only evidence collection and is not an ASC blocker unless Karl elevates it. Do not reopen Slice H without new physical/test evidence.

## 2026-08-30 — Capture-integrity Slice G COMPLETE (uncommitted; current)

Started from committed HEAD `7761c09f43` on `feature/ios-capture-camera-ux`. Nothing was reset, amended, staged, committed, or pushed. Existing dirty work was preserved. The protected `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and `CalibrationCameraOverlayTests.swift.plist` remain byte-for-byte unchanged from the recorded task-start hashes.

**Root cause.** ScratchLab could locally arm or play AHHH from manual controls, learned hot cues, DVS motion, and DEBUG fallbacks without declaring whether Serato or ScratchLab owned deck audio. That made double-audio possible and allowed UI/MIDI state to imply local playback even when the intended product role was an external-Serato companion.

**Implemented.** Shared `ScratchAudioOwnershipMode` persists one cross-platform choice and defaults safely to `.externalSerato`. iOS exposes it in Practice Controller Setup, Capture Hardware Setup, and Advanced MIDI; macOS exposes it in Advanced mapping. External mode unloads any armed local sample and blocks manual load/preview, learned-hot-cue load, DVS auto-load/drive, and temporary DEBUG triggers. Standalone mode preserves local `dvs_ahhh` playback. The iOS dispatcher no longer reports a suppressed hot cue as played, and mapping/status/waveform/accessibility copy states the real owner. Capture remains active in both modes so required export audio is a truthful ScratchLab bus WAV (silent when no local ScratchLab audio is rendered), rather than a missing or fabricated artifact. The macOS CoreMIDI/DVS gate uses lock-backed state and does not touch UserDefaults or SwiftUI observation at MIDI rate.

**Files changed for Slice G.** `ScratchLab/Models/CaptureCore.swift`; `ScratchLab/Audio/iOS/IOScratchPlaybackEngine.swift`; `ScratchLab/MIDI/iOSMIDIManager.swift`; `ScratchLab/MIDI/iOSMIDILearnCoordinator.swift`; `ScratchLab/Views/PracticeModeView.swift`; `ScratchLab/Views/CompanionCameraView.swift`; `ScratchLab/Views/MainMenuView.swift`; `ScratchLab/Views/ScratchMotionLane.swift`; `ScratchLabDesktop/Services/MacCaptureEngine.swift`; `ScratchLabDesktop/Views/MacAnalyzerView.swift`; `ScratchLabDesktopTests/PlatterTestSampleLoadTests.swift`; `ScratchLabDesktopTests/MIDILearnEngineTests.swift`; `ScratchLabDesktopTests/MIDILearnHangFixTests.swift`; `ScratchLabDesktopTests/TimecodeBridgeContinuityFixTests.swift`; and the four workflow records. Other hunks in overlapping files predate this slice and were preserved.

**Verification.** The final ownership/MIDI/DVS set executed 48 tests with zero failures twice after the last code change. The configured broad gate previously completed both passes with exactly the established 11 failing invocations across 9 unique names and no Slice G failure. Isolated generic iOS device Debug with embedded Watch and macOS Debug/test builds succeeded. Capture fixtures passed 47/47. `git diff --check` passed. Physical RANE/iOS smoke remains prudent before release: External Serato must produce no local AHHH, Standalone must load/play it, and changing back to External must silence an already armed sample.

**Next task.** The first unchecked implementation-ready item is **Slice H: iPhone landscape layout, waveform playhead, and BEFORE START / PAST END sign correctness**. Do not reopen Slice G or combine it with the later capture-movement evidence task.

## 2026-08-30 — Production iOS saved-take notation/playback/detail COMPLETE (uncommitted; current)

Started from committed HEAD `7761c09f43` on `feature/ios-capture-camera-ux`. Nothing was reset, amended, committed, staged, or pushed. The pre-existing dirty tree was preserved. Protected `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and `CalibrationCameraOverlayTests.swift.plist` retain their recorded SHA-256 values and were not altered.

**Root cause.** iOS had no production route to reopen a kept take. `TakeReviewView` only showed a thumbnail and text, `Take Detail` was macOS-only, and the two iOS saved-notation views were DEBUG-only. The durable Slice F ledger already owned the authoritative active session and real artifact references, so the smallest correct implementation was to present that ledger directly rather than introduce a second saved-session store.

**Implemented.** `GuidedCaptureSavedTakeDetail.load` resolves the kept take through the current `CaptureContainerLocator`, requires non-empty regular media and sidecar files, decodes the real sidecar, and validates session ID, take ID, take number, sidecar/media filename association, and completed status. It derives presentation strokes only through `CaptureCore.gestureRelativeRecordMovementEventsForPresentation` and the shared presentation-duration helper. Validation errors are explicit and retryable and never remove the take from the ledger.

`CompanionCameraView` now exposes `Review Saved Take(s)` from both Session Setup and Session Complete whenever the active durable ledger session has kept takes. The production sheet lists those takes and opens a detail surface using native `VideoPlayer` with the actual media URL plus the shared `ScratchPhraseChartView` with the saved notation projection. Missing/inconsistent files show a visible Retry action; empty notation says so truthfully; playback pauses when detail disappears. No DEBUG gate, second detector, copied notation algorithm, fabricated playable state, or alternate persistence layer was added.

**Files changed for this task.** `ScratchLab/Models/CaptureCore.swift`, `ScratchLab/Views/CompanionCameraView.swift`, `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`, `TASKS.md`, `DEV_LOG.md`, `AI_HANDOFF.md`, and `AI_HANDOFF/next_prompt.md`. Other hunks in those files predate this task and were preserved.

**Verification.** Three focused deterministic tests cover real media/sidecar loading plus the shared notation projection, missing-media refusal without ledger detachment, and sidecar identity mismatch. They passed in two separate executions. Relevant kept-ledger/export regressions and shared-presentation regressions passed. Isolated macOS `build-for-testing`, generic iOS Simulator Debug, and generic iOS device Debug with embedded Watch succeeded. Fixtures passed 47/47 and `git diff --check` is clean.

**Full-gate note.** The configured Xcode gate was attempted with isolated paths but Xcode 27's sandboxed app-host hung inside Foundation while an existing source-contract test read `CompanionCameraView.swift`; the same runner defect was reproduced with the temporary source-inspection test and that brittle new test was removed. The direct unsandboxed XCTest fallback completed 3,169 tests / 51 skipped with 208 assertions across 92 names, the known non-equivalent missing-resource/timing pattern; it is not a valid comparison to the configured 11-failure / 9-name baseline. No failure referenced `GuidedCaptureSavedTakeDetail` or any of the three new tests. Do not record the direct fallback as baseline drift.

**Next task.** The first unchecked implementation-ready item is **Capture-integrity Slice G: explicit audio-ownership mode (external Serato silent / standalone local AHHH)**. Do not begin Slice H or fold more work into this completed saved-take task.

## 2026-08-30 — Capture-integrity Slice F COMPLETE and PHYSICALLY APPROVED (uncommitted; current)

Started from committed HEAD `7761c09f43`. Nothing was reset, amended, committed, staged, or pushed. `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and the untracked `CalibrationCameraOverlayTests.swift.plist` were not touched. All other pre-existing dirty hunks were preserved. Production files changed: `ScratchLab/Models/CaptureCore.swift` and `ScratchLab/Views/CompanionCameraView.swift`; tests in `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`; plus `DEV_LOG.md`, `TASKS.md`, `AI_HANDOFF.md`, `AI_HANDOFF/next_prompt.md`.

**Slice F is complete and checked in `TASKS.md`.** Karl explicitly approved closure after the physical retry, cancellation, multi-take archive inspection, and his operator-reported subsequent-take export.

**Root cause, as fixed.** The kept-session ledger persisted each take's media/sidecar/audio/Watch location as an absolute `file://` URL embedding the iOS Data-container UUID, which iOS reissues across installs. The captures were intact; the ledger paths were not. The export validators were correct — they were reporting genuinely dead paths.

**What changed.** The four take locations are now `CaptureArtifactReference`: `.containerRelative(root:path:)` for anything ScratchLab owns, `.absolute` only for paths it does not. Resolving one to a `URL` requires a `CaptureContainerLocator`, which is built for the container the app is running in now — so a stored location cannot be consumed without being rebased. JSON keys are unchanged and legacy absolute-URL ledgers still decode.

**Legacy repair is an interpretation, not a search.** `GuidedCaptureLedgerRebase` runs once at load. It locates the container-root segment of a legacy path, requires the remainder to already be a capture directory that artifact kind owns plus a single file name, and proves the single resulting candidate against the recovered sidecar — session ID, take ID, take number, sidecar file name, `mediaFileName`, the audio file's media-sibling basename, and `linkedMotionFileName` for Watch/motion — before accepting it. Notation has no separate reference: it is generated from the sidecar, so proving the sidecar proves it. All four locations of a take move together or none do. Do not replace this with a directory scan or a basename match.

**Refusals are visible and non-destructive.** Path traversal, a doubly-named container root, a location outside the directories its kind owns, an unreadable sidecar, a wrong-session/take/number sidecar, a media/audio/Watch file the sidecar does not name, a genuinely missing file, and two takes resolving onto one file are each refused with a named reason in `lastRebaseReport`. A refusal leaves the ledger byte-identical, keeps every take attached, and lets Export keep reporting the real failure so it stays retryable. The repair never adopts an unkept capture that merely completed. Captures are never moved, renamed, or deleted.

**Fail-closed on write.** Persisting an absolute path inside a current container root is now rejected (`containerOwnedAbsoluteSourceURL`), so the defect cannot be reintroduced. Loading still accepts absolute paths, because a legacy ledger legitimately holds them and must survive to be repaired. Do not "simplify" that asymmetry away. No export validator was weakened and no path or file is fabricated.

**Preserved from the prior turn — do not undo.** Staged BYTES are still compared against the same documents re-encoded through the canonical encoder; `testSubSecondCreatedAtIsPreservedAndStagedMetadataIsCanonicalBytes` fails if that becomes a value comparison or if `createdAt` is floored. `SessionExportValidationReason` / `SessionExportValidationFailure` still name the staged check that fired. Retry/cancel semantics and the fail-closed platter-motion-without-recorded-movement check are unchanged.

**Verification.** 9 new deterministic tests + the 9 existing kept-ledger/export tests passed 18/18 twice via `xcodebuild test-without-building` with per-method `-only-testing:` selectors. Teeth were proved by mutation, not assumed: 8 of the 9 new tests FAILED against a temporary restoration of the pre-fix behaviour, and the traversal test FAILED against a disabled path-safety check. `CaptureRecoveryPhase2CoreTests` 58/58, `ScratchLabNotationAndExportTests` 29/29, `CaptureMotionEvidenceTests` 13/13, `CaptureFinalizationMachineTests` 28/28, `GuidedCaptureReviewStateTests` 10/10, `SessionExportRoundTripTests` 1/1. Isolated generic iOS Simulator Debug and macOS Debug builds plus macOS `build-for-testing` succeeded. Fixtures 47/47. `git diff --check` clean. The full configured gate returned 3,166 tests / 49 skipped / 11 assertion failures across the established 9 unique names, plus 366/366 Swift Testing cases, in both configurations.

**Physical approval.** A signed build made with isolated Xcode paths was installed on iPhone `K` as an upgrade, with no uninstall or container erase. Loading the preserved `b5a93fd7-…` session migrated its legacy ledger on device: takes 002/003/004 now store `{containerRoot, relativePath}` references and no stale `B116F53B-…` URL. Take 001 was completed but was never kept, so its absence from the ledger/export is correct. Retry Export reached the share sheet and produced `/Users/karlwatson/Downloads/session_2026_08_30_new_dj_baby_scratch_95_bpm 5.zip`. Read-only inspection proved all three kept takes occur exactly once; 17/17 manifest artifact hashes match; device-source media/audio hashes equal the packaged video/scratch artifacts; source sidecars are completed, identity-correct, and error-free; exported notation matches persisted notation (with the documented timestamp omission/default unavailable document); Watch JSON for takes 003/004 matches the exported Watch evidence; metadata, export metadata, review, replay, and take log agree on take IDs/numbers; and no packaged file is zero bytes. Karl reports current-build share cancellation is shown as cancellation and a subsequent newly kept take remained exportable. The latter is recorded as operator evidence because no second archive was supplied; Karl explicitly directed that it be trusted and Slice F marked complete.

**Next task.** The first unchecked implementation-ready item is the separately scoped **Production iOS saved-take notation, playback, and take-detail surface**. It must reuse the shared gesture-relative presentation and must not reopen or fold into Slice F. Nothing staged, committed, or pushed.


## 2026-08-30 — Capture-integrity Slice F: PHYSICAL VERIFICATION FAILED — kept-session ledger stores stale absolute container paths (uncommitted; current)

Verification-only turn on iPhone `K`. No production code was changed. HEAD stayed `7761c09f43` (no amend/reset/rebase/commit/push). The pre-existing dirty worktree, the four protected project/config files, and the untracked `CalibrationCameraOverlayTests.swift.plist` were left untouched and unstaged. Only `DEV_LOG.md`, `TASKS.md`, `AI_HANDOFF.md`, and `AI_HANDOFF/next_prompt.md` were edited, to record this result.

**Do not read either Slice F entry below as a physical result. Slice F stays unchecked in `TASKS.md`.**

**What was done.** Isolated Debug build (`-derivedDataPath` / `OBJROOT` / `SYMROOT` / `SHARED_PRECOMPS_DIR`, Xcode open) for `platform=iOS,id=…` → `BUILD SUCCEEDED`. Installed with `xcrun devicectl device install app` (upgrade; no uninstall, no erase). The failed session's container was preserved and verified: `Documents/CompanionCaptures/b5a93fd7-…_take00{1,2,3,4}_camA.{mov,wav,json}` all present, non-empty, every sidecar `recordingStatus: "completed"`.

**Installed binary carries the latest code.** `ScratchLab.app/ScratchLab.debug.dylib` (built 09:16 from source last modified 08:56) contains all seven `SessionExportValidationReason` raw values, the "Export blocked: manifests/session_metadata.json did not match the session it was generated from." detail string, `guided-capture-kept-sessions.json`, and `sourceMediaURL`. The sub-second-`createdAt` staged-bytes comparison is present. The diagnostic-reason work is NOT missing from the device.

**Physical result — FAILED, no new take recorded.**
1. The kept session did not present its takes as usable after the upgrade install/relaunch.
2. Retry Export did not reach the share sheet. On this freshly installed build it reports, per take: "Take 002 video is missing. Retake it before export.", "Take take-002 is missing b5a93fd7-…_take002_camA.json.", "Take 002 audio is missing. Retake it before export.", "Take 003 video is missing. Retake it before export." The pre-existing build showed the opaque "This session has inconsistent metadata." for the same underlying condition.

**Confirmed root cause (Retry Export failure).** `~/Library/Application Support/ScratchLab/guided-capture-kept-sessions.json` persists each take's `sourceMediaURL`, `sourceSidecarURL`, `sourceAudioURL`, and `sourceWatchMotionURL` as absolute `file://` URLs containing the app Data-container UUID `B116F53B-B4D3-4C1F-805D-40722E98025D`. The device's current Data container has a different UUID, so every one of those paths now dangles. The capture data itself is intact — sidecars store only relative filenames (`mediaFileName` / `sidecarFileName`), so local recovery can still resolve the files, but the ledger cannot. `CompanionCameraView` builds `SessionExportTake` with `mediaURL: keptTake.sourceMediaURL` / `audioArtifactURL: keptTake.sourceAudioURL` / `sidecarURL: keptTake.sourceSidecarURL` — no rebasing against the current container — and `SessionArchiveBuilder.packageValidationIssues` then fails `ArtifactPreflight.checkFileReady` / `FileManager.fileExists` on those dead URLs. `packageValidationReport` maps any "missing" issue to `SessionExportError.missingRequiredFiles`, so `validateStagedPackage` and the new `SessionExportValidationReason` vocabulary are never reached for this session. The sub-second-`createdAt` / staged-bytes fix is therefore neither implicated nor disproven here — the pre-flight source-file check fails before staging runs.

**Failure 1 (kept session "missing") — only partly explained.** The ledger file survived intact and still holds session `b5a93fd7` with takes 002/003/004 (take-001 is not in the ledger; the companion audit summary records four completed takes). Because every ledger take resolves to a dead path, surfaces that gate on file resolution can render the session empty or unexportable. The exact on-screen appearance of "missing" was not captured; this is not fully closed.

**Timeline not established.** Today's `devicectl` upgrade install preserved the container contents, which normally also preserves the Data-container UUID, so the UUID most likely changed at an earlier install cycle. Whether the original 2026-08-30 "inconsistent metadata" failure that reopened Slice F was this same stale-path condition or the distinct `createdAt` bug is not proven. Device logs and/or the original failing archive would settle it.

**Next action for Slice F is code, not another physical run:** the kept-session ledger must resolve take artifacts against the current container — store container-relative paths (or security-scoped bookmarks) and rebase on load — instead of persisting absolute Data-container URLs. This is the "persisted absolute container URLs have no relocation migration" risk already noted below, now a confirmed physical defect. No fix was made in this verification turn. After the fix, rerun a real iPhone export of a freshly kept take plus Share-sheet presentation/cancellation on device.

## 2026-08-30 — Capture-integrity Slice F: iOS "inconsistent metadata" export FIXED; still PHYSICALLY UNAPPROVED (uncommitted)

Started from committed HEAD `7761c09f43`; no amend/reset/rebase, commit, or push. The pre-existing dirty worktree was preserved, including the four protected project/config files, which were not altered or staged.

**Read this before the entry below it.** The next entry records Slice F as COMPLETE with a green gate. That was true of the tests but NOT of the device: the first real iPhone export of a freshly kept take failed with "This session has inconsistent metadata." Do not read that entry as a physical result.

**Root cause.** `SessionArchiveBuilder.validateStagedPackage` wrote `manifests/session_metadata.json`, `export_metadata.json`, `session_review.json`, and `session_replay.json` through the canonical `JSONEncoder`, whose `.iso8601` strategy serializes **whole seconds**, then decoded those files back and compared the decoded documents against the in-memory ones. A `Date` carrying a sub-second component cannot survive that round trip, so a byte-identical, fully valid export was rejected. Measured: `Date(timeIntervalSince1970: 1_710_000_000.372)` encodes to `"2024-03-09T16:00:00Z"` and decodes back 0.372 s earlier; re-encoding the same value is byte-stable.

**Why only freshly kept takes.** A guided kept session's `createdAt` is a live `Date()`, and `GuidedCaptureKeptSessionStore` persists it with the default (`.deferredToDate`) strategy, so the fraction survives in memory and across a reload. `packageForLocalRecordingSession` instead derives `createdAt` from sidecar dates that have already been through `.iso8601`, so recovered sessions are always whole-second. That is exactly why device recovery exports succeeded while a freshly kept take did not — and why every existing fixture missed it, since all of them used a whole-second `createdAt`.

**Fix.** Compare the staged BYTES against the same documents re-encoded through the same canonical encoder — the pattern `session_manifest.json` and every notation document already used in that same function. Decoded documents are kept only for the structural identity assertions (session ID, take IDs, counts, review/replay `generatedAt` agreement). Nothing is rounded, mutated, defaulted, filtered, or softened with `try?`/`compactMap`; the check is now stricter, because it also proves each staged file is the canonical byte-for-byte serialization rather than merely an equal-valued one. **Do not "simplify" this back into a value comparison** — `testSubSecondCreatedAtIsPreservedAndStagedMetadataIsCanonicalBytes` exists to stop that, and also fails if someone floors `createdAt` instead.

**Failure detail.** `SessionExportValidationReason` / `SessionExportValidationFailure` were added because "This session has inconsistent metadata." named nothing an operator or a device log could act on. A staged rejection now carries the specific check that fired alongside the unchanged `SessionExportError`; the coordinator surfaces it through the existing `validationReport`, so the coarse error, its user message, and retry/cancel semantics are unchanged. The reason vocabulary is closed and holds check names only — never paths, performer names, notes, or capture content.

**Preserved deliberately.** The fail-closed "take claims `.platter` motion but its notation recorded no movement events" check. It is still unreproduced on hardware, so it stays strict and is covered by a named-error regression instead of being relaxed. Intentional metadata groups in legacy local sessions keep their established selected-group behaviour; `matchingCompatibleLocalRecordingSidecarURLs` was not touched.

**Verification.** Focused set 14/14 in two executions. The four sub-second cases were first confirmed to FAIL against a temporarily reverted value comparison, then to pass against the fix — without that step the new tests prove nothing. Affected regressions 135/135 (`CaptureRecoveryPhase2CoreTests` 58, `ScratchLabNotationAndExportTests` 29, `SessionExportRoundTripTests` 1, `SessionReviewMetadataTests` 17, `SessionQualityAnalyzerTests` 15, `SessionReplayTimelineTests` 7, `SessionReplayDocumentTests` 8). Isolated generic iOS Simulator and macOS Debug builds green; fixtures 47/47; `git diff --check` clean. Full configured gate: **3,157 XCTest cases / 49 skipped / 11 assertion failures across exactly the established 9 unique names**, no export or Slice F name in the set, plus 366/366 Swift Testing cases.

**Slice F is NOT physically approved.** A real iPhone export of a freshly kept take must succeed, and Share-sheet presentation and cancellation must be checked on device. The earlier remaining risk still stands: kept ledgers persist absolute app-container URLs with no bookmark/rebase layer for a migration that relocates files. Nothing staged, committed, or pushed.

## 2026-08-30 — Capture-integrity Slice F COMPLETE: durable kept-session export (uncommitted; current)

Started from committed HEAD `7761c09f43`; no amend/reset/rebase, commit, or push. Existing dirty files were preserved, including the four protected project/config files.

**Root cause.** Keep only advanced transient UI state. There was no durable authoritative set of kept takes, so Export could disappear after Keep-and-Next or navigation, and archive completion did not establish that all real inputs and generated outputs were present, associated with the right take, unique, and byte-correct.

**Implemented.** `GuidedCaptureKeptSessionStore` atomically persists an append-only, idempotent session ledger and restores it across view lifetimes. Both Keep paths cross that boundary before presenting success. Ready/setup/session-complete surfaces expose Export / Share whenever the active session has kept takes, and later takes append to rather than replace the export set. Retry never discards staged captures; only explicit Discard does. `SessionExportCoordinator` now keeps failure visible/retryable, treats share-sheet cancellation separately, rejects stale/fabricated completion, and validates the source plus unzipped package: media/audio identity and hashes, sidecars, notation, Watch/motion, metadata, manifests, review/replay, take log, optional generated mixes/stems, and unique take numbers/IDs/paths. Local recovery is fail-closed so a corrupt or mismatched take cannot be silently filtered out.

**Verification.** The seven Slice F deterministic tests, seven affected notation/MIDI export regressions, and two legacy metadata-group compatibility tests passed in two final focused executions (16/16 each). Isolated generic iOS Simulator and macOS Debug builds passed after the final compatibility patch; capture fixtures passed 47/47; `git diff --check` passed. The first broad gate exposed seven review-timestamp regressions, and an intermediate gate exposed two metadata-group regressions; both sets were fixed. The final isolated broad gate returned exactly the established **11 assertion failures / 9 unique names**, with no Slice F or export name in the set.

**Remaining risk.** Kept ledgers persist absolute app-container URLs; normal app updates preserve the container, but a migration/restore that relocates files has no bookmark/rebase layer. Physical Share-sheet presentation and cancellation should still be checked once on device. Nothing staged, committed, or pushed.

## 2026-08-30 — Capture-integrity Slice E COMPLETE: one bounded, take-ID-scoped finalization state machine (uncommitted; current)

Started from committed HEAD `c0bb3babc1` without amend/reset/rebase. The pre-existing dirty worktree was preserved. Protected `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and untracked `CalibrationCameraOverlayTests.swift.plist` were not altered or staged.

**Root shape.** There was no single authoritative finalization state. "Are we saving", "did the watchdog already run", "was this summary already handled", and "is this summary for this take" lived in four places — a `flowState` case, a view-owned 12s + 3s `Task` watchdog, a `lastHandledRecordingID` string on the store, and a `matchesActiveSavingTake` helper checked independently by three delivery paths — so they could disagree. Worse, the de-duplication check ran at the END of `handleFinishedRecording`, after controller notation had been re-persisted, `pendingScratchAudioURL` consumed, and artifact banners raised. A duplicate recorder callback repeated all of that and falsely reported the rendered AHHH audio missing.

**What is in place.** `CaptureFinalizationMachine` in `CaptureCore.swift` is the whole finalization policy: one typed `CaptureFinalizationState` (`idle` / `awaitingRecorder` / `retryingStop` / `completed` / `failed`) scoped to a `CaptureFinalizationTakeKey(sessionID:takeNumber:)`. It is pure and clock-free — `apply(_:at:)` is handed the instant — and returns an ordered `[CaptureFinalizationEffect]` the view performs. `CaptureFinalizationBudget` states the 15s worst case (12s wait + exactly one 3s retry) that two hardcoded sleeps used to imply. `CaptureFinalizationDeadlineScheduler` is the only place a deadline becomes elapsed time and scheduling replaces the previous timer. `CaptureFinalizationClock` injects the time source.

It is a **consolidation, not an addition**: the view's `finalizationWatchdog` task, both hardcoded sleeps, and the store's `lastHandledRecordingID` are deleted. `flowState` is now a projection driven by the machine's `freezeElapsedTimer` and `presentRecoverableFailure` effects, and `matchesActiveSavingTake` is a one-line delegate to `finalization.acceptsSummary(for:)`.

**Invariants to preserve.** Do not add a second watchdog or a second "is saving" flag — that is exactly the shape this slice removed. Do not move the summary gate back to the end of `handleFinishedRecording`; it must run before any side effect. Do not branch on `CaptureStopSource` — the phone and Watch Stops must keep producing byte-identical effect lists; the value is provenance only. Do not let `preserveStagedMedia` follow `presentRecoverableFailure` in any effect list. Keep `mediaContainsAudio` returning `Bool?` with `nil` on timeout: making it return `false` would downgrade a good take to `missingAudio` whenever an `AVAsset` open is merely slow. Keep the machine in `CaptureCore.swift`, which is in both targets and Foundation-only — moving it to the iOS-only view file makes it untestable from the macOS test target, and adding a new file needs separate `project.pbxproj` approval.

**Verification.** `CaptureFinalizationMachineTests` 28/28 twice; Slice E source-structure guards 7/7; regressions twice each (`CaptureRecoveryPhase2CoreTests` 58/58; the `GuidedCaptureReviewState` / `CaptureMotionEvidence` / `CaptureMotionEvidencePresenter` / `ControllerPlatterDecoder` / `RanePlaybackRoutingPolicy` set 123/123; the notation/export set 45 executed / 1 skipped / 0 failures). Isolated generic iOS Simulator, generic iOS device (embedded Watch), and macOS `build-for-testing` builds all green. Fixtures 47/47. `git diff --check` clean.

**Physical check: PASSED on device (2026-08-30, Karl, iPhone `K`).** A signed Debug build of the current source — Slice E included, embedded `ScratchLabWatch.app` present — was built with isolated `build/SliceE-device-*` paths, installed to `com.machelpnz.scratchlab`, and launched.

1. **Save Take freeze → Review: PASS.** The elapsed readout froze immediately at the tap and Review appeared. This is the original hang symptom and the first-accepted-Stop freeze, both confirmed on hardware.
2. **Stop immediately after Start: PASS — branch (a), the deferred stop.** Karl tapped Stop inside the start race and the iOS Review screen appeared reading `Ready to keep`, with Keep / Retry / Discard available; the take was then kept and exported successfully. This is the **deferred-stop branch**: the broadcaster's `stopRequestedWhileRecordingStarts` retained the request and delivered it from `didStartRecordingTo`, so the take finalized normally. It is **not** the preservation-timeout branch — `preserveStagedMedia` → `presentRecoverableFailure` did not run, and the 15s bound was never reached. Do not record this as a timeout or a recovery-banner result.
3. **Watch Start/Stop, one tap each: PASS.** With the iPhone Capture screen foreground and the Watch showing Transfer Connected, a single Watch tap started the take and a single Watch tap stopped it. No second tap was needed, confirming the unified `stopTake(source:)` path on hardware.

**Supplied iOS export inspected and healthy.** Session `b5a93fd7` (2026-08-30) exported one 11-second take: `recordingStatus: completed`, `errorDescription: null`, 35 movement events, 9,572 mixer MIDI events, notation confidence 0.948, `watchSyncState: acknowledged`, and a real Watch CSV carried through to `watch/NEWDJ_baby_095_take01_watch.csv`. Its audit trail runs `take_allocated` → `watch_requested` → `watch_sync acknowledged` → `recording_completed` → `notation_snapshot` → `watch_linked` → `watch_reconciled`. An earlier session `568857c3` was also inspected: all three of its takes carried `recording_completed` + `notation_snapshot`, including the take that was reviewed but not kept, so its absence from that export is correct behaviour and not a finalization failure. No sidecar inspected on device shows `recordingStatus: failed` or any `errorDescription`.

**Separate product gap, NOT a Slice E defect and NOT to be folded into D or E.** Production iOS has no saved-take playback/detail surface: `TakeReviewView` renders a status card, video thumbnail, text detail blocks and decision buttons only, with no notation, lane, trace or chart; `Take Detail` exists solely on macOS (`MacAnalyzerView.reviewFigmaTakeDetail`); and the only iOS saved-notation surfaces, `DebugReviewNotationCard` and `DebugNotationLaneHostView`, are entirely `#if DEBUG` and wired into no production surface. A saved take therefore cannot be reopened or played back on iOS. This is tracked as its own unchecked task in `TASKS.md` and must not be silently dropped.

Slice D's own refreshed physical approval (macOS free-spin → catch → unequal push/pull/reversal, and the iOS signed-playhead/saved-surface check) is separate and **still outstanding**; Slice E's device pass does not cover it.

## 2026-08-29 — Capture-integrity Slice D COMPLETE: gesture-relative notation versus raw sample position (uncommitted; current)

Started from committed HEAD `c0bb3babc1` without amend/reset/rebase. The pre-existing dirty worktree was preserved. Protected `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and untracked `CalibrationCameraOverlayTests.swift.plist` were not altered or staged.

**Root cause.** Performance notation rendered accumulated signed/unwrapped CC6 motor phase. Free-running revolutions therefore moved the lane origin and made the next reversal begin high. That same raw coordinate is intentionally correct for audio and the waveform playhead, which need signed displacement from the hot-cue origin and must remain capable of `BEFORE START` / `PAST END`.

**What is in place.** `PlatterCoordinateSemantics` now names two independent meanings: `gestureRelativeNotation` maps each decoder movement run into its own local coordinate frame, and `samplePosition` preserves exact raw signed/unwrapped travel. The notation projection reuses `ControllerPlatterDecoder` movement-run/reversal boundaries and noise gates; there is no second scratch detector. Direction, timestamps, displacement, speed, and real unbounded excursion survive rebasing. The shared gesture-relative presentation is consumed by live iOS notation, live macOS notation, macOS saved Review and Take Detail, camera passthrough, overlays, and result charts. **Scope correction (2026-08-30): this slice does NOT deliver a production iOS saved-take surface.** iOS ships the live signed playhead and live notation; macOS ships live notation plus saved Review and Take Detail. Production iOS saved-take notation/playback/detail does not exist and is tracked as a separate unchecked task. Replacement hardware captures showed that the original stable one-revolution frame plus macOS's fixed 118-point live canvas made ordinary 0.08–0.22-revolution scratches too small. Controller presentation now uses one fixed quarter-revolution full-scale frame and the macOS live card fills the camera stage. A 0.10 / 0.20 / 0.25-revolution stroke occupies 40% / 80% / 100% of the lane. At or above 0.25 revolution the display reaches the rail intentionally; the physical event/export remains exact and unbounded. Camera endpoint dots now apply reduced radius once. Mixed-source rendering retains its legacy content-derived frame.

**Evidence boundary — preserve this.** `DetectedNotationSnapshot.recordMovementEvents` remains canonical and continues to feed scoring/export. Saved-presentation reconciliation is opt-in for unambiguous single-CC6 controller evidence: exact raw/canonical timing matches replace coordinates only and keep canonical metadata; decoder-valid raw runs dropped by fusion are presentation-only; fusion-merged same-direction spans expand to their covered decoder runs. Never route these presentation additions into scoring/export. `IOScratchPlaybackEngine` only expresses its existing raw hot-cue subtraction through `samplePosition`; audio scheduling and renderer behavior are unchanged. Do not flatten or clamp the raw playhead merely to flatten notation.

**Live invariants.** A committed stroke never changes coordinates when later input arrives. The iOS bounded live window advances only at decoder-safe boundaries after a committed event leaves the viewport. While powered-motor suppression is active, it retains the release-classifier lookbehind tail so the first genuine reversal packets are not lost. Provisional events may extend until committed, but older committed events are append-only.

**Verification.** Focused suites passed 147/147 twice; the relevant regression + saved-Review set passed 88/88 twice; isolated macOS and generic iOS Simulator builds succeeded, including the embedded Watch target; capture fixtures passed 47/47. Both broad configured passes ran 3,111 XCTest cases / 49 skipped / 11 assertion failures across exactly the established 9-name set, and 366/366 Swift Testing cases passed in each. The four-test increase from the prior 3,107 baseline is exactly the new display-scale/endpoint coverage. `git diff --check` passed after the final record update. Independent review found and prompted the now-fixed double-scaled camera endpoint; its follow-up audit found no remaining semantic-scope issue.

**Physical status and required recheck.** The replacement iOS/macOS archives and screenshots supersede the earlier `rr` session. They show stable local direction/baseline behavior but also prove the former trace was too small; because they predate the quarter-turn zoom, they are not approval of the final presentation. On macOS, select RANE ONE MKII with channel assign fully left; Advanced → Mixer & Hot Cue Mapping → apply mapping + load AHHH; open live Practice Copy or a short Capture; allow at least three hands-off forward revolutions; catch the platter and perform a short pull, a different-length push, then another pull/quick reversal. The caught gesture must begin at its own baseline; ordinary 0.10–0.20-revolution scratches should occupy about 40–80% of the lane; quarter-turn-or-larger strokes intentionally reach the rail; signed slope/timing/relative sub-quarter excursion must match the hand; completed strokes must stay fixed. On iOS, separately move backward through cue and forward past sample end: audible AHHH and cyan waveform/playhead must remain synchronized and show `BEFORE START` / `PAST END` without wrapping. Then, **on macOS**, save a take and compare live notation against saved Review and Take Detail, plus the camera overlay, for stroke order, direction, timing, and relative sub-quarter excursion; scrolling/viewport, horizontal scale, and camera radial geometry may intentionally differ. The saved-surface comparison belongs to macOS because those are the only production surfaces that render saved notation — do not attempt it on iOS, which has no such surface. **PHYSICAL APPROVAL RECORDED (Karl, 2026-08-30).** All three refreshed checks passed. macOS: the free-spin did not accumulate into the next gesture's baseline; catch, unequal push/pull, and reversal direction displayed correctly; completed strokes remained fixed. macOS saved Review and Take Detail preserved stroke order, direction, timing, and relative excursion. iOS: the playhead crossed `BEFORE START` and `PAST END` without wrapping and stayed synchronized with audible AHHH.

The supplied macOS export corroborates the visual approval but is **not** the approval itself — visual acceptance came from Karl, not the archive. Session `53d4b65d` (`calibration_no_click`, RANE ONE MKII, 20s, 12 files, none zero-byte, three debug traces present) contains one `slowDrag` free-spin run of **0.8419 revolution over 5.99s**, then 18 pulls spanning −0.0240 to −0.0558 rev and 7 pushes spanning 0.0273 to 0.0524 rev, so the performed asymmetry survives into the evidence. Note for future readers: in that export every post-catch gesture still starts at **0.7915–0.8507**, i.e. carrying the free-spin offset. That is CORRECT — canonical export/scoring keep the raw signed coordinate and gesture-relative rebasing is a presentation transform. Do not mistake those raw values for a regression of the old accumulated-motor-phase bug.

Slice D therefore has no outstanding physical acceptance risk. Nothing staged, committed, or pushed.

## 2026-08-29 — Standalone test isolation cleanup complete (uncommitted; current)

`PlatterTestSampleLoadTests` and `MIDILearnEngineTests` no longer depend on shared host state. The platter suite explicitly supplies `Bundle(for: MacCaptureEngine.self).resourceURL`; `ScratchSampleResolver` and `ScratchSamplePlaybackController` retain `Bundle.main.resourceURL` as their production default. The MIDI suite creates a unique `UserDefaults` suite in `setUp`, clears it before/after every test, and explicitly injects it into `MacCaptureEngine`; production and callers without explicit injection retain their prior `.standard` legacy-crossfader behavior. No assertion was weakened and no audio, routing, MIDI-event, or sample-selection behavior changed.

Verification: both target suites passed standalone twice before editing and twice on the final code (`PlatterTestSampleLoadTests` 2/2; `MIDILearnEngineTests` 32/32). `MIDILearnHangFixTests` passed 15/15 after the compatibility correction. Both target suites passed inside the full desktop plan. The full gate remains the **11 failures / 9 unique-name baseline** (3,090 tests / 49 skipped); neither target suite is in the failing set. Isolated iOS and macOS builds succeeded; capture-pipeline fixtures passed 47/47. The pre-existing untracked `.codex-build/` disappeared externally during the task and was not recreated. Protected dirty `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and `CalibrationCameraOverlayTests.swift.plist` were not altered. Nothing committed or pushed.

## 2026-08-29 — RANE right-deck playback routing FIXED and PHYSICALLY APPROVED (uncommitted; current)

Started from `37e2d1d1`. No commit amended or reset.

**MEASURED HARDWARE TRUTH — treat as settled, do not re-derive.** The RANE ONE MKII exposes **10** USB output channels (not 14). USB output **1/2 is the left deck**, **3/4 is the right deck** (Karl, hardware-confirmed). **13/14 is the master path** and must never be used for deck playback — it bypasses the channel strip, fader, and meter.

**Root cause.** `IOScratchPlaybackEngine` hardcoded `raneOutputChannelCount = 14` and gated the channel map on `maximumOutputNumberOfChannels >= 14`. `10 >= 14` is false → requested stereo → `channelMap` never installed → playback fell to the device's first pair, **1/2, the left deck**. The pair index `2` was correct all along and was never applied — which is why both the earlier 13/14 assumption and the later 3/4 value lit the wrong meter. The old DEBUG log printed the *requested* channel count, so it read `14` even when nothing was installed; that is what hid the defect across two prior attempts.

**AVAudioSession is NOT at fault — do not "fix" it.** The diagnostic showed it granting 10 of 10 on request, and `options=8` is `.defaultToSpeaker` alone, which did not block multichannel USB. No category/mode/option was changed, and the earlier `.defaultToSpeaker`/`.mixWithOthers` hypothesis is disproved.

**What is in place.** `RanePlaybackRoutingPolicy` lives in `DVSHardwareProfile.swift` — chosen because that file is in **both** targets and Foundation-only, so the policy is testable from the macOS test target while the engine that applies it is iOS-only. `minimumRequiredOutputChannels` is **derived** (`rightDeckPairStartIndex + 2 = 4`), never a device size. The engine requests the route's real maximum, decides from the granted session count **and** the output node's own count, sizes the map to the real destination count, applies it, then **reads it back and verifies** before allowing playback. A recognized RANE that cannot reach the right deck **throws and refuses to play** — do not reintroduce a stereo fallback, that silent downgrade to 1/2 *was* the bug. Non-RANE routes are untouched.

**Physical acceptance (Karl, iPhone K):** AHHH plays through the right deck, only the right meter responds, right upfader and right-deck crossfader control it, master output normal, DVS unaffected. Log corroborates: `granted=10 max=10 outputNode=10 map=[-1,-1,0,1,-1,-1,-1,-1,-1,-1] onRightDeck=true decision=raneRightDeck`, identical at `after-engine-start`.

**Test debt repaid.** The old `testRaneScratchPlaybackUsesRightDeckOutputThreeFourIndependentlyOfDVSInput` asserted the literal string `"let raneOutputPairStartIndex = 2"` and **passed throughout the entire bug**. Replaced by 17 behavioural tests. Do not reintroduce source-string assertions for routing.

**DVS input stays physical 3/4** in the independent input namespace. Input and output both using 3/4 is not a collision; neither may be derived from the other.

**Verification.** 17/17 twice; regressions green (39/39, 22/22, 40/40, 17/17, plus Slice A/B/C); iOS + signed device + macOS `build-for-testing` all built; fixtures 47/47; `git diff --check` clean. `scripts/build.sh all` exit 65, **3090 / 49 skipped / 11 failures**, failing-name set **identical to the post-restore baseline (9 names)**.

**Standalone isolation fragility resolved:** see the current entry above. Both suites pass standalone twice and in-plan.

## 2026-08-29 — Capture-integrity Slice C: crossfader provenance + take-window bounding (now in commit 37e2d1d1)

Started from `14685e06`. Neither `089965f4` nor `14685e06` was amended, reset, or rebased.

**Resource deletions were restored** (Karl-authorised, gate checked first: all 32 entries were `D`, none `M`/`A`). This alone removed the whole Coach-demo / reference-audio / practice-reel failure family — the full-gate baseline went from **15 failures / 13 names to 11 failures / 9 names** before any Slice C code existed. `project.pbxproj`, `ScratchLab.xcscheme`, `Info.plist`, and the untracked `.swift.plist` remain untouched.

**TWO CORRECTIONS to earlier claims — read these before repeating them.**
1. The old Slice C stub said the `"Raw ch 15 · CC 8"` row "shows as configured while persisting zero events". False — it already read `"Not active · expected …"`. Retracted.
2. **The take-002 `Fader: No movement` is very likely CORRECT, not a bug.** `ScratchLabApp.configureMIDILearnDevice()` already auto-applies the verified RANE mapping at startup, and a Baby Scratch is played with the fader OPEN, which the existing delta gate correctly renders as zero events. Do not describe Slice C as the fix for that screenshot.

**Real defects fixed.** (a) The resolver checked the registry for transport but not crossfader, despite a `.certified` RANE crossfader binding existing — so a device selected manually via `selectMIDISource` (which, unlike startup, never auto-applies) recorded nothing. (b) No take-END bound existed, so moves between Stop and finalization landed in the finished take.

**What is in place.** `FaderMappingSource` (`learned` / `certifiedRegistry`); resolver step 2b gated on a real registry match at `.certified` confidence plus a non-diagnostic `.crossfader` binding — never a blind CC8 sniff, and learned always wins. **Evidence-only**: `setCrossfaderPosition` is called only for `.learned`; do not extend it to the registry path without a new decision. Provenance persists on `RawMixerMIDIEvent.mappingSource` (Optional → legacy sidecars decode `nil` = unknown, never "learned") and reaches review rows and `SessionExportTake.faderMappingSource`; no on-disk schema change. `markCaptureStopped()` bounds the take in the `CACurrentMediaTime()` domain, with the filter in shared `CaptureMotionEvidenceResolver.eventsWithinTakeWindow` because `iOSMIDIManager.swift` is iOS-target-only and unreachable from the macOS test target.

**Untouched by design:** `deriveDetectedNotationFaderEvents` and its delta gates, so an open-fader Baby Scratch still yields zero events. macOS keeps its separate `CrossfaderCCMapping` — documented as a known divergence in `MIDIActionResolver.swift`.

**Verification.** 21 new `CrossfaderMappingProvenanceTests` + Slice A/B suites = 51/51, twice. Regressions green (46/46, 29/29, 22/22, 58/58, 29/29, 14/14). iOS + macOS builds and `build-for-testing` green; fixtures 47/47; `git diff --check` clean. `scripts/build.sh all` exit 65, **3073 tests / 49 skipped / 11 failures** — count up by exactly 21, failing-name set **identical to the post-restore baseline (9 names)**.

**Historical standalone fragility resolved 2026-08-29:** `MIDILearnEngineTests` now uses an explicitly injected, reset-per-test defaults suite; see the current entry above.

**Physical RANE checks still required:** registry matching depends on the real CoreMIDI endpoint name (`"rane one"` matching is unverified against the actual device string); confirm a fader cut records with `· certified default` provenance when no mapping is learned, that ScratchLab stays silent on that path, and that a move made just after Stop does not appear in the take.

## 2026-08-29 — Capture-integrity Slice B: truthful review state derivation (now in commit 14685e06)

Started from Codex checkpoint `089965f4`, which had absorbed Karl's prior WIP **and** Slice A. That commit was not amended, reset, rebased, or overwritten. The unstaged Xcode settings, resource deletions, and stray `CalibrationCameraOverlayTests.swift.plist` were left untouched — Slice B needed none of them.

**Root cause was three defects, not one.** The operator message was a hardcoded `"Ready to keep"` literal decided at two call sites that never consulted motion; `motionAssessment` computed `syncStatus` and `motionStatusTitle` as two independent strings and deliberately returned `"Motion pending"` alongside `"Motion Missing"` for one false input; and `CaptureReview` stored all four labels as separately-settable `var`s.

**What is in place.** One `GuidedCaptureReviewState` built from typed `CaptureReviewReadiness` and `CaptureMotionStatus`. `reviewState(...)` now also takes `recordingFailed` and `duration`, so readiness cannot be decided at a call site. `operatorMessage` / `syncStatus` / `motionStatusTitle` / `motionPresent` are computed projections of one stored value — do not reintroduce them as independent stored properties. `syncStatus` intentionally restates the motion wording verbatim when motion is the blocker; that repetition is the fix, not a bug to "clean up". A new `retakeRecommended` readiness keeps a motionless-but-valid take honest and still keepable. A shared `CaptureMotionEvidencePresenter` renders `Platter: Present · MIDI` / `Fader: N events` / `Watch: Not used` in both review layouts. DVS is deliberately not a row while no real feed exists.

**Verification.** `GuidedCaptureReviewStateTests` 10/10 and `CaptureMotionEvidencePresenterTests` 7/7 plus Slice A's 13/13, all twice. Two tests are exhaustive over all seven resolver inputs and assert `"Motion pending"` is unreachable and `readyToKeep` can never pair with missing motion. Regressions green (58/58, 29/29, 14/14, 3+1 skipped). iOS + macOS builds and `build-for-testing` green; fixtures 47/47; `git diff --check` clean. `scripts/build.sh all` exit 65 with **3052 tests / 49 skipped / 15 failures**, and the `CaptureReliabilityPhase1CoreTests` failing-name set diffed **identical to the Slice A baseline (26 names, nothing added, nothing fixed)**.

**Still unfixed, do not report as done:** crossfader capture still requires a learned mapping so `Fader` reads `No movement` on an unmapped controller (Slice C); bounded finalization is Slice E, not this slice; notation coordinates, audio ownership, export discoverability, clipping/health, and landscape layout are untouched.

**Needs Karl's eyes:** a required-motion-missing take now reads `Retake recommended` instead of `Ready to keep` — intended, but user-visible copy. The evidence rows add two cells to the landscape detail grid and were not verified on hardware; landscape crowding is Slice H.

Nothing was committed or pushed.

## 2026-08-29 — Capture-integrity Slice A: shared capture-evidence model (now in checkpoint 089965f4)

Karl's ten-requirement capture-integrity prompt (physical iPhone take-002: live notation moving while the HUD read `MOTION Motion Missing`, and Review showing `Ready to keep` + `Motion pending` + `Motion Missing` + `Fader: No movement` at once) was classified as roughly eight architectural slices rather than one batch, decomposed into A–H at the top of `TASKS.md`, and Karl selected **Slice A only**. Nothing else in that prompt has been implemented.

**Root cause, verified in code.** Motion presence was derived solely from a linked Apple Watch artifact at three sites: `CompanionCameraView.handleFinishedRecording`, that file's `makeSessionExportPackage` take builder, and `SessionExportCoordinator`'s recovery builder. The take's real controller evidence was already decoded by `iOSMIDIManager.detectedNotationSnapshot()` and persisted into the sidecar four lines above the first check, then ignored by all three.

**Second root cause found during implementation.** Two export gates would have *rejected* the newly-truthful takes: `packageValidationIssues` flagged "claims watch motion, but no linked watch artifact was supplied", and the canonical-context builder hard-`throw`s `invalidSessionMetadata` on the same condition. Both are now source-aware. Do not collapse `claimsWatchBackedMotion` / `claimsMotionWithoutAnySource` back into a bare `motionPresent == true` test.

**What is in place.** A domain-only `CaptureMotionEvidence` (platter / fader count / watch / DVS) plus `CaptureMotionEvidenceResolver` in `CaptureCore`, carrying no user-facing strings by design — presentation is Slice B. Gesture-vs-motor discrimination is structural (a decoded reversal), reusing the existing decoder noise gates rather than adding a threshold. Fader events never establish platter motion. DVS is `.unsupported` because iOS capture has no timecode feed at finalization. Live export and recovery both resolve from the same persisted `sidecar.detectedNotation`, so they cannot disagree. `SessionExportTake.motionSources` is additive and optional, `nil` preserves legacy Watch-only validation, and `SessionExportTake` is not a serialized type — there is **no on-disk export-schema change**.

**Verification.** 13 new `CaptureMotionEvidenceTests` passed twice; `ControllerPlatterDecoderTests` 14/14, `CaptureRecoveryPhase2CoreTests` 58/58, `ScratchLabNotationAndExportTests` 29/29, `Take002ControllerRoundTripTests` 3 passed/1 skipped; isolated macOS build, macOS `build-for-testing`, and generic iOS Simulator build all green; fixtures 47/47; `git diff --check` clean. `scripts/build.sh all` was run once and exited on the pre-existing dirty-WIP baseline only (four documented UI-layout failures, the documented `testRaneOneMkiiDebugPresetHasSetupNoteOtherPresetsDoNot`, the Coach-demo/reference-audio resource suites from deleted WIP resources, and four `ScratchSamplePlaybackControllerTests` DVS/wrap tests from the dirty renderer WIP). That attribution was proven, not assumed: the missing `chirpflare_noBeat.wav` was confirmed absent from the built bundle, and intersecting the failing test names against every test referencing a Slice A symbol produced the empty set.

**Still true and unfixed** (do not report these as done): the hardcoded `"Ready to keep"` literal and the resolver's two-strings-for-one-false-input shape survive until Slice B, so a genuinely motionless take can still show contradictory labels; crossfader capture still requires a learned mapping, so `Fader: No movement` is unchanged until Slice C; notation coordinate drift, audio ownership, finalization bounding, export discoverability, clipping/health, and landscape layout are all untouched.

**Decision recorded.** Karl chose an explicit audio-ownership mode (external Serato silent / standalone local AHHH retained) rather than deleting local AHHH. This supersedes the "restore local AHHH" gate below without erasing it — keep the existing Load AHHH controls and add the mode in Slice G.

**Next action is physical, not code:** one short RANE take with no Watch paired, confirming Review reports motion present and the export validates. Nothing was committed or pushed.

## 2026-08-29 — latest physical iOS evidence fixes and audible macOS AHHH test (uncommitted; supersedes output-13/14 notes below)

- Physical RANE evidence disproved the earlier ScratchLab-output 13/14 assumption: iOS now sends its right-deck stereo to physical outputs 3/4. DVS still reads physical inputs 3/4; input and output channel spaces are independent. Do not restore iOS output 13/14 unless new hardware evidence proves it.
- iOS take ownership is now complete for this path: raw take-relative crossfader MIDI, canonical fader transitions, detected notation, and Watch command/reply evidence are persisted. The scratch WAV is renamed to the exact movie/sidecar basename before Review/export, so recovery no longer treats it as an unrelated UUID stem.
- Watch Start is truthful: it is disabled unless the iPhone is live-reachable. The iPhone Capture/System Check screen must be foreground and ready and the Watch must say Transfer Connected; paired alone cannot start the camera. Stop remains reachable for an active take.
- macOS notation can exist without audio because it is driven by motion/timing data. `Apply mapping + load AHHH` deliberately arms `dvs_ahhh` silently. A separate repeatable `Test AHHH audio` button now plays a short excerpt from that exact bundled sample through the macOS system output and leaves it armed for right-platter CC6 movement.
- Focused iOS evidence/route/Watch/recovery tests are green twice, fixtures pass 47/47, and `PlatterTestSampleLoadTests` passes 2/2 twice. Signed iPhone/embedded-Watch and isolated macOS builds succeed. The current clean macOS build is open from `build/CodexProducts-macos-ahhh-final/Debug/ScratchLab.app` (PID 20154); its AHHH hash exactly matches source: `4c932a6fd6b26af317eaa7850ca8e11626c5a41e8d382561dcfac81e95949791`. A final broad-gate rerun passed fixtures 47/47, retained the known missing Coach Demo failures, and then lost the sandboxed runner/IDE helper connection before the next export test completed; do not treat that incomplete test as a new assertion regression. Nothing committed or pushed.

## 2026-08-29 — AHHH waveform/playhead designed and implemented for iOS landscape (uncommitted)

- Figma file `AgrnQXwRvkAKlORTQ2U25z` now contains reusable `SamplePositionWaveform` component set `457:3817` with Unloaded/Ready/Active states and exact `VirtualPlatter/ahhh.wav` envelope data. It has separate cue and live-playhead markers, START/MID/END labels, transparent presentation, and one audited placement in each of eight current iPhone/iPad landscape Practice/Capture states. Do not replace it with a decorative/fake waveform or opaque card.
- Production reads the same real sample: `IOScratchPlaybackEngine` builds a 128-bin envelope and exposes the renderer's actual smoothed playhead; `IOScratchRenderer` publishes that position through atomics while preserving signed before-cue/past-end travel across its loop. `SamplePositionWaveformView` renders at 30 fps along the bottom of active landscape Practice and both Capture camera paths, with amber bounds warnings and no backing surface.
- This view answers “where am I in the AHHH sample?” and shows bound overshoot. The existing target notation answers “how far should this exercise move?” Keep both; do not claim the waveform adds a separate performance score.
- Focused coverage passed twice, fixtures passed 47/47, and iOS/macOS/watchOS builds succeeded. A fresh signed build with the embedded Watch companion is installed and launched on physical iPhone `K`. `scripts/build.sh all` still exits 65 on the established dirty-WIP deleted-resource/UI/MIDI/DVS/profile baseline after reaching 366 tests; the new waveform test is green. Physical RANE comparison of the cyan playhead with audible output remains. Nothing committed or pushed.

## 2026-08-29 — complete Figma notation audit and current device integration state (uncommitted)

- Figma file `AgrnQXwRvkAKlORTQ2U25z` is now the audited notation source. All 44 direct target/performance surfaces, five canonical variants, 17 instances, and the macOS overlay/preview set were checked. Result: zero structural failures, zero stale demo metadata, and zero notation/control overlaps.
- Every teaching target uses the current BBB 79 BPM 32-movement/16-cycle demo. Performance traces are intentionally independent examples. Decorative turnaround/click-like squares are gone; the open-fader rail remains. Notation canvases are transparent, including Prototype A, iPhone Entry + Practice, iPhone/iPad live Practice/Capture, and macOS Copy. Mac Copy is taller rather than the prior flat dark strip.
- Production matches the design rule through transparent `ScratchNotationPanel` / `ScratchMotionLane` surfaces and the taller unbacked macOS Copy overlay. iOS Save Take now completes from the matching recorder finalization callback, including Stop-during-start. Watch Start/Stop sends an authoritative phone capture command and waits for the phone reply. RANE ScratchLab playback uses physical outputs 13/14; DVS remains physical 3/4.
- Focused tests pass 9/9; fixtures pass 47/47; isolated macOS and iOS Simulator/embedded-watch builds succeed. Current signed iOS source was installed/launched on iPhone `K`; current macOS source was built/launched. Direct Watch installation failed at the external Bluetooth pairing layer (CoreDevice 4000 / remote pairing 1035); the companion is embedded in the phone app and should sync once the Watch is reachable/unlocked.
- `scripts/build.sh all` reached the broad 366-test macOS plan after fixtures, then exited 65 on existing dirty-WIP missing-resource/UI/profile/DVS/demo failures. Do not claim that broad baseline is green, and do not restore unrelated deleted assets. The slice-specific tests are green. Manual closure: save/export a short phone take, start/stop Capture from Watch, confirm RANE 13/14, and approve notation on physical phone/iPad/macOS. Nothing committed or pushed.

## 2026-08-29 — iOS Save Take state/UI repaired and deployed to physical iPhone (uncommitted)

- The reported “Saving Take” hang was a UI finalization defect, not lost capture media. Device inspection found a completed 10.4-second HEVC/AAC movie and matching completed JSON sidecar in `Documents/CompanionCaptures`; preserve those files.
- `CompanionCameraView` now consumes matching broadcaster summaries, freezes elapsed time at the Save Take request, advances to Review before optional audio inspection, and bounds Saving with a stop retry/recovery watchdog. `CompanionCameraBroadcaster` clears stale summaries at start and no longer silently ignores an inactive-recorder stop.
- Immersive iPhone/iPad landscape uses one safe-area-aware control row. The native toolbar is hidden only for that immersive layout; local back/settings controls, summary, Recheck/action, metrics, and notation now have non-overlapping reserved space.
- Both normal `ahhh` and `dvs_ahhh` playback resolve to `VirtualPlatter/ahhh.wav`; this is important because the built app still contains a different legacy flattened `ahhh.wav`. The approved hash is `4c932a6fd6b26af317eaa7850ca8e11626c5a41e8d382561dcfac81e95949791`.
- Signed iPhone/watch build succeeded, was installed, and launched on iPhone `K` (iPhone 16 Pro Max, iOS 27.0). Focused capture tests pass 3/3 and fixtures pass 47/47. The required broad script compiled and began tests, but the existing macOS test runner hung after starting `AutoCutVisualPlaybackTests`; it was interrupted after 92 seconds and no xcodebuild/xctest process was left running.
- Manual closure: make one fresh physical take, press Save Take, confirm the timer freezes and the app immediately reaches Review, then Keep/Export. Nothing committed or pushed.

## 2026-08-29 — current iPhone and macOS products built and launched (uncommitted)

- A signed current-source iOS Debug build was installed and launched on physical iPhone `K` (iPhone 16 Pro Max, iOS 27.0), bundle `com.machelpnz.scratchlab`. Its packaged `VirtualPlatter/ahhh.wav` exactly matches the approved source SHA-256 `4c932a6fd6b26af317eaa7850ca8e11626c5a41e8d382561dcfac81e95949791`.
- A fresh arm64 `ScratchLabDesktop` Debug product was built and launched from `build/CodexProducts-macos-launch/Debug/ScratchLab.app`. Its packaged BBB demo exactly matches source SHA-256 `220a2d74568b91d580ab5945ad77d9f0acc74a19d5e839dd2ae8e01c3dbee74f`; the process was alive after launch.
- Both builds used isolated DerivedData/OBJROOT/SYMROOT paths, so Xcode's shared locked `build.db` was untouched. No database or `.priors` error recurred.
- Remaining manual smoke: rotate the physical iPhone/iPad through active Practice/Capture, arm AHHH with Load/HC1 then move the right platter, and watch/listen to the macOS demo for subjective alignment. Nothing committed or pushed.

## 2026-08-29 — iPhone/iPad live notation is full-screen; Advanced HC1 AHHH is functional (uncommitted)

- Practice and both Capture camera paths now give the target/performance notation overlay the complete landscape safe workspace on iPhone and iPad. Do not reintroduce the previous 144–184-point height cap. Compact iPhone Home uses a minimum-width horizontal carousel and clears the tab bar; compact System Check details wrap.
- Advanced MIDI is no longer a read-only mock. It observes `IOSMIDIManager`, `IOSMIDILearnCoordinator`, `IOSMIDIControllerDispatcher`, and `IOScratchPlaybackEngine`; the user can select/refresh a source, apply the verified RANE mapping, learn/relearn HC1, assign `dvs_ahhh`, and explicitly load AHHH.
- HC1 dispatch intentionally calls the ungated `HotCueTriggerResolver.resolve(action:)`: Serato can own transport while ScratchLab listens to controller MIDI. A learned RANE HC1 automatically receives its default AHHH assignment. Sound is platter-driven—pressing Load/HC1 arms the sample, then right-platter movement produces audio.
- Figma file `AgrnQXwRvkAKlORTQ2U25z` was updated first: iPhone live HUDs, Advanced frame `416:4202`, iPad Capture `360:71`, and active iPad Practice `281:969` with HUD `436:2421` now match the full-screen behavior.
- Isolated generic iOS Simulator build succeeded with the embedded watch app; resolver tests passed 3/3; capture fixtures passed 47/47; `git diff --check` passed. Source-contract tests compile, but the sandboxed macOS host hung on project reads under `Downloads` and that run was interrupted. No iPad Simulator is installed, so final physical iPad landscape and RANE audio smoke remain.
- Nothing committed or pushed. Preserve unrelated dirty WIP and keep using isolated build roots while Xcode is open.

## 2026-08-29 — macOS Watch notation now follows the BBB demo audio; false click diamonds removed (uncommitted)

- Root cause: Practice Watch used the old 4.700-second canonical template while playing the new 16.048-second BBB demo, then applied modulo timing. It also drew a decorative diamond at every platter reversal, colliding with the chart's real fader-transition symbol.
- `MacAnalyzerView` now uses `ScratchNotation.babyScratchDemo` for Ready/Watch/Listen and uses the audio player's sampled time directly, clamped at the final movement through the two-second tail. Copy/scoring/review still use `ScratchNotation.babyScratch`.
- `ScratchPhraseChartView` no longer draws decorative platter-turnaround diamonds. Direction remains encoded by path slope and chevrons; fader OPEN remains visible; a transition diamond is retained only for a real fader-state change.
- Isolated macOS build/tests succeeded without touching Xcode's shared database: 11/11 Watch/live tests twice, 61/61 demo-notation tests, and 3/3 audio/motion/tail checks twice. `git diff --check` passed. Final manual eyes-and-ears playback approval remains.
- The stale `.priors` file was removed earlier, and all Codex build/test work used separate DerivedData/OBJROOT/SYMROOT paths; the `ReadError 15` and locked `build.db` did not recur. Do not run concurrent CLI and Xcode builds against the same build root.
- Nothing committed or pushed; preserve all unrelated dirty WIP.

## 2026-08-29 — explicit iOS Load AHHH restored after Karl's follow-up (uncommitted)

- Karl's later instruction supersedes the earlier Serato-listen-only/no-AHHH note below. Practice Controller Setup and Capture Hardware Setup now expose explicit `Load AHHH` actions with truthful status, and the verified Rane mapping owns local ScratchLab samples for this iOS test path.
- Restored the correct platter-ready `ScratchLab/Resources/VirtualPlatter/ahhh.wav` (1.047415 seconds; Git blob `2895220755832dff90d940789533bc7111041fb6`), not the padded 4.466667-second `ScratchSamples/ahhh.wav`.
- Existing sampleless Rane mappings are repaired without losing learned MIDI/calibration/custom sample IDs. iOS Simulator build passed; mapping tests 29/29 twice and the explicit-AHHH source contract passed twice.
- Physical iPhone/iPad + Rane Hot Cue 1 smoke remains. Nothing committed or pushed.

## 2026-08-29 — six missing Xcode binary resources restored; macOS/iOS builds green (uncommitted)

- Restored the exact tracked versions of four `ScratchSamples` WAVs (`ah_yeah`, `ahhh`, `check_it_out`, `fresh`), `ScratchLabDesktop/AppIcon.icns`, and `Resources/Coach/Coach.usdz` from the intact `ScratchLab-fix-stable-ios-audio-session-activation` checkout. Every source Git blob matched the destination index blob, so no binary content or Xcode project configuration changed.
- `ScratchLabDesktop` now builds/links on macOS and `ScratchLab` builds for the generic iOS Simulator. Capture fixtures passed 47/47. `scripts/build.sh` copied all six resources and linked before unrelated tests failed on other intentionally deleted WIP assets, including `chirpflare_noBeat.wav`; the long test run was then stopped. Preserve those unrelated deletions unless Karl explicitly expands scope.
- Nothing committed or pushed.

## 2026-08-29 — iOS adaptive views, BBB demo routing, cold-launch repair, and Serato-companion mapping COMPLETE (uncommitted)

### Root causes and result
- The new local Home/sidebar views existed but were unreachable; compact iOS omitted Home and used Capture/Review placeholders. They now route to the implemented Practice, Capture/Review, and Advanced flows, with a persistent sidebar on regular-width landscape iPad.
- iOS Demo preferred the old 42-second reel. Baby Demo and Demo + My Motion now select the exact 16.048-second BBB `baby_noBeat.wav` + 32-stroke motion resource at fixed 79 BPM before any legacy fallback.
- Static launch first named the full logo SVG and scaled it to fill; making it background-only then exposed a black-looking frame for the app's roughly 5–7-second cold initialization. It now uses a dedicated compact 240×240 launch logo, and `AppLaunchContainerView` renders the SwiftUI splash before constructing heavyweight root services.
- Serato cannot run on iPhone. The supported architecture is Serato on Mac/PC feeding audio/MIDI to ScratchLab on iPhone/iPad. Production iOS no longer shows or silently invokes AHHH loading; verified and manually learned RANE pad mappings are listen-only and carry no local ScratchLab sample IDs. Older saved mappings are normalized on load by stripping only pad sample IDs while preserving their MIDI/calibration fields. DEBUG Virtual Platter retains its own standalone AHHH test.

### Verification and remaining scope
- iOS device and Simulator builds succeeded; watchOS embedded build succeeded; macOS built through focused tests. Capture fixtures passed 47/47. Mapping tests passed 29/29 twice; adaptive-route/no-AHHH contracts passed twice; BBB lane tests passed 11/11 twice. Final bundle audio/motion hashes match the sources, and built launch configuration contains `LaunchBackground` plus `ScratchLabLaunchLogo`. A fresh iPhone 17 Pro simulator showed the compact logo at 0.5 seconds and Home at 7.5 seconds. New launch contracts compiled; the normal macOS test host could not read source under `Downloads`, and an unsandboxed retry stopped earlier on the unrelated pre-existing deleted `Coach.usdz` resource.
- `scripts/build.sh all`: 47/47 capture fixtures passed; desktop tests stopped on seven occurrences / six unique known dirty-WIP failures recorded in `DEV_LOG.md`; standalone builds completed target coverage.
- Latest saved Figma node is deleted. Exact latest-frame parity needs a current node-specific Figma URL. NDI/breakout overlay and iOS timecode test-side-app work were not implemented.
- Nothing committed or pushed. Preserve all unrelated dirty WIP.

## 2026-08-29 — BBB 79 BPM take cleaned and installed as the Baby Scratch demo

### Completed slice
- Treated Karl's “CCC” as the latest supplied BBB archive (`session_2026_08_29_bbb_baby_scratch_79_bpm.zip`); no CCC archive was present.
- `ScratchLab/Resources/CoachDemoAudio/baby_noBeat.wav` is now the dry BBB scratch-only performance: setup backward and two surplus cycles removed, 16 forward/backward cycles retained, +4 dB, two-second lead/tail, 48 kHz 16-bit stereo, 16.048313 s, SHA-256 `220a2d74568b91d580ab5945ad77d9f0acc74a19d5e839dd2ae8e01c3dbee74f`.
- `ScratchLab/Resources/CoachDemoMotion/baby_scratch_strokes.json` now carries the matching 32-stroke live timeline, and `NotationVisualizerView` uses it, eliminating the old audio/76-stroke visualization mismatch. Runtime constants, developer manifest, and all affected test contracts were updated.
- Focused demo timing/audio checks passed twice; `LiveNotationOverlayTests` passed 61/61; macOS/iOS simulator builds succeeded; iOS installed and launched on iPhone 17 simulator. See the top `DEV_LOG.md` entry for the final `scripts/build.sh` result.

### Still open
- Do a physical-device listening check before release. Capture-movement loss Phase 1/2 remains open and independent: a fresh hardware trace must exactly replay the live final count. Nothing was committed or pushed.

## 2026-08-29 — Take 009 movement replay diagnosed; corrected trace needs one new hardware take

### Current slice
- Selected the first unchecked `TASKS.md` item: Capture-movement loss Phase 1/2. Replayed `session_2026_08_29_platter_baby_scratch_95_bpm.zip` before making any detection-threshold or sampling change.
- Take 009 live diagnostics reported 48 final movements; exact offline replay produced 0. The first mismatch was the builder funnel: live 134 starts / 6 extensions versus replay 64 starts / 76 extensions.
- Root cause is a DEBUG evidence-wiring defect: the live builder received angular `processed.position`, but the trace stored the smoothed image/display X as `builderPoint`; brief misses also recorded a display point when the live builder received nil. Take 009 is therefore not exactly reconstructable after export.
- Corrected only the DEBUG trace wiring in `ScratchLabDesktop/Services/MacCaptureEngine.swift` and added an environment-gated real-hardware replay assertion in `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift`. No Release capture behavior, audio routing, thresholds, sampling, notation, schema, or Ableton Link integration changed.
- `TASKS.md` remains unchecked. The next required action is one fresh hardware take from this build, then run the replay test using the exported `debug/take-N_movement_trace.json` and `debug/take-N_movement_diagnostics.json`. Only after exact replay equals live may the true capture-loss stage and any fix be selected.

### Verification and repository state
- `MovementTraceDiagnosticsTests`: 20 executable tests passed in each configured test-plan run; the external-data test skips when paths are absent. Old Take 009 fails deliberately at exact 0 vs live 48, proving its trace is unusable for exact replay.
- `scripts/build.sh`: capture fixtures 47/47 and movement suites passed; the broad desktop plan exited 65 on the existing six UI/source-profile results documented in `DEV_LOG.md`. `git diff --check` is clean.
- Worktree remains heavily dirty with user WIP. This slice touched only `MacCaptureEngine.swift`, `CaptureReliabilityPhase1Tests.swift`, `TASKS.md`, `DEV_LOG.md`, and these handoff files. Nothing staged, committed, or pushed.
- Ableton Link recommendation: integrate shared Link tempo/phase as a future separately reviewed task, not as a claimed left-deck detector. Link has no deck identity; the operator must make Serato's left deck the Link/master reference. Canonical CXL recording should be scratch-only audio while the performer hears the beat in cue/headphones, with Link timing metadata and an optional separate beat-reference/evaluation stem.

## 2026-08-28 — MIDI Learn fixes + Rane ONE MKII operator docs COMPLETE; branch pushed — AWAITING PRODUCT-PRIORITY DECISION

### Repository state
- **Branch:** `feature/ios-capture-camera-ux`
- **Repository baseline:** `10f79db8` was the synchronized tip before this handoff; the handoff was then committed and pushed as `baa06fc9`. Run `git rev-parse HEAD origin/feature/ios-capture-camera-ux` for the live state.
- **Index is empty.** Nothing staged.

### Recent completed commits (all on this branch, pushed)
- `ce12fe0e` — MIDI Learn stale-value fix + cross-mapped-CC guard, with six regression tests in `MIDILearnEngineTests` (113/113 MIDI-suite pass).
- `e9fd591a` — DEV_LOG hardware / root-cause record.
- `37ec26c3` — TASKS completion record for the Rane ONE MKII MIDI Learn fix.
- `10f79db8` — operator documentation for the Rane ONE MKII channel-assign switch (`docs/dj_operator_quickstart.md`, `docs/session_checklist.md`; scoped `DEV_LOG.md` / `TASKS.md` entries only — 4 files, +34/−0).

### Verified hardware root cause (2026-08-28, live Rane ONE MKII)
- No CoreMIDI input-path defect. The **channel-assign switch above the fader must be fully left** before MIDI Learn; otherwise the mixer section transmits no MIDI at all — the upfaders and the normal (unshifted) hot-cue pads emit nothing. Only the crossfader and the SHIFT + pad layer transmit when the switch is not fully left.
- **Verified MIDI tuples** (single CoreMIDI source endpoint, switch fully left; 1-indexed channel, raw 0-indexed in parens):
  - Crossfader — `CC 8`, ch 16 (raw 15), value 0–127
  - Left upfader — `CC 28`, ch 1 (raw 0), value 0–127
  - Right upfader — `CC 28`, ch 2 (raw 1), value 0–127
  - Hot Cue 1 — `NoteOn` ch 6 (raw 5) note 20 / `NoteOff` note 20
  - Hot Cue 2 — `NoteOn` ch 6 (raw 5) note 21
  - SHIFT + Hot Cue 1 — `NoteOn` ch 16 (raw 15) note 50 (shift layer only)
  - Platter (not scored) — `CC 6` flood + 14-bit `PitchBend` flood, both ch 2 (raw 1)
- The MIDI Learn fixes and the operator documentation are **complete**.

### Pre-existing WIP — DO NOT TOUCH
- **34 modified files** + **1 untracked** `ScratchLabDesktopTests/CalibrationCameraOverlayTests.swift.plist` remain **local and unstaged**. This is a large in-flight iOS Companion Camera / capture-UX effort (e.g. `CompanionCameraView.swift` +3,489, `MainMenuView.swift` +1,770, `PracticeModeView.swift` +2,054, `MacAnalyzerView.swift` +2,790, `project.pbxproj` +910, `ScratchLab.xcscheme`) plus the in-flight `RaneOneMKIIVerifiedLearnedMapping` registry / iOS coordinator wiring. `DEV_LOG.md` and `TASKS.md` also still carry unstaged pre-existing WIP entries (only the scoped 2026-08-28 docs entries were committed).
- **Do not clean, revert, stage, or commit any of this WIP without an explicit, written scope.**

### Latest verification (docs-only task, commit `10f79db8`)
- `git diff --check` clean.
- `scripts/build.sh all`: capture-pipeline fixtures **47/47**; **zero compile errors**; the `xcodebuild` ScratchLabDesktop test plan stopped (via its own `set -e`) on **five pre-existing dirty-WIP test failures** — `testGuidedCaptureLandscapeHidesHelperTextDuringPreRoll`, `testGuidedCaptureSystemCheckScrollsOnSmallScreens`, `testLevelSelectSourceUsesSafeAreaAwareScrollableHeaderLayout`, `testPracticeSetupDoesNotRenderCoachCard`, `testRaneOneMkiiDebugPresetHasSetupNoteOtherPresetsDoNot`. These are source-slice / layout / byte-size assertions against dirty Swift files; a markdown-only change cannot cause them.

### No implementation-ready work queued
- Every section of `TASKS.md` (`Next Priority Sequence`, `Ready`, `Mapped Follow-up Tasks`, all "User Requested…" sections) is fully `[x]`. The only `- [ ]` items are:
  1. **Capture-movement loss — Phase 1/2** (`TASKS.md:136`): already implemented (DEBUG trace + `Codable` diagnostics + `MovementTraceReplay`, tests pass); unchecked only because **closure is hardware-validation-gated** — a real capture take must produce a trace for offline-vs-live loss classification.
  2. Keep playback override / notation routing off until approved — a standing guard rule, not a task.
  3. Optional non-Rane DVS hardware validation — optional, hardware-gated.
- **There is no implementation-ready unchecked task.**

### RESOLVED 2026-08-29 — product direction is multiplatform
- Product decision (2026-08-29): **ScratchLab remains multiplatform across macOS, iOS/iPadOS, and watchOS.** The 2026-08-12 "macOS-only" direction in `TASKS.md` is superseded.
- Already reversed in code: `1061dc33` (2026-08-15) restored the iOS/iPad target; `37f81c06` (2026-08-22) restored the `ScratchLabWatch` target. At repository baseline `baa06fc9` the iOS `ScratchLab` target, the `ScratchLabWatch` target, and `ScratchLab.xcscheme` are all present. `PROFILE.md` / `README.md` / `AI_CONTEXT.md` / `docs/**` already say multiplatform.
- `TASKS.md`, `DEV_LOG.md`, and `AI_HANDOFF/next_prompt.md` reconciled 2026-08-29 (docs only). The pre-existing 34-file WIP is consistent with the multiplatform direction but remains unreviewed and unapproved; it stays local, unstaged, and preserved. Any task selection against it needs a separate written per-slice scope.

### Stale-doc note
- Everything below this entry (2026-08-17 and earlier) refers to branch `feature/v3.2-swiftui-20260815` / commit `7efbb70` and does **not** describe current state. Preserved for history only.

---

## 2026-08-17 — V3.2 beta candidate COMMITTED `7efbb70` (NOT pushed) — AWAITING APPROVAL

Final beta-candidate preparation. Committed one clean commit `7efbb70`
(`V3.2: prepare App Store Connect beta candidate`) on `feature/v3.2-swiftui-20260815`.
**NOT pushed, NOT uploaded.**

### Commit hashes
- **`7efbb70` V3.2: prepare App Store Connect beta candidate** (this slice — 3 files, +200/−18)
- `ae2462b` V3.2: implement production Advanced workspace
- `797e087` V3.2: implement production Review workspace
- `d5043b0` V3.2: implement production Capture workspace
- `184b8d1` V3.2: implement cross-platform Practice workspace
- `0b85674` V3.2: reconcile cross-platform semantic colours
(Branch is `feature/v3.2-swiftui-20260815`, ahead 19 of origin.)

### What `7efbb70` contains
1. **B1** — Review target cards unified onto canonical registry (`reviewTargetReferenceNotation(for:)` +
   `reviewReferenceTargetCycles`; `reviewTargetNotationStageCard` + `reviewOverlayDiffStageCard`).
2. **B2** — `loadReviewMetadataForCurrentTake` now reloads `sidecar.reviewDecision` (relaunch persistence).
3. **B3** — removed the no-op destructive "Discard" button from `captureRecordCard`.
4. **Release compile fix** — `timecodePipeline` is `#if DEBUG`-gated; added Release-safe
   `dvsTimecodeMode`/`dvsTimecodeSignalHealth` (`.disabled`/`.noSignal` in Release) and re-pointed the six
   Release consumers (`advancedOverviewSummary`, `dvsSignalState`, `controllerMappingState`,
   `captureReadiness`, Overview timecode status). **This fixed the macOS Release archive failure.**
5. Regression tests: `RegistryDrivenComparisonSurfaceTests.reviewReferenceTargetCardUsesRegistry` (B1);
   `CrossWorkspaceFixRegressionTests` (B2/B3); `PrivacyAndPermissionRegressionTests` (quality audit).

### Archive results (both now SUCCEED — development signing)
- **iOS** `/tmp/ScratchLabiOS.xcarchive` — `ARCHIVE SUCCEEDED`, "Apple Development: Karl Watson" + iOS Team
  Provisioning Profile.
- **macOS** `/tmp/ScratchLabMac.xcarchive` — `ARCHIVE SUCCEEDED` (after the timecodePipeline fix), same dev signing.

### Verification this slice
iOS Release build ✓ · macOS Release archive ✓ · build-for-testing ✓ · `git diff --check` clean.
Focused suites: CrossWorkspaceFixRegressionTests 2/2, PrivacyAndPermissionRegressionTests 3/3,
SessionReviewMetadataTests 17/17, ReviewPresentationStateTests 12/12, RegistryDrivenComparisonSurfaceTests 5/5.

### EXACT remaining blockers (before TestFlight upload)
1. **Apple Distribution signing** — only two "Apple Development" identities present locally; no
   "Apple Distribution" cert. `xcodebuild -exportArchive` (method `app-store-connect`) needs it. Resolve in
   Xcode → Settings → Accounts (managed cert), or it is created at export time if the Apple ID permits.
2. **Pre-existing dirty files NOT in this commit** (preserved per instruction; review + commit before a real
   submission): `ScratchLab.xcodeproj/project.pbxproj`, `ScratchLab.xcscheme`, and the AppIcon/Logo assets
   (iOS + watch + `ScratchLabDesktop/AppIcon.icns`). The archives above were built from the working tree
   (they include the dirty icons), but `7efbb70` does NOT carry them — checking out cleanly reverts icons.
3. **Hardware/manual verification** — see matrix below (all pending).

### Hardware test matrix (all pending)
1. Practice: open → listen/copy → result (WATCH/COPY/RESULT) on macOS + iPhone/iPad.
2. Capture: configure session → record → stop/save (has-take states, finalizing/issue/complete).
3. Review: open → correct/confirm label → export ZIP (confirmation/correction/export states).
4. Advanced: diagnose hardware (DVS/MIDI/camera) → return to another workspace without losing session state.
5. Camera/mic permission grant AND denial → Settings recovery (both platforms).
6. DVS/MIDI hardware (RANE ONE MKII CC6 platter; DDJ-GRV6 crossfader) → readiness states.
7. Companion camera + Performer Monitor over local network (Bonjour).
8. 1440×900 / 1280×800 layout eyeball; VoiceOver + Dynamic Type pass on primary flows.

### Rollback notes
- Un-push the commit (safe): `git reset --soft HEAD~1` (keeps changes staged) or `git reset --mixed HEAD~1`
  (keeps working tree, unstages). Since it is NOT pushed, `git revert 7efbb70` also works but leaves a revert commit.
- The commit only touches 3 source/test files; the dirty `project.pbxproj`/`xcscheme`/icons are untouched, so
  a reset does not disturb them.

### Commands Karl should run before upload
1. Push (auto-classifier may block; use the user-shell `!` form): `! git push origin feature/v3.2-swiftui-20260815`
2. Review + commit the pre-existing dirty assets (`project.pbxproj`, `xcscheme`, app icons) if intended.
3. Export a distribution archive (requires Apple Distribution cert):
   `xcodebuild -exportArchive -archivePath <xcarchive> -exportOptionsPlist <plist with method=app-store-connect>`
4. Upload via **Xcode Organizer "Distribute App"** (or the **Transporter** app). Do NOT use
   `xcrun altool --upload-app` — Apple deprecated altool's upload path and it misreports under Xcode 26.
   (`xcrun notarytool` is for Developer ID notarization outside the App Store — not this flow.)

**Stop:** Awaiting Approve Beta Upload.

---

---

## 2026-08-17 — ASC/TestFlight preflight (no upload) — AWAITING APPROVAL

Read-only ASC/TestFlight preflight. No upload/push/signing change. Result: **NO-GO for macOS** — the
macOS target does not compile in Release; iOS archives cleanly.

**Config (inspected):** `MARKETING_VERSION 1.0.1`, `CURRENT_PROJECT_VERSION 18`, bundle id
`com.machelpnz.scratchlab` (shared macOS/iOS), team `2DDKGL33BU`, `CODE_SIGN_STYLE=Automatic`.
Deployment targets: macOS 15.0, iOS 26.x. macOS entitlements complete (sandbox + camera + audio-input +
network client/server + user-selected file). iOS: no entitlements (none needed). Debug flags correct
(`ENABLE_TIMECODE_LIVE_TAP` Debug-only; `-O` Release; `ENABLE_TESTABILITY` Debug-only). Both schemes
archive with `Release`. Export compliance `ITSAppUsesNonExemptEncryption=false`. Privacy manifest +
permission strings verified (prior audit). App icons present (modified, uncommitted).

**Build results:**
- **iOS Release build ✓** and **iOS Release archive ✓** (`ARCHIVE SUCCEEDED`, dev signing
  "Apple Development: Karl Watson" + iOS Team Provisioning Profile). `/tmp/ScratchLabiOS.xcarchive`.
- **macOS Release archive ✗** — 16 compile errors, single root cause: `timecodePipeline` is `#if DEBUG`
  (`MacAnalyzerView.swift:670-709`, def at `:693`) but referenced by UNGUARDED Release code. PRE-EXISTING
  (my B1/B2/B3 + quality-audit changes touch 0 of these lines). Scope of the blocker (Release consumers):
  `advancedOverviewSummary` (`:4905-4906`), `dvsSignalState` (`:4917`), `controllerMappingState` (`:4930`),
  `captureReadiness` (`:5460`), and the Overview card timecode status (`:2368`). Fix direction: Release
  fallbacks (DVS mode `.disabled`, health `.noSignal`) for those six sites — since `ENABLE_TIMECODE_LIVE_TAP`
  is Debug-only, DVS/timecode is legitimately OFF in Release.

**Signing note (not a code blocker):** only two "Apple Development" identities present locally; no
"Apple Distribution" cert. iOS archive signs for Development; TestFlight/App Store export would require
"Apple Distribution" signing (account-managed, created at export time if the Apple ID permits).

**Focused tests:** `PrivacyAndPermissionRegressionTests` 3/3, `CrossWorkspaceFixRegressionTests` 2/2,
`RegistryDrivenComparisonSurfaceTests` 5/5, `SessionReviewMetadataTests` 17/17, `ReviewPresentationStateTests`
12/12 (all green; run via `xcrun xctest` dylib-symlink recipe).

**Go/no-go:** NO-GO — macOS Release compile blocker (above) is the only hard blocker. Manual hardware
tests still pending (real take → Review/export; camera/mic grant+denial; DVS/MIDI; companion/performer
monitor; 1440×900/1280×800; VoiceOver/Dynamic Type).

**Stop:** Awaiting Approve ASC Beta Candidate.

---

---

## 2026-08-17 — V3.2 quality audit (a11y/perf/privacy/permission) — AWAITING APPROVAL

Read-only quality audit across the implemented scope (macOS Practice/Capture/Review/Advanced + iOS/iPad
Practice/Advanced). **No beta blockers found — privacy/permission posture is solid.** No production code changed
this slice; added a regression suite to lock in the verified invariants. NOT committed.

**Verified solid (with evidence):**
- **Usage descriptions** present + truthful on both targets (`NSCameraUsageDescription`/`NSMicrophoneUsageDescription`/
  `NSLocalNetworkUsageDescription` in `ScratchLab/Info.plist` + `ScratchLabDesktop/Info.plist`).
- **Privacy manifests** (`ScratchLab/PrivacyInfo.xcprivacy` + `ScratchLabDesktop/…`): `NSPrivacyTracking=false`,
  `NSPrivacyCollectedDataTypes` empty, required-reason API categories present (UserDefaults CA92.1,
  FileTimestamp 0A2A.1, SystemBootTime 35F9.1).
- **No third-party analytics/services.** `SessionUploadManager` cloud upload is Release-disabled
  (`SessionUploadConfiguration.current()` → `#if !DEBUG` returns `apiBaseURL: nil`); only reachable via
  DEBUG env `SCRATCHLAB_UPLOAD_API_BASE_URL`. Consistent with "session results stay on device."
- **Permission denial/recovery** present: `AVCaptureDevice.authorizationStatus` denied/restricted branches +
  settings deep-link (`UIApplication.openSettingsURLString` iOS; `NSWorkspace`/`x-apple.systempreferences` macOS).
- **Local network**: pre-prompt rationale (`localNetworkRationaleAccepted`) + `NSBonjourServices`
  (`_scrcamfeed._tcp`, `_scrmonfeed._tcp`) declared.
- **Reduce Motion** honored on the animation-heavy surfaces (`ScratchMotionLane`, macOS Practice playhead).
- **VoiceOver**: ~112 accessibility labels/hints, no unlabeled icon-only buttons.
- **Capture pipeline threaded** off-main (`sessionQueue`/`videoQueue`/`audioQueue`/`finalizationQueue` in
  `MacCaptureEngine`).

**Regression tests added (`PrivacyAndPermissionRegressionTests`, 3/3 green, in ScratchNotationPanelTests.swift):**
usage descriptions on both platforms; privacy manifests (no tracking/collection + required reasons);
cloud upload Release-disabled. Builds: macOS build-for-testing ✓, `git diff --check` clean.

**Follow-ups (deferred, NOT beta-blocking):**
1. **Dynamic Type** — design system uses fixed `.system(size:)` throughout; supporting it is a typography
   redesign that would break Figma pixel-parity (out of scope).
2. **`print` diagnostics in Release** — a handful log file paths/device names (user's own machine data);
   convert to `Logger` with `.private` or gate `#if DEBUG` in a hygiene slice.
3. **`reviewPerformanceComparison` + `resolvedOverlayAndDiagnostics` recompute on every Review body eval**
   (no Release cache) — moderate, low-frequency (only on take-load/session/tab change).
4. **`rescanRoutineCaptures` sync disk I/O on main thread** (launch/session switch).
5. **`.controlSize(.small)` sub-44pt controls** in Advanced/diagnostic surfaces.
6. **Splash logo animation** ignores Reduce Motion (one-shot 1.5 s).

**Stop:** Awaiting Approve Quality Audit.

---

---

## 2026-08-17 — V3.2 cross-workspace fixes (B1/B2/B3 beta blockers) — AWAITING APPROVAL

Implemented the three beta blockers from the approved Cross-Workspace Fix List. NOT committed (per rule).
No redesign, no engine/export/schema change, no pbxproj edit. Production owners preserved.

**B1 — duplicated target-notation source of truth (FIXED).** Added `reviewTargetReferenceNotation(for:)`
+ `reviewReferenceTargetCycles = 8`; both Review target cards now resolve through the canonical registry
(`canonicalBeatPattern` → `TargetScratchPhrase` → `materializedNotation`): `reviewTargetNotationStageCard`
(`MacAnalyzerView.swift:6790`) and `reviewOverlayDiffStageCard` (`:7348`). The legacy `ScratchNotation.babyScratch`
(~5 s excerpt, pre-canonical "baby" ID) is gone from BOTH Review target cards; `reviewTargetVsPerformedStageCard`
was already canonical. **Deferred:** macOS Practice still uses `babyScratchFull76BeatQuantized ?? babyScratch`
(`:1199`) vs iOS/iPad `canonicalBeatPattern` — a cross-platform *teaching-model* decision, not a same-screen
contradiction; changing it would redesign the approved Practice surface.

**B2 — Review label decision not restored after relaunch (FIXED).** `loadReviewMetadataForCurrentTake` (`:4475`)
now also reloads `sidecar.reviewDecision` into `reviewDecisionStatusByTakeID` (always) +
`reviewDecisionByTakeID` (when the label maps to a `ReviewCorrection`). Header badge + summary now agree with the
persisted sidecar after relaunch, matching export/artifact-status.

**B3 — "Discard" no-op destructive button (FIXED).** Removed the `Button("Discard")` that called `prepareRetake()`
(identical to "Record another", no discard, no confirm). `captureRecordCard` action row is now "Save take" +
"Record another"; comment updated to note takes are preserved, never deleted from this surface. (`prepareRetake`
still used by the accurately-labeled "Retake"/"Record another" buttons.)

**Regression tests (3 new, all green):**
- `RegistryDrivenComparisonSurfaceTests.reviewReferenceTargetCardUsesRegistry` (B1, Swift Testing) — 5/5 suite.
- `CrossWorkspaceFixRegressionTests` (B2/B3, XCTest, appended to ScratchNotationPanelTests.swift) — 2/2.
Adjacent suites re-verified: `SessionReviewMetadataTests` 17/17, `ReviewPresentationStateTests` 12/12.

**Gates:** iOS build ✓, macOS build ✓, macOS build-for-testing ✓, `git diff --check` clean.

**Deliberately deferred (follow-ups, NOT in this fix list):** "Save take" no-op (F1), stale
`capturedNotationSnapshot` in Advanced Overview (F2), macOS Practice hardcoded to Baby Scratch (F3), and the
Practice cross-platform target model (part of B1). Hardware-verification items unchanged.

**Stop:** Awaiting Approve Integration Fixes.

---

---

## 2026-08-17 — V3.2 cross-workspace audit (READ-ONLY, no fixes) — AWAITING APPROVAL

Read-only cross-workspace audit of Practice → Capture → Review → Advanced on every implemented
platform (macOS all four; iOS/iPad Practice + Advanced only — mobile Capture/Review still FUTURE).
No code/Figma/Code Connect changed. Nothing staged/committed/pushed.

**Findings ranked (awaiting "Approve Cross-Workspace Fix List" before any fix):**

- **BETA BLOCKER — duplicated target-notation source of truth.** Baby scratch has 5 distinct
  `ScratchNotation` sources (`CaptureCore.swift`): `babyScratch` (2670, ~5s excerpt, legacy "baby"),
  `babyScratchDemo` (2689), `babyScratchFull76` (2700), `babyScratchFull76BeatQuantized` (2723),
  `babyScratchCycle` (3010, canonical, via `canonicalBeatPattern` 3034). Consumers disagree:
  macOS Practice → `babyScratchFull76BeatQuantized ?? babyScratch` (`MacAnalyzerView.swift:1199`,
  BPM 79); macOS Review "Target notation" card → `babyScratch` (`:6767`); macOS Review
  "Target vs performed" card → `babyScratchCycle` (`:6894`); iOS/iPad Practice → `babyScratchCycle`
  (`PracticeModeView.swift:174-177`). Same workspace + same technique show different targets.
- **BETA BLOCKER — Review label decision not restored after relaunch.** `loadReviewMetadataForCurrentTake`
  (`MacAnalyzerView.swift:4475`) reloads only `sidecar.reviewMetadata`, NOT `sidecar.reviewDecision`.
  In-memory `reviewDecisionByTakeID`/`reviewDecisionStatusByTakeID` (`:651-652`) start empty and are
  only set by `persistReviewDecision` (`:4285`). After relaunch `reviewPresentationState` (`:3833`) and
  `reviewLabelDecision` (`:7416`) show READY/Pending while export (`SessionExportCoordinator.swift:2255`)
  + artifact status (`MacCaptureEngine.swift:6006`) still read the persisted decision.
- **BETA BLOCKER — "Discard" is a no-op destructive button.** `captureRecordCard` "Discard" (`:5767`)
  and "Record another" (`:5759`) both call `prepareRetake()` (`:4186`) which only reports
  "Retake selected… previous take remains stored" + `workspaceTab = .capture`. No discard, no confirm,
  no delete-take path exists.
- **FOLLOW-UP — "Save take" is a no-op.** `markLastTakeSaved()` (`:4168`) emits only a status string;
  take already persisted on stop.
- **FOLLOW-UP — stale `capturedNotationSnapshot` in Advanced Overview.** Set once by Review "View
  captured notation" (`:6180`), never cleared; `NotationVisualizerView(capturedSnapshot:
  capturedNotationSnapshot ?? currentRoutineNotationSnapshot)` (`:2355`) shows a prior take's notation
  after recording a new one until relaunch.
- **FOLLOW-UP — macOS Practice target hardcoded to Baby Scratch** (`:1188`, `:1199`, `:1301`), ignores
  `routineSessionSetup.scratchType`. Consistent with "only baby_scratch is safe-to-author", stated.
- **FOLLOW-UP / structural — mobile Capture/Review absent.** `CapturePlaceholderView`/`ReviewPlaceholderView`
  (`MainMenuView.swift:275,317`) `private`+unreferenced; mobile flow = Practice + Advanced hub only.

**Passed (no finding):** navigation graph via TabView + explicit buttons; back nav (macOS tabs,
mobile `dismiss()`/nav-back); session continuity (`synchronizeSelectedRoutineSession` + `preferredSessionID`
filter correctly re-scopes take; fresh session clears `hasRecordedTake`); single shared `MacCaptureEngine`
(no duplicated hardware state); window restoration via `@AppStorage("scratchlab.mac.workspaceTab")` +
`advancedSection` + `WorkspaceTab.resolved(from:)` legacy-value mapping; no URL deep links (only
`MacWorkspaceRouting.showRoutineCapture()` Command+N).

**HARDWARE VERIFICATION (deferred):** has-take states (recording/finalizing/issue/ready/confirmed/
exporting/exported/failed) + 1440×900/1280×800 rendering need a real recorded take + camera/controller;
DVS/MIDI/audio transitions across workspace switch need hardware.

**Stop:** Awaiting Approve Cross-Workspace Fix List.

---

---

## 2026-08-16 — V3.2 final Review audit — COMMITTED `797e087` (not pushed)

Final Review audit clean, committed `797e087` (`V3.2: implement production Review workspace`, 4 files,
+122/−13) on `feature/v3.2-swiftui-20260815`. NOT pushed. Only the 4 intentional Review files staged;
pre-existing dirty `project.pbxproj`/`xcscheme` + handoff preserved uncommitted.

Audit confirmations:
- **Mutation safety**: Review reads captured notation; correction/confirmation writes only the sidecar
  JSON (`reviewed`/`withReviewMetadata` copy + set `reviewDecision`/`reviewMetadata`, never
  `detectedNotation`); media (audio/video) untouched; export creates an archive without mutating source.
- **Cross-platform notation**: `ScratchPhraseChartView` single definition, dual-target (macOS + iOS
  pbxproj build-files); `ScratchNotationPanel`/`ScratchNotationComparisonPanel` shared — no fork.
- **A11y/robustness**: accessibilityLabel/Hint/traits on the notation panel; catch-based error recovery
  (sets `reviewStatusMessage`); atomic sidecar writes; export button gated (disabled without a take /
  while recording / while exporting).

Gates: macOS build ✓, iOS build ✓, build-for-testing ✓, `git diff --check` clean.
Tests: ReviewPresentationStateTests 12/12, SessionReviewMetadataTests 17/17, ScratchNotationPanelTests
9/9, ScratchPhraseChartComparisonDomainTests 5/5, ScratchLabDesignTokensTests 21/21,
SessionExportRoundTripTests 1/1, ScratchLabNotationAndExportTests 27/29 (2 PRE-EXISTING source-string
failures reading deleted files `AIBattleModeView.swift`/`FormulaPlaygroundView.swift`, not Review).

Separated evidence:
- **Automated** (done): builds, tests, mutation-safety, cross-platform, a11y, error recovery.
- **Hardware/manual** (deferred): the has-take states (recording/finalizing/issue/correction/
  confirmation/playback/exporting/success/failure) need a real recorded take + camera/controller;
  visual 1440×900/1280×800 + screenshots BLOCKED (Screen Recording TCC permission absent this session).

**Approved by Karl 2026-08-16.** Review implementation accepted — committed `797e087`, not pushed.

---

---

## 2026-08-16 — V3.2 mobile Review capability gate — BACKEND GAP (no code)

Read-only gate for mobile (iPhone/iPadOS) Review. **Verdict: NOT supported — the primary mobile
Review backend paths do NOT exist.** No decorative UI implemented (would be a fake workflow). The
honest "coming soon" state is already in place and correct.

Per-owner gate (verified against code):
- **Saved-take** ❌ — `RoutineSessionStore` (`CaptureCore.swift:5202`) is shared but has NO iOS
  consumer; no primary iOS take recorder (`MacCaptureEngine` is macOS-only; iOS has only
  `CompanionCameraBroadcaster` companion/secondary).
- **Playback** ❌ — no iOS take-playback owner (`SessionExportReplayTake` is export-schema data, not
  a playback engine).
- **Correction** ❌ — `CaptureReviewDecision` model shared (`CaptureCore.swift:5660`) but the action
  (`correctReviewLabel`/`persistReviewDecision`) is macOS-only in `MacAnalyzerView`.
- **Confirmation** ❌ — `acceptReviewLabel`/`reviewDecisionByTakeID` macOS-only.
- **Export wired to Review** ❌ — `SessionExportCoordinator` shared (used in `MainMenuView.swift:576`,
  `CompanionCameraView.swift:9`) but no mobile Review screen to wire it to.

Mobile Review screen: `ReviewPlaceholderView` (`MainMenuView.swift:317`) is the only mobile Review
view — `private` + unreferenced, honest copy ("On-device Review is coming. Full take review currently
runs on the ScratchLab Mac app."). No mobile `reviewWorkspace`/`reviewStage`; no Review navigation
route (Home card list retired per Figma-approved Home; footnote "Capture and Review are intentionally
absent until implemented"). Shared `ScratchNotationComparisonPanel` CAN render TARGET+PERFORMANCE but
no mobile screen feeds it captured evidence.

**Honest state already in place** — Review is absent from production mobile Home (Figma-approved), the
honest placeholder is retained, no fake workflow exists. No code change warranted; adding decorative
mobile Review UI would fake a completed workflow (same verdict as the mobile Capture gate).

**Exact backend gap before mobile Review can be real:** (1) primary mobile take recorder, (2) mobile
`saved-take` store consumer, (3) mobile take playback, (4) mobile correction/confirmation actions +
persistence, (5) a mobile Review screen to wire `SessionExportCoordinator` + `ScratchNotationComparisonPanel`.

**Validation:** N/A — no mobile Review implemented. Size/Dynamic Type/VoiceOver/hit-target/safe-area
validation applies only to the "supported" branch.

**Approved by Karl 2026-08-16.** Mobile Review gate accepted (backend gap, no code).

---

---

## 2026-08-16 — V3.2 macOS Review presentation — AWAITING APPROVAL

Implemented macOS Review from the approved anchors. The hierarchy was already correct (`64b5a58`):
`reviewCompletedTakeStageCards` leads with `reviewTargetVsPerformedStageCard` (comparison + coaching)
→ `reviewSummaryFooterCard` (summary) → "Technical evidence & diagnostics" disclosure (target /
captured / overlay-diff / audio-onset). No hierarchy change needed.

**`MacAnalyzerView.swift` — surfaced the label decision + truthful export status in the summary:**
- `reviewLabelDecision` — maps `reviewDecisionStatusByTakeID[reviewTakeID]` to Confirmed (green) /
  Corrected (cyan) / Unknown / Pending. Mirrors `reviewPresentationState` so the summary cannot
  contradict the header badge (corrected ≠ confirmed).
- `reviewExportMetric` — maps `sessionExportCoordinator.state` to Exporting (cyan) / Exported (green) /
  Export failed (red) / Ready / Pending. Previously the footer hardcoded "Ready" from artifact
  readiness even mid-export.
- `reviewSummaryFooterCard` gained a "Label" metric (6 metrics: Target / Detected / Signal confidence /
  Label / Source / Export).

Uses existing owners only (`reviewDecisionStatusByTakeID`, `sessionExportCoordinator.state`, existing
`acceptReviewLabel`/`correctReviewLabel`/`shareLastRoutineSession`). No new services. Audio/video files
untouched (label correction persists to the sidecar JSON only).

**Verification:** macOS build ✓, build-for-testing ✓, `git diff --check` clean. Focused suites green:
ReviewPresentationStateTests 12/12, SessionReviewMetadataTests 17/17, ScratchNotationPanelTests 9/9,
ScratchPhraseChartComparisonDomainTests 5/5, ScratchLabDesignTokensTests 21/21.

**Visual validation at 1440×900 / 1280×800 — DEFERRED (environment-blocked).** The app launches
without crash (process running), but the session lacks Screen Recording TCC permission, so the main
window could not be captured (CGWindowList returns redacted/absent window data; full-screen screenshots
show the terminal, not the app). The has-take summary-footer change additionally needs a real recorded
take (HARDWARE REQUIRED — no take persists in the current session) before its pixels can be eyeballed.
Notation markers / rails / joins / overlays are unchanged by this slice (no renderer edit).

**Approved by Karl 2026-08-16.** macOS Review presentation accepted — nothing committed.

---

---

## 2026-08-16 — V3.2 Review state model (pure adapter + tests) — AWAITING APPROVAL

Implemented ONLY the pure Review presentation adapter + notation-comparison tests. No screen
re-layout, no detection/capture/export algorithm change, nothing committed.

**`CaptureCore.swift` — `ReviewPresentationState` now has a distinct `.corrected`:**
- Added `.corrected` (label "CORRECTED", variant `.info`/cyan — informational, never green).
- `ReviewPresentationInput.isConfirmed: Bool` → `decisionStatus: CaptureCore.CaptureReviewDecision.Status?`.
- `derive` maps `.accepted`→`.confirmed`, `.corrected`→`.corrected`, `.unknown`/`nil`→`.ready`.
  Confidence is NOT part of the input — detection confidence stays informational, never a
  confirmation trigger.

**`MacAnalyzerView.swift` — adapter wiring only (no layout):**
- Added `reviewDecisionStatusByTakeID: [String: CaptureReviewDecision.Status]`, set in
  `persistReviewDecision`, read in `reviewPresentationState` (`decisionStatus:`).
- Fixes audit gap #2: "Correct label" now shows CORRECTED (not CONFIRMED); "Leave unknown" now
  shows READY (not CONFIRMED).

**Tests (all green via `xcrun xctest`):**
- `ReviewPresentationStateTests` 12/12 (+5: corrected-distinct, unknown-not-confirmed,
  correction/confirmation order, export failure-overrides-success, export-requires-take).
- `ScratchLabDesignTokensTests` 21/21 (+2: trace identity distinct, empty events → no preview).
- `ScratchPhraseChartComparisonDomainTests` 5/5 (+1: performed-past-target-end overflow, no rescale).
- `ScratchNotationPanelTests` 9/9 (unchanged). Lane-label test extended
  (`.targetReference.performanceLabel == "MY PERFORMANCE — CAPTURED"`).

**Gates:** macOS build ✓, iOS build ✓, build-for-testing ✓, `git diff --check` clean.

**Stop:** Awaiting Approve Review State Model.

---

## 2026-08-16 — V3.2 Review ownership map (READ-ONLY audit) — APPROVED

Read-only Review ownership audit (no code/Figma/Code Connect edits). Mapped the 10 requested
Review states (empty · recording/finalizing · processing · issue · ready · label-correction ·
confirmed · exporting · export-success · export-failure) plus the 8 data concepts to real owners.

**State owners (macOS `MacAnalyzerView.reviewStage` `:6465` is the only real Review surface):**
- empty → `currentRoutineArtifactStatus == nil && !hasRecordedTake` (`:3780-3784`) → `.empty`/`.noTake`.
- recording → `captureEngine.isRoutineRecording` (`:3776`); finalizing → `currentRoutineArtifactStatus.readiness
  == .finalizing` OR `hasRecordedTake && status == nil` (`:3780-3784,3793`).
- issue → `TakeArtifactReadiness.missingAudio/.missingVideo/.failed` (`:3795-3810`).
- ready → `TakeArtifactReadiness.ready` (`:3789`).
- confirmed → `reviewDecisionByTakeID[reviewTakeID] != nil` (any persisted decision; see gap 2) (`:3831`).
- exporting → `sessionExportCoordinator.isPreparing` (`:3832`); export-success → `.state ∈
  {.readyToShare,.presentingShareSheet,.shareCompleted}` (`:3833-3838`); export-failure →
  `.state == .failed` (`:3839-3842`).
`derive` precedence (`CaptureCore.swift:6851`): recording → finalizing → issue → no-take →
exporting → exportFailed → exported → confirmed → ready. Green only confirmed/exported (`:6821`).

**Data-concept owners (separate from state):** target notation = `canonicalBeatPattern(forScratchID:)`
(`CaptureCore.swift:3034`) → `materializedNotation`; captured performance =
`currentRoutineNotationSnapshot.recordMovementEvents` (`MacAnalyzerView.swift:3457-3459,6935`);
playback position = `playheadTime` (comparison card is STATIC, no animated playhead);
detected label = `currentRoutineArtifactStatus?.detectedLabel ?? lastScratchDetection?.scratchName`;
confidence = `labelConfidence ?? lastScratchDetection?.confidence`; correction =
`correctReviewLabel()`→`persistReviewDecision(.corrected)` + `CaptureReviewMetadata.labelOverride`;
confirmation = `acceptReviewLabel()`→`.accepted` + `approveSession()`→`SessionReviewState.approved`;
export URL/service = `SessionExportResult.archiveURL` + `SessionExportCoordinator.state`.

**Review consumes saved Capture output (NOT synthetic) — CONFIRMED.** Captured performance is
`detectedNotation`/`lastRoutineDetectedNotation` snapshot, hard-requires non-empty
`recordMovementEvents`; target is the canonical registry pattern materialized at session BPM.

**iPhone/iPad Review frames — NONE backed by real paths.** `ReviewPlaceholderView` (`MainMenuView.swift:317`)
private + unreferenced; no mobile reviewWorkspace; the only mobile `.review` is a camera state
(`CompanionCameraView.swift:350`). `ScratchNotationComparisonPanel` is shared but no mobile screen
feeds it captured evidence. Mobile Review = FUTURE.

**Shared time domain (TARGET + MY PERFORMANCE) — CONFIRMED.** `reviewTargetVsPerformedStageCard`
(`:7054`) draws both charts from one `domain = ScratchPhraseChartComparisonDomain.commonDomain`
(`ScratchPhraseChartView.swift:967`), `performedFrame` = target `rawRange`; deterministic `normalizedX`.

**Gaps (flagged, not faked):**
1. `processing` = spec/Figma word with NO code equivalent — split between `.finalizing` (take) and
   `SessionExportState.preparingArchive` (export). Needs a decision which it means.
2. `label-correction` has NO distinct badge — `isConfirmed` folds accepted AND corrected into
   `.confirmed` (`:3831`); correction is indistinguishable from confirmation in the header.
3. Two target sources: `reviewTargetNotationStageCard` uses bundled `ScratchNotation.babyScratch`
   demo (`CaptureCore.swift:2670`), while `reviewTargetVsPerformedStageCard` uses canonical
   `babyScratchCycle` (`CaptureCore.swift:3010`).

**Approved by Karl 2026-08-16.** Read-only audit accepted — no code/Figma/Code Connect
changed. The three flagged gaps remain OPEN decisions (not resolved by this approval) and must be
pinned before any Review implementation slice: (1) `processing` has no code state; (2)
`label-correction` has no distinct badge; (3) two target sources (bundled demo vs canonical cycle).
**Stop:** awaiting the next phase/spec (Review implementation or gap decisions). Do NOT start Advanced.

---

## 2026-08-16 — V3.2 Capture implementation COMMITTED `d5043b0`

Final Capture audit clean, committed `d5043b0` (`V3.2: implement production Capture workspace`,
3 files, +283/−172) on `feature/v3.2-swiftui-20260815`. NOT pushed.

Audit confirmations: no engine/export file changed (only `CaptureCore.swift` + `MacAnalyzerView.swift`
+ `ScratchNotationPanelTests.swift`); no fake hardware claims; standard camera preview is clean
(no pill/scrim/`DeckGamificationOverlay` — those remain only in Advanced `deckMonitorContent`);
`git diff --check` clean; only the 3 source files staged (handoff + pre-existing dirty
`project.pbxproj`/`xcscheme` preserved uncommitted).

Gates: iOS build ✓, macOS build ✓, build-for-testing ✓. Tests: `CaptureReadinessTests` 14/14,
`VisionCaptureGateTests` 18/18, sibling suites green; `CameraNotationOverlayTests` 14 failures =
pre-existing bundled-resource env ("Baby Scratch notation must load from bundle").

Runtime (code-only evidence, no capture hardware this session): app launches clean; OCR of Capture
tab confirms 6-stage stepper + metadata strip + setup message + "Camera / visual guide" disclosure
rendering the clean "Deck Camera" preview. HARDWARE-ONLY checks (record/finalizing/failed/
complete + camera permission grant) deferred — need a real take + camera.

Deferred mobile states (unchanged): mobile Capture/Review remain FUTURE (no primary recording/
DVS/MIDI/review engine — see backend-gap entry below).

**Stop:** Awaiting Approve Implementation Capture.

---

## 2026-08-16 — V3.2 mobile Capture capability gate — BACKEND GAP (no code)

Read-only capability gate for mobile Capture. **Verdict: the primary mobile Capture backend
paths do NOT exist.** No decorative UI implemented (would be a fake workflow). Documented
designed-but-deferred Figma frames below.

Per-capability owners (evidence):
- **Recording** ❌ — `MacCaptureEngine` (`ScratchLabDesktop/Services/MacCaptureEngine.swift`,
  macOS-only) is the only take recorder. iOS has `CompanionCameraBroadcaster`
  (`ScratchLab/Services/CompanionCameraBroadcaster.swift`, `import UIKit`+MultipeerConnectivity)
  = companion/secondary angle only (`storageKind: .companion`, relays frames to Mac over
  MultipeerConnectivity). `AudioEngine` (`ScratchLab/Audio/AudioEngine.swift`) is Practice
  scratch-motion analysis (mic → motion), not a take recorder. No primary iOS take engine.
- **DVS/timecode** ❌ — `TimecodeControlPipeline` (`ScratchLab/Models/TimecodeControlPipeline.swift`,
  shared) is fed live audio only by `MacCaptureEngine` (macOS); iOS uses it only in offline
  `SeratoControlVinylAnalyzer`. No live iOS audio→timecode path.
- **MIDI/controller** ❌ — CoreMIDI input (`MIDIClientCreate`/`MIDIInputPortCreateWithBlock`) is
  macOS-only in `MacCaptureEngine.swift:8907`. `MIDIHardwareRegistry`/`ControllerProfileCatalog`
  (`ScratchLab/Models/ControllerInput/**`) are data-only shared models; no iOS MIDI input engine.
- **Session persistence** 🟡 — shared models exist (`CaptureSessionConfig`/`SessionSetupViewModel`
  with `LocalRecordingSurface.iosCompanion`/`macRoutine`, `SessionExportCoordinator` in
  `CaptureCore.swift`/`SessionExportCoordinator.swift`), but `RoutineSessionStore` has NO iOS
  consumer (used only in `MacAnalyzerView.swift`/`ScratchLabDesktopApp.swift`); iOS persistence is
  companion-camera sidecar only.
- **Review handoff** ❌ — macOS `MacAnalyzerView` reviewWorkspace only; iOS `ReviewPlaceholderView`
  (`MainMenuView.swift:317`) is unreferenced (Review = FUTURE).

Designed-but-deferred Figma frames: iPhone Capture 6 (`269-156`/`269-204`/`269-289`/`269-364`/
`269-433`/`269-504`); iPadOS Capture 9 (`284-1364`/`284-1408`/`284-1451`/`284-1551`/`284-1625`/
`284-1690`/`284-1742`/`284-1811`/`284-1856`). Do NOT implement until a primary mobile engine exists.

**Stop:** Awaiting Approve Mobile Capture.

---

## 2026-08-16 — V3.2 macOS Capture implementation — AWAITING APPROVAL

Implemented macOS Capture only, driven by the approved `CaptureReadiness` adapter. No engine/
file/export changes, no pbxproj, no Figma/Code Connect, nothing committed. `MacAnalyzerView.swift` only.

**Staged flow (6 stages, single authority):**
- `CaptureStage` 4→6 cases: setup(1)/readiness(2)/record(3)/finalizing(4)/issue(5)/complete(6).
- `currentCaptureStage` now derives purely from `captureReadiness` (recording→record, finalizing→
  finalizing, incomplete/failed→issue, complete→complete, setupRequired→setup, blocking-lane/
  permission/timecode→readiness, ready→record). The stepper highlight, expanded stage, and record
  card header all read `currentCaptureStage`, so the active stage can never disagree with the
  expanded stage. `captureRecordCard` step header now uses `currentCaptureStage.rawValue/.title`.

**Camera / visual guide:**
- Standard preview is now the clean live feed only (`MacCameraPreviewView`): removed the
  `previewPill` (hand dot + coaching cue), the `Color.black.opacity(0.08)` scrim, and
  `DeckGamificationOverlay` (deck/mixer drag boxes). `previewPill` definition deleted (0 refs).
- `DeckGamificationOverlay` remains only in Advanced (calibration). Removed the "Camera deck
  calibration" disclosure from the Capture readiness card (calibration is Advanced-only).
- Camera stays an optional collapsed disclosure (`showCaptureCamera` defaults false; `.onChange`
  starts `captureEngine.start()` on open; closing does not stop the shared engine). Collapsed
  disclosure does not resize the sidebar (core workflow).
- Lifecycle traced (no engine change needed): `start()` → permission → `configureCaptureSession`
  → `startRunning()`; `refreshDevices()` auto-selects video device; single shared `captureSession`
  bound to the preview. Real preview kept — no black placeholder.

**Validation:** macOS build ✓, app launches clean (PID 40292), OCR of Capture tab confirms 6-stage
stepper + metadata strip + setup message + "Camera / visual guide" disclosure rendering "Deck
Camera" with truthful device subtitle. `CaptureReadinessTests` 14/14, `VisionCaptureGateTests`
18/18. `CameraNotationOverlayTests` 14 failures are PRE-EXISTING bundled-resource env failures
("Baby Scratch notation must load from bundle" — Bundle.main = xctest runner), unrelated.
1440×900/1280×800 exact sizing + hardware states (record/finalizing/complete) are HARDWARE/
interactive REQUIRED — not exercised this session.

**Stop:** Awaiting Approve macOS Capture.

---

## 2026-08-16 — V3.2 Capture state model (pure adapter + tests) — AWAITING APPROVAL

Implemented ONLY the pure Capture presentation/readiness adapter + its tests. No
re-layout, no capture-engine behaviour change, no pbxproj, no Figma/Code Connect.

**`ScratchLab/Models/CaptureCore.swift`** — the adapter is now lane-aware:
- `CaptureLane` (audio/dvsTimecode/platter/crossfaderMIDI/camera) + `CaptureLaneReadiness`
  (isRequired/isUsable, `isBlocking`) + `CaptureLanes` (5 lanes, `blockingLanes`, `isReady`).
- Mapping helpers reuse the existing rich enums: `.dvs(DVSSignalState, required:)` (only
  `.usable` is usable → carrierDetected≠ready), `.controller(ControllerMappingState, required:)`
  (only `.dvsPlusMidiReady` is usable → midiLearned/platterReady≠combined-ready),
  `.input(InputReadinessState, required:)`, `.audio(isAvailable:)`.
- `CaptureReadiness` gained `.incomplete` (post-recording take that ended without a clean
  save) — distinct from `.needsAttention` (pre-recording blocking lane) and `.failed`.
- `CaptureReadinessInput` refactored from a flat boolean bag to `lanes: CaptureLanes` +
  lifecycle primitives (`didComplete/didFail/didEndIncomplete/isFinalizing/isTimecodeLost`).
- `derive` precedence: recording → finalizing → complete → failed → incomplete → timecodeLost
  → permission → setup → lanes. READY only when `lanes.isReady` (every blocking lane usable).

**`MacAnalyzerView.swift`** (minimum compile wiring only): `captureReadiness` now builds
`CaptureLanes` from real owners (audio→`isSelectedAudioInputAvailable`; dvs→`dvsSignalState`
required when `timecodePipeline.mode != .disabled`; platter→notRequired; crossfaderMIDI→
`controllerMappingState` required:false; camera→optional). `isFinalizing`/`didFail` wired
from `currentRoutineArtifactStatus?.readiness` (`.finalizing` / `if case .failed`).
`captureNextAction` gained the `.incomplete` case (moved the "didn't complete" message out
of `.needsAttention`). No other UI changed.

**Tests** (`ScratchNotationPanelTests.swift`, `CaptureReadinessTests` 14/14): carrierDetected
vs usable; midiLearned/platterReady vs dvsPlusMidiReady; camera never blocks; READY requires
every blocking lane usable; DVS-ready-but-audio-missing contradiction; incomplete≠needsAttention;
hardware-detected≠ready; green reserved for complete; non-blank labels.

**Gates:** macOS build ✓, iOS build ✓, build-for-testing ✓, `CaptureReadinessTests` 14/14,
`ScratchNotationPanelTests` 9/9, `ScratchLabDesignTokensTests` 19/19, `PracticePresentationStateTests`
18/18, `ReviewPresentationStateTests` 7/7. `git diff --check` clean. Nothing committed.

**Missing backend owners (reported, not invented):** `isTimecodeLost` still hardcoded `false`
(`SignalHealth` has noSignal/weak/usable/clipped/channelFault — no "lost", no "carrierDetected");
`CaptureLane.platter` has no dedicated readiness owner (`.notRequired`); `DVSSignalState.carrierDetected`
/`.lost` and `ControllerMappingState.platterReady`/`.controllerDetected`/`.mappingConflict` are
presentation states with no current engine bridge.

**Stop:** Awaiting Approve Capture State Model.

---

## 2026-08-16 — V3.2 Capture ownership map (READ-ONLY audit) — AWAITING APPROVAL

Read-only Capture ownership audit (no code/Figma edits). Mapped 11 approved Capture
presentation states (session metadata · selected hardware profile · audio input ·
DVS/timecode carrier+usability · platter motion · crossfader/MIDI mapping · recording ·
finalizing · incomplete take · saved take · camera availability) across macOS/iPhone/iPadOS.

**macOS owners (captureWorkspace = `MacAnalyzerView.swift:1299`):**
- session metadata — `CaptureSessionConfig`/`SessionSetupViewModel(.macRoutine)` (`CaptureCore.swift`),
  `routineSessionStore.selectedSession`; UI = `capturePageHeaderCard` metadata strip (`:5651`) + `captureSessionSetupCard` (`:5666`).
- audio input — `MacCaptureEngine.availableAudioDevices`/`selectedAudioDeviceUniqueID`/`isSelectedAudioInputAvailable`
  (`MacCaptureEngine.swift:2159,2763,2971`); UI = Audio `InputReadinessRow` (`:5821`) + source picker (`:5922`).
- crossfader/MIDI mapping — `crossfaderCCMapping`/`midiLearnState`/`selectedMIDIInputSourceID` (`:2163-2165`); UI = Mixer MIDI tile (`:5837`) + `midiLearnRow`.
- recording — `isRoutineRecording` (`:2879`); UI = `captureRecordCard` (`:5720`).
- incomplete take — `isLastRecordingIncomplete` (`:5443`) ← `routineRecordingStatus`/`lastRoutineRecordingURL` (`:2885-2886`); UI = `RecoveryCard`.
- saved/complete — `hasRecordedTake` = `lastRoutineRecordingURL != nil` (`:3303`); `markLastTakeSaved` (`:4168`) reports only.
- camera availability — `availableVideoDevices`/`selectedVideoDeviceUniqueID`/`isCameraActive` (`:2160,2781,2878`); UI = `captureCameraSection` (`:1326`) + Camera tile (`:5826`). Optional, never readiness-blocking.

**MISSING macOS owners (flagged, not faked):**
- `finalizing` + `didFail` — `CaptureReadiness` has the states but `captureReadiness` hardcodes `isFinalizing:false`/`didFail:false` (`:5475,5477`). Real owner exists: `TakeArtifactStatusSnapshot.readiness` (`currentRoutineArtifactStatus`, cases `.recording/.finalizing/.ready/.missingAudio/.missingVideo/.failed`).
- `timecodeLost` — hardcoded `false` (`:5479`); `SignalHealth` (noSignal/weak/usable/clipped/channelFault) has NO "lost" case. Needs a signal-loss owner.
- selected hardware profile — model owners exist (`ControllerProfileCatalog`/`MIDIHardwareRegistry`, `MIDIVerification` tier) but NO Capture UI; `HardwareProfileCard` deferred.
- DVS carrier/usability — owned by `TimecodeControlPipeline` (mode/signalHealth) but NOT surfaced in Capture; `DVSSignalHealthCard` is Advanced (DEBUG-scoped); `isDVSMode` defaults off so DVS is invisible in standard Capture.
- platter motion — engine tracks (CC6 `ScratchPlatterTracker`, `lastDrainedPlatterPositionTimeline`) but no Capture tile; timeline is DEBUG-only.

**Contradictions vs rules:**
- "saved take" ≠ `.complete`: `.complete` = recorded (a URL exists), not saved; `markLastTakeSaved` mutates no readiness state.
- Standard camera preview violates "no hand-region pills / scrims / coaching overlays": `previewPill` (hand dot + `babyScratchGuidanceCue`) + `.overlay(Color.black.opacity(0.08))` render unconditionally (`:2506,2512`). Drag boxes correctly gated behind `showRigGuides == !calibrationLocked` (`:2508`).
- MIDI identity ≈ readiness: `isMIDIReady = !availableMIDISources.isEmpty` (identity folded into readiness); verification tier not represented in readiness.

**iPhone/iPadOS:** ALL 11 states = FUTURE (Figma Implementation Map "Capture · mobile" FUTURE; `CapturePlaceholderView` unreferenced). Underlying-only: camera `CompanionCameraBroadcaster`, audio `AudioEngine`. No Capture presentation owner to map — reported honestly.

**Recommended slices + test plan:** see inline response + `next_prompt.md`.

**Stop:** Awaiting Approve Capture Ownership Map.

---

## 2026-08-16 — V3.2 Phase 6 (Cross-platform reconciliation) COMMITTED `0b85674`

Phase 6 committed as `0b85674` (`V3.2: reconcile cross-platform semantic colours`,
1 file, +4/−4): fixed the last "connected/ready = green" semantic bugs in macOS
(mixer status, Performer Monitor ×2, Review "Export Ready" → cyan). Audited obsolete
UI — `HandMotionOverlay` (0 refs, dead), `CapturePlaceholderView`/`ReviewPlaceholderView`
(FUTURE placeholders), Watch (retired) — IDENTIFIED but NOT removed (removal needs a
pbxproj edit). All builds green; 82 focused tests green (NotationPanel 9, DesignTokens
19, Practice 18, CaptureReadiness 12, Review 7, SessionReviewMetadata 17).

**Next: Phase 7 (Final audit)** — do NOT start until Karl provides the Phase 7 spec.
Final audit: clean build, build-for-testing, unit/integration/UI tests, notation/
capture/export/persistence tests, platform builds, compiler + runtime warning review,
and the full "no crash / no state-update / no false-Ready / no false-DVS / no
fabricated-review / no fake-export" checklist. Runtime + hardware validation is
HARDWARE REQUIRED. Remaining Phase 6 items carried forward: dead-code removal
(needs pbxproj approval), Dynamic Type / Reduced Motion / focus-order sweep.

---

## 2026-08-16 — V3.2 Phase 5 (Advanced) COMMITTED `facb46a`

Phase 5 committed as `facb46a` (`V3.2: implement adaptive Advanced workspace`, 1
file, +51/−9): fixed the Advanced Overview semantic-colour bug (ready=bone,
detected/connected=cyan, green only for completion) and wired the reusable
`DVSSignalHealthCard`/`ControllerMappingCard`/`PerformerMonitorConnectionCard`
into their sections with signal→state helpers (`dvsSignalState`,
`controllerMappingState`, `monitorConnectionState`). Builds ✓, app launches clean
(PID 29287). The Advanced workspace structure was already built in `9ee02a0`/`68188e4`.

**Next: Phase 6 (Cross-platform reconciliation)** — do NOT start until Karl
provides the Phase 6 spec. Reconciliation scope: reconcile macOS/iPhone/iPad,
remove obsolete UI only after proving unused, validate navigation/adaptive
layout/state consistency/camera/semantic colours/Dynamic Type/accessibility.
Remaining Phase 5 items carried forward: `HardwareProfileCard` (needs a
device→profile mapping decision), `TimecodeSystemSelector`/`ChannelPairSelector`
(DEBUG-scoped DVS selectors).

---

## 2026-08-16 — V3.2 Phase 4 (Review) COMMITTED `4568ad0`

Phase 4 committed as `4568ad0` (`V3.2: implement adaptive Review workspace`, 4
files, +227): `ReviewPresentationState` (9 states) + `ReviewPresentationInput` +
pure `derive` in `CaptureCore.swift`; macOS `reviewPresentationState` + header
`StatusBadge`; `ReviewPresentationStateTests` 7/7; label-confirmation/correction
persistence tests in `SessionReviewMetadataTests` (now 17/17). Builds ✓, app
launches clean. Label correction/confirmation/export were already implemented in
the prior macOS V3.2 Review work (`64b5a58`).

**Next: Phase 5 (Advanced)** — do NOT start until Karl provides the Phase 5 spec.
Advanced scope: Overview / Audio & DVS / Calibration / MIDI & Controller /
Performer Monitor / Diagnostics; independent Overview derivation. macOS
`advancedWorkspace` + `AdvancedSection` already exist (commits `9ee02a0`,
`68188e4`); the reusable `HardwareProfileCard`/`DVSSignalHealthCard`/
`ControllerMappingCard`/`PerformerMonitorConnectionCard`/`TimecodeSystemSelector`/
`ChannelPairSelector` from Phase 1 are ready to wire.

---

## 2026-08-16 — V3.2 Phase 4 (Review) — core state model done, uncommitted

Phase 4 core (uncommitted): `ReviewPresentationState` (9 states: noTake/recording/
finalizing/issue/ready/confirmed/exporting/exported/exportFailed) +
`ReviewPresentationInput` + pure `derive` added to `CaptureCore.swift` (green only
for confirmed/exported). macOS `reviewPresentationState` computed property in
`MacAnalyzerView` maps the real owners (`reviewStagePresentation`, `captureEngine`,
`reviewDecisionByTakeID`, `sessionExportCoordinator.state`) and the `reviewHeaderCard`
now shows a `StatusBadge` from it. `ReviewPresentationStateTests` 7/7. Builds ✓
(iOS + macOS + build-for-testing), app launches clean (PID 28666).

**Phase 4 REMAINING (do NOT start Advanced):**
1. Label correction/confirmation/export were already implemented in the prior macOS
   V3.2 Review work (commit `64b5a58`) and are wired to real evidence — verify their
   state maps onto `reviewPresentationState` (`.confirmed`/`.exporting`/`.exported`/
   `.exportFailed`) end-to-end with a real take.
2. Persistence tests (label correction/confirmation round-trip via
   `CaptureReviewDecision`/`CaptureReviewMetadata`).
3. Runtime validation with a real recorded take (HARDWARE REQUIRED).

---

## 2026-08-16 — V3.2 Phase 3 (Capture) COMMITTED `ffbd686`

Phase 3 committed as `ffbd686` (`V3.2: implement adaptive Capture workspace`, 4
files, +378/−169): `CaptureReadiness` model + derive + tests, macOS `captureReadiness`
wiring (ready→bone fix), camera optional-preview regression fix, DVS/MIDI/permission
signal wiring, `captureNextAction` unified onto `captureReadiness`, `RecoveryCard`
wiring, `InputReadinessState.neutral` + `InputReadinessRow` tile swap. Builds ✓,
`CaptureReadinessTests` 12/12, `ScratchLabDesignTokensTests` 19/19, app launches clean.

**Next: Phase 4 (Review)** — do NOT start until Karl provides the Phase 4 spec.
Review scope: no-take/ready/confirmation/correction/export, real captured evidence,
export schema, label correction (preserve raw evidence). macOS `reviewWorkspace` +
`ReviewStagePresentation` + `SessionExportCoordinator` are the owners; the prior
macOS V3.2 Review work (commit `64b5a58`) already exists.

---

## 2026-08-16 — V3.2 Phase 3 (Capture) — core readiness model done, uncommitted

Phase 3 core landed (uncommitted, mirroring Phase 2's state-model-first approach):
- `ScratchLab/Models/CaptureCore.swift` — new `CaptureReadiness` (10 states:
  setupRequired/hardwareDetected/needsAttention/ready/recording/finalizing/
  complete/failed/timecodeLost/permissionRequired) + `CaptureReadinessInput`
  (pure primitives) + `CaptureReadiness.derive` + `label`/`variant`/`systemImage`/
  `isBlockingReady`. Green only for `.complete`; ready = bone. Enforces
  connected≠ready, carrier≠DVS-ready, DVS-ready≠capture-ready, MIDI≠mapped.
- `MacAnalyzerView` — `captureReadiness` computed property mapping real signals
  (`selectedRoutineSession`, `routineMetadataStatusMessage`,
  `captureEngine.isSelectedAudioInputAvailable`, `isRoutineRecording`,
  `hasRecordedTake`, `isLastRecordingIncomplete`, `crossfaderCCMapping`).
  Replaced the private 4-state `CaptureHardwareStatus` (which BUGGILY mapped
  READY→green) with `CaptureReadiness`; readiness card now shows the derived
  label + systemImage + `variant.color`. Removed the dead enum.
- `ScratchNotationPanelTests.swift` — `CaptureReadinessTests` 12/12.
Builds ✓ (iOS + macOS + build-for-testing), macOS app launches clean.

**Phase 3 camera optional-preview regression FIXED (uncommitted):** the Capture
tab's `captureCameraSection` disclosure showed `MacCameraPreviewView` but nothing
ever started the session on the Capture tab (`captureEngine.start()` only ran on
app-appear if `liveInputEnabled`, or from Practice's "Start live input"). Added
`.onChange(of: showCaptureCamera)` → `captureEngine.start()` (idempotent) when the
disclosure opens. Build ✓, app launches clean (PID 26762). **Hardware note:** the
actual feed display still needs a physical camera + permission grant — the code
path is fixed but not hardware-verified. "Stop when closed" is a separate lifecycle
concern: the engine is shared with recording, so it must stay active on the Capture
tab even when the camera preview is collapsed.

**Phase 3 DVS/MIDI/permission signal wiring (done, uncommitted):**
`captureReadiness` now wires real signals — `isDVSMode: timecodePipeline.mode !=
.disabled` (safe default `.disabled`), `isDVSReady: timecodePipeline.signalHealth ==
.usable`, `isMIDIReady: !captureEngine.availableMIDISources.isEmpty`,
`hasAudioPermission: AVCaptureDevice.authorizationStatus(.audio) != denied/restricted`
(`audioCapturePermissionGranted` static helper), `isCrossfaderMapped` already wired.
Still defaulted (VERIFY IN ENGINEERING): `isFinalizing`/`didFail`/`isTimecodeLost`
(no single owner; `SignalHealth` has no "lost" state) and `isMIDIRequired` (MIDI is
optional). Build ✓.

**Phase 3 workspace re-layout (done, uncommitted):** unified `captureNextAction`
onto `captureReadiness` (header status now derives from the single state; fixed
the "Ready→green" bug → ready is cyan accent; the record button was already
correct cyan-idle/red-recording). Wired `RecoveryCard` for the incomplete-recording
state into the readiness section (`Retry take` → `handleMainCaptureAction`).
Build ✓, app launches clean.

**Phase 3 REMAINING (do NOT start Review/Advanced):**
1. Runtime/hardware validation (RANE ONE MKII, DVS, USB-C — HARDWARE REQUIRED).

The reusable-component wiring is now COMPLETE: added `InputReadinessState.neutral`
(non-blocking, "—", grey) and swapped the capture input `LazyVGrid` of the ad-hoc
`captureInputStatusTile` (raw colors, "ready=green" bug) for a `VStack` of
`InputReadinessRow` (semantic states). Audio/Camera → `.setupRequired`/`.ready`;
Hand → `.neutral`/`.detected` (diagnostic); Mixer/Watch → `.neutral`/`.detected`/
`.ready` (optional). Removed the dead `captureInputStatusTile`. `ScratchLabDesignTokensTests`
now 19/19. Build ✓, app launches clean (PID 28113).

---

## 2026-08-16 — V3.2 Phase 2 (Practice) APPROVED & committed

Phase 2 is complete and approved. Two commits (split because the state model was
committed at an earlier checkpoint): `9877222` (state model + macOS header) and
`57e85e5` (iPhone/iPad/macOS surfaces + accessibility), both
`V3.2: implement adaptive Practice workspace`. Full report:
`~/Downloads/scratchlab_v32_phase1_components.md` (Phase 1) — the Phase 2 report
was presented inline and approved via `Approve Implementation Practice`.

**Next: Phase 3 (Capture)** — do NOT start until Karl provides the Phase 3 spec.
Capture scope (from the original plan): session setup + readiness, real
audio/DVS/MIDI/platter/crossfader state wiring, camera optional-preview fix,
truthful recording/finalizing/complete/failure, `CaptureReadiness` presentation
adapter. macOS `CaptureStage` + `MacCaptureEngine` are the owners; mobile Capture
remains FUTURE unless separately un-blocked.

---

## 2026-08-16 — V3.2 Phase 2 (Practice) — core state model done, surface wiring pending

**Phase 1 COMMITTED** as `544623d` (`V3.2: implement shared design components and
notation styling`), 5 files. **StatusBadge semantic verification** passed against
Figma node `144:23`: READY=bone, COMPLETE=green, Recording/Failure=red,
Attention=amber, Detected=cyan. One fix was made before commit: `ControllerMappingState
.platterReady` corrected from cyan → bone (Figma `253:293` shows "Platter Ready"
with the neutral READY badge). Added 2 badge-mapping tests pinning the exact
`ControllerMappingCard`/`ReviewExportCard` badge→colour mapping.

**Phase 2 (Practice) — core only, NOT committed (awaiting review).** Added the
single derived `PracticePresentationState` (ready/listening/copyActive/paused/
result/review/lessonComplete) + `derive(gameplay:isListening:isPaused:isReviewing:
isLessonComplete:)` + `notationMode` mapping + `showsPerformance` + `flowOrder`, in
`ScratchLab/Models/PracticeGameplayCoordinator.swift`. `PracticePresentationStateTests`
10/10 in `ScratchLabDesktopTests/ScratchNotationPanelTests.swift`.

- Notation mode mapping: ready/listening → `.targetReference`; copyActive/paused →
  `.liveComparison`; result/review/lessonComplete → `.reviewComparison`.
- `derive` precedence: lessonComplete > review > (copying: paused?→paused:copyActive)
  > (idle/watching/ready: listening?→listening:ready).
- Builds ✓ (iOS + macOS + build-for-testing). Design-token tests still 18/18.

**Phase 2 macOS wiring (done, uncommitted):** added `PracticePresentationState.label`
+ `.variant` (green only for `.lessonComplete`); added `practicePresentationState`
computed property in `MacAnalyzerView` deriving from real owners
(`practiceCoordinator.state` → gameplay, `demoModeController.demoPlayer.isPlaying`
→ listening, `progressManager.isScratchMastered("baby_scratch")` → lessonComplete);
`practiceStageHeader` now shows a `StatusBadge` with the derived label/variant.
Screenshot `/tmp/scratchlab_phase2_practice.png` shows "Practice / READY" (bone).
`PracticePresentationStateTests` 10/10, builds ✓.

**Phase 2 iPhone (done, uncommitted):** the iOS Practice surfaces were ALREADY
Figma-aligned from the prior V3.2 Phase 4 work (`PracticeReadyOverlay`,
`ResultsOverlayView`, `PauseOverlayView` — reconciled to anchors `33:18`/`35:99`
in earlier sessions). Added the missing "one derived state" layer:
`PracticePresentationState.derive(isSessionActive:isPaused:isResult:isListening:
isLessonComplete:)` (iOS boolean overload) + `PracticeModeView.practicePresentationState`
computed property deriving from `isSessionActive`/`isPaused`/`showingResults`/
`demoPlayer.isPlaying`/`progressManager.isScratchMastered(activeScratch.id)`.
`PracticePresentationStateTests` now 16/16. iOS build ✓, macOS build ✓.
The derived property is the single-state foundation; it is not yet wired into a
visible iOS indicator (the per-surface overlays are already correct).

**Phase 2 iPad (done, uncommitted):** `PracticeReadyOverlay` is now genuinely
adaptive — `AdaptiveWorkspaceHeader` + `LessonProgressIndicator` (WATCH/LISTEN/COPY/
RESULT/REVIEW) + a landscape two-column split (dominant `ScratchNotationPanel`
left, controls right via `layoutMode == .regularLandscape`), portrait/compact
keep the single column. iPad app builds for `generic/platform=iOS` + iPad
simulator, launches clean (screenshot `/tmp/scratchlab_ipad_home.png`). iPad sim
`B6972ED1…` is left booted for a manual tap-through. Practice tests 16/16.

**Phase 2 macOS notation swap + accessibility (done, uncommitted):**
`practiceTeachingNotation` now renders the shared `ScratchNotationPanel` (`.target`,
`mode: practicePresentationState.notationMode`, `canvasHeightOverride: 320`,
`domain` + `playheadTime` from the existing playback timeline) inside the existing
`TimelineView`; `ScratchNotationPanel` gained `canvasHeightOverride` and a
descriptive `accessibilitySummary` + hint. macOS playhead animation respects
`@Environment(\.accessibilityReduceMotion)`. `PracticePresentationStateTests`
now 18/18 (added 44pt-target + non-blank-label tests). Screenshot
`/tmp/scratchlab_phase2_notation_swap.png`.

**Phase 2 REMAINING (do NOT start other workspaces):** runtime screenshots of the
Practice Ready/live/result states on iPhone + iPad (needs a manual tap into
Practice — the simulators can't be UI-driven from this session; the iPad sim
`B6972ED1…` is left booted). **Missing owners (reported, NOT faked):** macOS has
no copy-pause (`.paused`) and no in-Practice review (`.review`) — review lives in
the separate Review workspace; iOS HAS a real pause owner (`isPaused` +
`pauseSession()`/`resumeSession()`).

---

## 2026-08-16 — V3.2 Phase 1 (tokens + shared components + notation) DONE — uncommitted

Phase 1 of the Figma→SwiftUI implementation is complete but **not committed**
(awaiting `Approve Implementation Components`). Full report:
`~/Downloads/scratchlab_v32_phase1_components.md`.

**Starting commit:** `68188e4`. **No pbxproj / scheme edits** — the project uses
explicit file refs (only `ScratchLabDatasetBuilder` is a synchronized folder), so
no new `.swift` files were created; all shared components went into the
dual-target `ScratchLab/DesignSystem/ScratchLabDesignSystem.swift`.

**Changed files (5):**
- `ScratchLab/DesignSystem/ScratchLabDesignSystem.swift` — locked Figma tokens
  (bg `#05070B/#0B1018/#101826/#151E2B`, accent `#0EA5E9`, success `#22C55E`,
  warning `#F59E0B`, danger `#F44336`, text/border/notation tokens, typography
  roles) + 22 reusable domain cards (`InputReadinessRow`, `HardwareProfileCard`,
  `RecoveryCard`, `DVSSignalHealthCard`, `ControllerMappingCard`,
  `CameraDisclosureRow`, `LessonProgressIndicator`, `AchievementProgressIndicator`,
  `SessionSummaryCard`, `PerformerMonitorConnectionCard`, `TakeListItem`,
  `EmptyStateCard`, `PracticeTransport`, `CoachingFeedbackCard`, `ReviewExportCard`,
  `MetadataField`, `ChannelPairSelector`, `TimecodeSystemSelector`,
  `AdaptiveWorkspaceHeader`, …) with pure semantic state enums. Button reconciled
  (dark-on-cyan primary, filled-red destructive, surface secondary, disabled).
- `ScratchLab/Models/ScratchMotionRenderer.swift` — `Style.target` 1.6pt + new
  `Style.performance` (cyan `#0EA5E9`, 2pt).
- `ScratchLab/Views/Notation/ScratchNotationPanel.swift` — Figma Target/Live/Review
  modes, `TARGET — COPY THIS` / `MY PERFORMANCE — LIVE/CAPTURED` labels, distinct
  target `#101013` / performance `#0E131B` canvases, `ScratchNotationComparisonPanel`.
- `ScratchLabDesktop/Views/ScratchPhraseChartView.swift` — renderer colours → tokens,
  distinct lane backgrounds, fader active rails trace-coloured (bone/cyan), grid
  tokens.
- `ScratchLabDesktopTests/ScratchNotationPanelTests.swift` — +`ScratchLabDesignTokensTests`
  (16 tests).

**Key semantic rule landed:** READY is bone (`#E8E4DC`), never green — added
`StatusBadgeVariant.ready` + `Sem.textStatusReady`. DVS `carrierDetected`/`weak`
are NOT `isReady`; only `usable` is. Controller `midiLearned`/`platterReady` are
NOT `dvsPlusMidiReady`.

**Verification:** iOS build ✓, macOS build ✓, build-for-testing ✓.
`ScratchLabDesignTokensTests` 16/16, `ScratchNotationPanelTests` 9/9. Full bundle:
2833 XCTest / 50 skipped / 225 pre-existing env failures (3 unexpected, none in a
changed area) + swift-testing 347 / 2 issues. macOS app launches, notation renders
(screenshot `/tmp/scratchlab_phase1_practice.png`).

**Still deferred (do NOT start):** mobile navigation shell, mobile Capture/Review,
`CaptureReadiness`, Review-state expansion, camera-engine repair, export, Advanced
workspace.

---

## 2026-08-16 — V3.2 macOS Advanced design LANDED (commit `9ee02a0`)

Advanced restructured so the selected section drives the main detail area
instead of stacking everything into one scrolling sidebar.

- `advancedWorkspace` → `advancedMainContent` renders `advancedSelectedSectionContent`
  in the main area; the sidebar is now a compact navigator (header + section
  picker + active session). `NotationVisualizerView` moved into the Overview
  section (was the always-on detail area).
- Section titles renamed (enum cases unchanged → persisted `advancedSection`
  selection preserved): Audio → "Audio & DVS", Camera & deck → "Calibration",
  Monitor / Connection → "Performer Monitor", [DEBUG] Capture details →
  "Diagnostics", Timecode Input → "DVS / timecode". Calibration icon → viewfinder.

File: `MacAnalyzerView.swift` only (23+/13-). OCR-verified the MIDI & fader
section renders in the main detail area with a compact sidebar.

### DVSControlVinylPanel "generic-class diagnostic"

Investigated: `DVSControlVinylPanel` is a plain `struct: View` (not a generic
class), in the active `ScratchLabDesktop` target, and the real `xcodebuild build`
shows **no** generic/`DVSControlVinylPanel` diagnostic. The reported diagnostic
is **stale** — a SourceKit index false positive (same class as the "Cannot find
type" noise observed all session). Nothing to fix.

### Verification

`xcodebuild build` ✓, `build-for-testing` ✓, `ScratchNotationPanelTests` 9/9,
`SessionReviewMetadataTests` 13/13. No state-update warning, no crash.
Screenshots: `/tmp/scratchlab_advanced.png` (MIDI & fader),
`/tmp/scratchlab_advanced_overview.png` (Overview capture was misrouted to the
Practice tab by a stale window — re-eyeball Overview before accepting).

### Remaining for final cross-workspace audit (separate pass)

- One authoritative Overview summary card (audio/DVS/MIDI/camera/monitor/next
  action) — the header badges cover audio/device/monitor today.
- Cramped/clipped mode/status labels now have full width in the main area; eyeball
  DVS / timecode (DEBUG `ENABLE_TIMECODE_LIVE_TAP`) panels.

Do NOT begin the final audit until Advanced is visually reviewed and accepted.

---

## 2026-08-16 — V3.2 macOS Review design LANDED (commit `64b5a58`)

Review was already largely complete (synchronized `reviewTargetVsPerformedStageCard`,
`reviewStagePresentation` state machine, canonical `ScratchPhraseChartView`
stacked comparison). This slice closed the two real gaps:

- **Hierarchy**: `reviewCompletedTakeStageCards` now shows the stacked
  TARGET / MY PERFORMANCE comparison + coaching first, then the result
  summary; the raw captured chart, overlay diff, audio-onset preview and
  reference target collapse behind a "Technical evidence & diagnostics"
  disclosure (was a flat list where evidence dominated).
- **Missing-evidence labels**: `ScratchPhraseChartView` now labels empty
  performed fader data "FADER DATA NOT CAPTURED" (was "Fader not captured")
  and a performed chart whose strokes all lacked direction "DIRECTION
  UNAVAILABLE" (was a silent flat "No measured movement").

Files: `MacAnalyzerView.swift` (29+/…), `ScratchPhraseChartView.swift` (10+/…).

### Verification

- `xcodebuild build` ✓, `build-for-testing` ✓.
- `ScratchNotationPanelTests` 9/9, `NotationFeedbackStateTests` 23/23,
  `NotationFeedbackComparisonTests` 14/14 (run individually — batching with a
  swift-testing class runs 0).
- OCR-verified the no-take state (target reference + "Open Capture" + empty
  take-detail, consistent). The has-take stacked-comparison state needs a real
  take (none exists in the user's persisted session) — Karl to record one and
  eyeball. Screenshot: `/tmp/scratchlab_review.png`.

### Next

Advanced. Do NOT begin Advanced until Review is visually reviewed and accepted.

---

## 2026-08-16 — V3.2 macOS Capture REDESIGN (commit `c1604b4`, supersedes `2a53c56`)

Karl rejected `2a53c56` (semantic tweaks only). Redone as a genuine staged
redesign, amended into `c1604b4` (MacAnalyzerView.swift, 280+/53-):

- **Four-stage stepper** (setup → readiness → record → review): current stage
  emphasized, completed stages checkmarked + collapsed, future dimmed.
  Completed stages auto-collapse via `captureStageSection` (DisclosureGroups
  bound to `openCaptureStage`, synced from `currentCaptureStage` on appear +
  `.onChange`).
- **Session metadata strip** (performer · technique · BPM · mode) in the page
  header.
- **Unified HardwareStatus** (SETUP REQUIRED / NEEDS ATTENTION / READY /
  RECORDING) as the readiness-card headline. `currentCaptureStage` routes
  metadata gate → `.setup`, audio-missing → `.readiness`.
- Record/Stop cyan-idle / red-recording; "Use Serato Audio" cyan; "Review
  Takes" secondary; deck/mixer calibration in a collapsed disclosure.

### Verification (OCR, not just code inspection)

Image preview returns "Unsupported Image" this session, so screenshots were
verified with a local **Vision OCR** script (`/tmp/ocr.swift`) that dumps
recognized text + position. Confirmed on the launched build: metadata strip,
4-stage stepper, only the current stage expanded (setup expanded when
"Choose a scratch type"), record hero pinned. Build ✓, build-for-testing ✓,
`ScratchNotationPanelTests` 9/9. No state-update warning.

Screenshots: `/tmp/scratchlab_capture_final.png`,
`/tmp/scratchlab_capture_window.png`, `/tmp/scratchlab_capture_clean.png`.
Karl to eyeball the pixel rendering (OCR proves structure, not pixels).

### Next

Review, then Advanced. Do NOT begin Review until Capture is visually reviewed
and accepted. Note: a stale `ScratchLab` process (PID 2445,
`-NSDocumentRevisionsDebugMode YES`, Xcode-launched) is still running and
shows a second window (Advanced tab) — kill it if it confuses window screenshots.

---

## 2026-08-16 — V3.2 macOS Capture design LANDED (commit `2a53c56`)

Same option-2 fallback contract as Practice (Figma `AgrnQXwRvkAKlORTQ2U25z`
is iPhone+iPad only; no macOS frames). Capture semantics + progressive
disclosure corrected:

- **Record/Stop button** is now cyan (`Sem.accent`) when idle and red
  (`Sem.danger`) while recording — was green, which is reserved for
  readiness/success. `captureNextAction` already used correct semantics.
- **Draggable camera-region editor** (deck/mixer calibration) moved out of
  the standard readiness card into a collapsed `DisclosureGroup` with a
  Locked/Unlocked label. `showRigGuides == !calibrationLocked` (default
  locked), so the overlay itself was already opt-in.
- "Use Serato Audio" → cyan accent; "Review Takes" → secondary.

Files: `ScratchLabDesktop/Views/MacAnalyzerView.swift` only (48+/39-).

### Verification

- `xcodebuild build` → BUILD SUCCEEDED; `build-for-testing` → TEST BUILD
  SUCCEEDED.
- `xcrun xctest -XCTest ScratchLabDesktopTests.ScratchNotationPanelTests`
  → 9/9. (`CaptureReliabilityPhase1CoreTests` / `LiveInputSuspensionTests`
  ran 0 via `-XCTest` — same pre-existing selector caveat.)
- App launched on Capture + Practice tabs, no crash, **no "Modifying state
  during view update" warning** on either path.
- Screenshots: `/tmp/scratchlab_capture_after.png`,
  `/tmp/scratchlab_practice_regress.png` (Practice regression). Image preview
  still returns "Unsupported Image" in this session — Karl to eyeball.
- Restored `scratchlab.mac.workspaceTab` to `review` (Karl's prior value).

### Next

Review, then Advanced. Do NOT begin Review until Capture is visually
reviewed and accepted.

---

## 2026-08-16 — V3.2 macOS Practice design LANDED (commit `df6c564`)

Option-2 fallback contract authorised by Karl: use the DS 0.1.1 Foundations +
canonical notation + iPad V3.2 product frames in Figma `AgrnQXwRvkAKlORTQ2U25z`
as the visual reference for native macOS — there are **no macOS frames** in
that file (it is iPhone + iPad only; the "V3.2 implementation board" node
`38:23` is still "processing — not duplicated"). Do NOT claim pixel-parity
with nonexistent macOS frames.

### Practice (this slice)

- `MacAnalyzerView.practiceWorkspace` now shows **canonical notation as the
  central teaching surface**: a single `practiceTeachingNotation` card labelled
  "TARGET — copy this" (shared `ScratchPhraseChartView`, target window +
  playhead, animates during WATCH/LISTEN), with the camera/live-input path
  collapsed into `practiceOptionalLiveInput` (a `DisclosureGroup`).
- Deleted `practiceCameraStage` / `macDemoStage` / `demoModeFeedbackColor` —
  the large camera + demo-feedback-circle stage is gone from standard Practice.
- Cyan primary hierarchy: "Start practice" was `scratchLabSuccessButton`
  (green) — now `scratchLabPrimaryButton`; "Listen", "Start Copying", "Next
  Attempt" all converted from bare `.borderedProminent` (gold) to
  `.scratchLabPrimaryButton`. `practiceStageHeader` lost the "Start live
  input" primary; "Open Capture" is now secondary.
- Sidebar: scored attempt (WATCH → COPY → RESULT) sits directly under the
  Current-lesson hero; the timed `practiceRunCard` moved into a "Practice run"
  disclosure.
- Added shared `ScratchLabDesign.Notation.targetTrace` (#E8E4DC bone) and
  aligned `ScratchMotionRenderer.Style.target` to it (cross-platform token —
  no fork).

### Verification (macOS)

- `xcodebuild build -scheme ScratchLabDesktop` → BUILD SUCCEEDED.
- `build-for-testing` → TEST BUILD SUCCEEDED.
- `xcrun xctest -XCTest ScratchLabDesktopTests.ScratchNotationPanelTests`
  (dylib-symlink recipe) → 9/9 passed.
- App launched from the fresh build (no crash). **No "Modifying state during
  view update" warning fires on the Practice path** — the warning is tied to
  the Advanced → MIDI & fader bindings (already deferred via
  `DispatchQueue.main.async`), not Practice.
- Before/after screenshots: `/tmp/scratchlab_practice_before.png`,
  `/tmp/scratchlab_practice_after.png` (same 3024×1964 retina; differ by mean
  channel Δ≈8.7). I could not visually inspect them in this session (image
  preview returned "Unsupported Image") — Karl to eyeball.

### Next

Capture, Review, Advanced still pending (one workspace at a time, same
fallback contract). Do NOT begin Capture until Practice is visually reviewed
and accepted. Commit message pattern: `V3.2 macOS: implement native <Workspace> design`.

---

## 2026-08-15 — V3.2 legacy Practice removal + "MOVE TO ADVANCED" reroute (uncommitted)

Follow-up to Phase 4, on `feature/v3.2-swiftui-20260815`. Removed the legacy
iPhone Practice presentation from the production route per the course correction:
production is now `Home → Practice Ready (Figma 33:18) → Live → Result`, fixed
Baby Scratch / Open mode / mic auto / BPM badge; the superseded controls
(beat/BPM, assist modes, Chirp Flare, Baby Flow combo) moved to Advanced.

### Production route (new)

`MainMenuView` "Practice" → `fullScreenCover` → `PracticeModeView(baby_scratch, usesSimplifiedReady: true)`.
`PracticeModeView`'s ready state now branches:
- `usesSimplifiedReady == true` → new `PracticeReadyOverlay` (Figma `iPhone / Practice Ready`:
  `PRACTICE · BABY SCRATCH` eyebrow, "Copy the target", canonical TARGET
  `ScratchNotationPanel` (compact), mic + BPM status pills, "Open practice" card,
  `Start session` → Open mode, `Watch` → Demo mode). Production only.
- `usesSimplifiedReady == false` → legacy `SessionSetupOverlay` (full). Advanced only.

### Moved to Advanced

`AdvancedHubView` gained a "Practice modes" `MenuButton` → `LevelSelectView`
(keeps Chirp Flare, Baby Flow combo, and the full `SessionSetupOverlay` with
beat/BPM + assist modes + audio input + session length).

### Dead-code cleanup (done, no file deletion — symbols only)

- `LevelSelectView.swift`: removed dead `LevelCard`, `ProgressIndicator`,
  `LevelDetailView`, `ScratchCard` (0 or only-dead references; their
  functionality was superseded by `LevelSelectView.practiceScratchCard`).
  File is live (still reachable from Advanced); file now ends at `LevelSelectView`.
- `MainMenuView.swift`: removed 8 orphaned `@State` routes + their destinations/
  sheet (`showingCapturePlaceholder`, `showingReviewPlaceholder`, `showingCoachPreview`,
  `showingDemoMode`, `showingVirtualPlatterPrototype`, `showingCompanionCam`,
  `showingWatchCapture`, `showingPerformerMonitor`, plus `isIOSAppOnMac`) — all
  duplicated in `AdvancedHubView`. `CapturePlaceholderView` / `ReviewPlaceholderView`
  retained (future mobile Capture/Review intent), now unreferenced, with a
  `// Retained future placeholders` comment.

### Verification

iOS (generic + iPhone 17 sim) ✓, iPad sim ✓, macOS ✓, macOS build-for-testing ✓,
`git diff --check` clean, Phase 4 swift-testing suites all pass.

### Files changed (this slice)

- `ScratchLab/Views/MainMenuView.swift` — reroute + orphan removal + Advanced entry.
- `ScratchLab/Views/PracticeModeView.swift` — `usesSimplifiedReady` + `PracticeReadyOverlay` + helpers.

Nothing staged, committed, or pushed. No pbxproj edits. Do NOT begin Phase 5.

---

## 2026-08-15 — V3.2 Phase 4 Practice RESULT/REVIEW: truthful capability path (uncommitted)

Continued Phase 4 on `feature/v3.2-swiftui-20260815`. Implemented the DECISION's
truthful path: RESULT shows canonical TARGET notation + real aggregate metrics,
and REVIEW shows real semantic/timing coaching — never a fabricated
MY PERFORMANCE trace (the live mic Practice path produces no movement evidence).

### What landed (all uncommitted)

- `ScratchLab/Models/ScratchGameplayAttempt.swift` — two pure, testable types:
  - `PracticeResultNotation` — capability decision. `resolve(performedMovementEvents:)`
    maps an empty event list → `.targetOnly` (truthful "trace unavailable") and a
    non-empty list → `.comparison(performed:)` (real TARGET + MY PERFORMANCE).
    Evidence-driven, never platform-name-driven.
  - `PracticeReviewSummary` — honest post-take Review projection from the live
    `ScratchAnalysisResult` timing aggregates (attempts / averageAccuracy /
    onBeatCount / earlyCount / lateCount). `timingDirection` (noSignal/onBeat/
    early/late) and `coachingLine` reuse the existing `NotationFeedbackState`
    70/90 thresholds and coaching voice; no platter direction/position claimed.
- `ScratchLab/Views/PracticeModeView.swift` — the Result surface (`ResultsOverlayView`)
  now renders (1) the canonical TARGET `ScratchNotationPanel` (compact) when a
  target exists, (2) a truthful `PerformanceTraceUnavailableCard` in place of
  Figma's stacked PERFORMANCE panel when no movement evidence exists (the current
  mic path), and (3) a `PracticeReviewCard` semantic coaching section. The
  existing real metrics (score/accuracy/attempts/streak) and the timing-preview
  card are preserved unchanged. `handleScratchDetected` now also buckets off-beat
  hits into `earlyHitCount`/`lateHitCount` (supplementary, never saved/scored/exported).
  Content moved into a `ScrollView` to fit the taller card.
- `ScratchLabDesktopTests/ScratchGameplayAttemptTests.swift` — 14 new swift-testing
  tests across 3 suites: `PracticeResultNotation capability` (5), `PracticeReviewSummary
  review evidence` (6), `Practice result truthfulness (source-string)` (3).

### Figma reconciliation

Result frame = node `35:99` ("Practice / Result"). Its PERFORMANCE
`ScratchNotationPanel` (`35:117`) — and the Copy frame's `35:70` — expect a
performed lane the mic-only iPhone input path cannot supply. There is NO existing
Figma "unavailable/evidence" component; the smallest correction is to swap the
PERFORMANCE panel for a warning-toned `SurfaceCard` carrying the truthful
capability copy. **FIGMA RESULT SPEC REQUIRES CAPABILITY-STATE CORRECTION** —
reported, not modified (waiting Karl's approval).

### Verification

- iOS (generic) build ✓, macOS build ✓, macOS build-for-testing ✓, iPad sim build ✓.
- `git diff --check` clean.
- 14/14 new swift-testing tests pass (full bundle: 2 pre-existing swift-testing
  issues = crossfader-lane-label; 21 pre-existing XCTest failures = bundled-resource
  / Timecode fixture — none related).

### Files changed

- `ScratchLab/Models/ScratchGameplayAttempt.swift` — +2 pure types.
- `ScratchLab/Views/PracticeModeView.swift` — Result/Review UI + timing buckets.
- `ScratchLabDesktopTests/ScratchGameplayAttemptTests.swift` — +14 tests.
- (Pre-existing dirty, NOT touched: `ScratchLab/Views/MainMenuView.swift` — Phase 3 Home.)

Nothing staged, committed, or pushed. No pbxproj edits (models/tests added to
existing files; the "pbxproj diffs need separate manual approval" rule holds).

### Next

Karl to (1) live-verify on ~375/393/430pt iPhones (Home → Practice → Baby Scratch →
WATCH/LISTEN → COPY → RESULT → REVIEW), (2) approve/deny the Figma capability-state
correction, then (3) approve commit. Do NOT begin Phase 5.

---

## 2026-08-14 — Baby Scratch comparison alignment fix (uncommitted)

Fixed the Review target-vs-performed comparison so Take 002's leading backward
setup stroke no longer phase-shifts the whole phrase into 17 wrong-way results.
Evidence ZIP `session_2026_08_14_notation_baby_scratch_90_bpm.zip` (Take 002:
34 controller movements, `B/F/B/F…`). Nothing staged/committed/pushed.

### Root cause

`ScratchPerformanceAlignment.compare` anchored to absolute beat time and
greedily paired target stroke 0 with performed stroke 0. Take 002's slow
leading backward setup stroke (0.92 s ≈ 2.6× median) shifted every pair by one
stroke → 17 wrong-way; an incomplete final stroke + an over-tiled 17th cycle
added 4 missed / 4 extra → ~40%.

### Fix (comparison/scoring alignment only)

Added `ScratchPerformanceAlignment.align(target:performed:) -> ScratchAlignment`
— a deterministic, source-neutral stage that classifies boundary/setup and
boundary/incomplete strokes from duration evidence (never "first/last
unconditionally", never flipping directions to raise score), selects phase, and
flags over-tiled target strokes as unscored. `compare` now matches one-to-one
monotonically (drift-tolerant index pairing for a coherent same-count phrase,
direction-aware window match otherwise). Captured/exported notation untouched.

- `ScratchLab/Models/ScratchPerformanceComparison.swift` — `ScratchAlignment`,
  new result fields (`boundarySetup…`, `boundaryIncomplete…`,
  `unscoredTargetStrokeIndices`, `alignmentExplanation`), `align`, rewritten
  `compare`/`matchStrokes`, overlay `MarkKind.boundarySetup/boundaryIncomplete`.
- `ScratchLabDesktop/Views/ScratchPhraseChartView.swift` — dim boundary marks.
- `ScratchLabDesktopTests/ScratchPerformanceComparisonTests.swift` — 15 new
  `ScratchPerformanceAlignment boundaries` tests (real Take 002 fixture +
  edge cases).

### Take 002 result

32 matched / 0 missing / 0 extra / 0 wrong-way; boundary setup `[0]`,
incomplete `[33]`, unscored target `[32,33]`; 16 F/B cycles; timing 13 early /
4 correct / 15 late (performer ~6% slow); overall 60.4 (was 40).

### Verification

macOS Debug ✓, Release ✓, build-for-testing ✓, `git diff --check` clean. 15/15
new + all existing comparison suites pass via `xcrun xctest`. Full bundle: 2
swift-testing issues = pre-existing crossfader-lane-label checks; XCTest
failures = pre-existing bundle-resource / iOS-target-membership.



Repair of the camera fallback path and proof of the controller telemetry round
trip, on top of the prior uncommitted controller work. Two source reviews found
defects; this entry records the fully corrected state. Nothing staged or pushed.

### Root cause (camera path)

1. **Cadence.** 40 ms gate reset to the accepted frame → 30 fps quantized to
   ~15 fps. Fixed with an accumulated-deadline scheduler (frame-rate
   independent).
2. **Anchor.** Per-frame highest-scoring joint (anatomical switching), plus a
   key-mapping bug (`JointName.rawValue.rawValue` is `VNHLKWRI`, not `"wrist"`).
   Fixed with a time-bounded confidence-weighted wrist+MCP base anchor +
   fingertip fallback + `canonicalAnchorJointName`.
3. **Direction.** Raw camera X → signed angular displacement around the platter
   centre (atan2 + unwrap + orientation contract + centre/jump rejection),
   fail-closed to "camera calibration insufficient".
4. **Device routing.** CC6 decode resolved from the first ch1 CC6 event
   (nondeterministic); nil device disabled the decoder filter. Now
   `resolvedControllerMovementEvents` fails closed (nil → zero controller
   events → camera fallback).
5. **Builder geometry.** The notation builder consumed image-space X. Now a
   source-neutral `MovementObservation` (semantic direction, scalar position,
   angular confidence, source) feeds the builder; the smoothed image point is
   display-only. The builder's "furthest" tracking is source-neutral
   (absolute deviation from start). Evidence-based angular confidence
   (`PlatterRotationMath.angularConfidence`) replaces `handDirectionTracker.confidence`.
6. **Confidence lifecycle (second review).** The uncorroborated-camera penalty
   was applied up to four times (initial normalize + unmatched downgrade +
   downgrade classify + final normalize → ×0.62⁴). Fixed: `classify` is now
   idempotent (physical validation only), and a single documented
   `adjustConfidence` stage applies the camera penalty (or audio `+0.08`) exactly
   ONCE, keyed on source so "video"/"fused" are never re-adjusted.

### Shared camera processor

`CameraMovementProcessor` (cadence → anchor → geometry → angular → builder
observation) is the single non-UI pipeline used by BOTH live capture and the
offline replay test. The replay drains the real `RoutineDetectedNotationBuilder`,
runs real fusion, persists/reloads the snapshot via `SessionArchiveBuilder`.
`decodeSidecarForAudit`, and uses the production export mapping
(`SessionExportRecordMovementEvent.init(from:)`, also used by
`SessionExportCoordinator`).

### Controller round-trip counts (verified)

`take-002` `mixerMidiEvents` = **8,656** CC6 ch1 events: filtered 8656 →
decoder runs **50** → noise-filtered **35** → fusion **30** = 2 merges + 3 drops
(`deltaTooSmall:2`, `speedTooLow:1`). The DEV_LOG "35 → 32 (3 dropped)" was
WRONG (it is 30; two reductions are merges). 30 trusted/saved/Review/export,
source `controller`, 20 audio bursts, 26 audio-correlated. Controller confidence
(0.9) is unaffected by the confidence refactor.

### Offline camera replay (production path, Take 002 camA, after confidence fix)

460 frames → 454 valid anchors → **3 raw builder events → 0 fused movements**,
each dropped by `confidenceTooLow` after the single ×0.62 penalty
(raw 0.116/0.192/0.172 → 0.072/0.119/0.107, all < 0.12). The camera fallback is
**EXPERIMENTAL/INSUFFICIENT** (3 movements vs 30 controller, in the wrong
15–17 s region). Reported honestly; controller stays authoritative.

### Files changed (this session)

- `ScratchLab/Models/CaptureCore.swift` — `PlatterDecodeDiagnostics` +
  `platterMovementDecodeDiagnostics`; decoder refactored onto `decodePlatterCore`.
- `ScratchLab/Services/SessionExportCoordinator.swift` — extracted
  `SessionExportRecordMovementEvent.init(from:)` (single export-mapping source).
- `ScratchLabDesktop/Services/MacCaptureEngine.swift` — device routing,
  `HandPoseCadenceScheduler`, `HandAnchorTracker`/`HandAnchorMath`,
  `PlatterRotationMath`/`PlatterRotationTracker`, `MovementObservation`,
  `CameraMovementProcessor`, `canonicalAnchorJointName`, builder source-neutral
  scalar position, `resolvedControllerMovementEvents`, idempotent
  `classify` + single-stage `adjustConfidence`.
- `ScratchLabDesktop/Views/NotationVisualizerView.swift` — truthful source
  labels ("Controller platter" / "DVS timecode" / "Video motion" / "Audio" /
  "MIDI fader") + "Camera movement insufficient" state.
- `ScratchLabDesktopTests/CaptureReliabilityPhase1Tests.swift` + `VisionCaptureGateTests.swift` — new/updated tests.

### Verification

- macOS Debug build ✓, macOS Release `build` ✓, `git diff --check` ✓.
- Focused suites all pass (controller 14, cadence 7, anchor 8, rotation 9,
  source-priority/degraded 8, Take002 round-trip 4, export round-trip 1,
  MovementTrace 20, VisionCaptureGate 18, AnchorJointNameMapping 1).
- **Full `xcodebuild test` RAN (no hang)**: XCTest 2807 tests / 51 skipped /
  21 failures; swift-testing 310 tests / 42 suites / 2 issues. The 21 XCTest
  failures = 1 (mine — a source-string assertion, since fixed) + 16
  `ScratchSamplePlaybackControllerTests` + 1 `MIDILearnHangFixTests` + 1
  `PracticeTargetNotationChartTests.testScratchPhraseChartViewIsOniOSTarget`
  (this worktree has no iOS target). The 2 swift-testing issues are the
  crossfader-lane-label checks. All non-mine failures are pre-existing.

### Readiness

- **Controller hardware validation: READY.** Routing, round trip, and export
  are proven deterministically.
- **Camera fallback: NOT READY — experimental.** Produces ~3 low-confidence
  movements that all fail the confidence gate; needs real platter-centre
  calibration. CC6 + angular orientation contracts remain PROVISIONAL (each a
  single documented function to flip).



The canonical target/performed comparison foundation (`6ede816`) is now
wired into user-facing surfaces: a Review "Target vs performed" card
(macOS), comparison-driven coaching and inspectable sub-scores, and
graceful Practice behaviour for techniques without a canonical pattern.
Zero new files, zero pbxproj changes (per the standing rule that pbxproj
diffs need separate manual approval).

### What landed

- `ScratchLab/Models/ScratchPerformanceComparison.swift`:
  - `ScratchComparisonWindows.derived(from:...)` — match windows derived
    from the target phrase's own beat spacing (half min inter-stroke start
    gap); correctness tolerances stay caller-supplied, clamped to windows.
  - `TargetScratchPhrase.materializedNotation(bpm:...)` — tiled phrase →
    `ScratchNotation` through the canonical `BeatPattern.materialized`
    boundary only.
  - `ScratchComparisonOverlay` — renderer-neutral seconds-domain marks
    (matched/missing/extra strokes with timing + direction verdicts;
    fader-edge marks only when the channel was `.compared`). Matched and
    extra marks sit at PERFORMED times; missing marks at TARGET times.
  - `ScratchPerformanceScore` — inspectable sub-scores: platterTiming,
    platterCompleteness, faderTiming, faderCompleteness (each nil when
    unassessable, never zeroed), overall = documented mean of non-nil
    sub-scores, plus all raw counts.
- `ScratchLab/Models/NotationFeedbackState.swift`:
  - `from(comparison:)` — aggregate state with a fundamental-first
    precedence ladder (wrongDirection > missed > dominant early/late >
    accuracy-threshold praise tiers reusing the existing 70/90 constants).
  - `coachingMessages(for:limit:)` — concise beginner lines (wrong way,
    missed movement, extra movement, early/late reusing the established
    voice verbatim, missed cut, cut early/late). No fader advice unless
    the channel was actually compared.
- `ScratchLabDesktop/Views/ScratchPhraseChartView.swift`: optional
  `comparisonOverlay` on the `.target` chart — performed slashes in the
  captured chart's direction language (flat dash when direction was
  indeterminate — never invented), verdict dots (same colours as
  `NotationFeedbackStyle`), hollow marks for missing slots, fader-edge
  verdict ticks in the crossfader sub-lane. Nil ⇒ byte-identical chart.
- `ScratchLabDesktop/Views/MacAnalyzerView.swift`: new
  `reviewTargetVsPerformedStageCard` between the captured-evidence and
  overlay-diff cards. Registry-driven
  (`canonicalBeatPattern(forScratchID:)`), beat anchor = count-in skip
  (`countInBeats * 60 / bpm`; beat 0 incl. count-in at take-relative 0),
  Schmitt fader thresholds 0.6/0.4 (UI-side constants), cycle count from
  evidence length (rounded, capped 64), tolerance ±50 ms via the
  established `NotationFeedbackState` constants converted to beats.
  Graceful `unavailable` reasons for: no scratch type, no canonical
  pattern, no BPM, no movement evidence. Preview-only copy; nothing
  saved/scored-persistently/exported.
- `ScratchLab/Views/PracticeModeView.swift`: unsupported techniques get a
  graceful "Target notation isn't available…" placeholder instead of a
  silent Spacer. Target lane still resolves through the registry alone.

### Verification (all green, 2026-08-11)

| Gate | Result |
| --- | --- |
| `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** TEST BUILD SUCCEEDED **` |
| `xcrun xctest` full bundle (dylib-symlink recipe; bundle is at `ScratchLab.app/Contents/PlugIns/`) | 259 swift-testing tests / 34 suites ALL PASSED (incl. 4 new comparison suites + registry source-string suite) |
| `xcrun xctest -XCTest …NotationFeedbackComparisonTests` | 14/14 passed |
| `xcrun xctest -XCTest …NotationFeedbackStateTests` | 23/23 passed |
| XCTest bundled-resource failures (31 across 7 classes) | Pre-existing environmental (`Bundle.main` is the xctest runner) — same classes as before this diff |
| `git diff --check` | clean |

### Debt audit (Phase 5) — categorized, nothing removed

- **A (required):** comparison/canonical model, TimingLane/ScratchMotionLane
  substrate, ReviewOverlayTimeline/OverlayReplayController, CXLNotationCapture,
  bundled `ScratchNotation.babyScratch` demo-timeline consumers (macOS Review
  target card, Notation Lab, coach).
- **B (adapter/compat):** bundled 76-stroke `babyScratch` demo timeline
  itself (legacy `"baby"` ID; technique ≠ demo timeline), per-stroke
  `faderState` legacy fader fallback, `ScratchNotation.detectedPreview`.
- **C (debug/verification-only):** `ScratchLab/Models/Notation/` tree
  (~4.1k lines — Grammar/Semantics/Timing/Phrasing/Coaching/Presentation;
  all consumers `#if DEBUG`), `TravelLaneDebugView`,
  `ScratchAnalysisFixtureAdapter` (offline C++-core proof, test-consumed
  by design), `ScratchNotationIntent` diagnostic comparison/exports.
- **D (obsolete candidate, deletion DEFERRED):**
  `ScratchLabDesktop/Services/ScratchNotationTimeline.swift` — zero
  production consumers (only its own test file). Deleting it requires a
  pbxproj edit, which needs Karl's separate manual approval — flagged,
  not removed.
- `LaneUserEvent` scaffold intentionally kept inert: iOS Practice has no
  per-stroke capture source (camera is preview-only; mic gives IOI
  scalars), so wiring the lane overlay there would fabricate data.
  `ScratchComparisonOverlay` is the ready-made feed once an iOS capture
  source exists.

### Still lacking ground truth

Only `baby_scratch` has a canonical `BeatPattern`. All other techniques
show the graceful placeholder (Practice) / unavailable reason (Review).
Adding a technique to `canonicalBeatPatterns` lights up every surface
with no per-surface edits (pinned by the "Registry-driven comparison
surfaces" test suite).


## 2026-07-07 — DVS sample auto-load slice LANDED (commit `4d5157c`, pushed, in sync with `origin/main`)

DVS-driven sample playback now auto-loads the `"ahhh"` sample before
playback-drive scheduling. This closes the gap where DVS scratch
motion could arrive before any sample was loaded to play it against.

### Sync status

- Branch: `main`.
- `origin/main` is synced with local `main`.
- Latest pushed commit: `4d5157c31509d0580cad58d21a6afaac2efc6cd4`
  (`DVS: auto-load sample before playback drive`).
- Working tree was clean after push.
- No CI / GitHub Actions configured: no `.github/workflows/` directory
  in this repo.

### What the slice does

- `ScratchSamplePlaybackController.ensureLoadedForDVSDrive(sampleID:)`
  is idempotent — repeat calls for an already-loaded sample do not
  reset playback position. The existing manual `load(sampleID:)` is
  unchanged and still resets playback position on every call (hot-cue
  pads, crossfader trigger, debug button all keep their old behavior).
- `MacCaptureEngine.forwardTimecodeDrive` arms/loads the sample as
  soon as `dvsPlaybackDriveActive` is true, independent of whether a
  `TimecodePlaybackDrive` value has arrived yet, tracking
  `dvsAutoLoadAttempted` / `dvsSampleLoadFailed`.
- `MacAnalyzerView`'s DVS status card gained a diagnostic line:
  `Sample loaded: yes / no / loading… / FAILED (WAV missing)`.

### Files changed in `4d5157c`

- `ScratchLabDesktop/Services/MacCaptureEngine.swift`
- `ScratchLabDesktop/Services/ScratchSamplePlaybackController.swift`
- `ScratchLabDesktop/Views/MacAnalyzerView.swift`
- `ScratchLabDesktopTests/ScratchSamplePlaybackControllerTests.swift`

### Validation

| Gate | Result |
|---|---|
| `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** TEST BUILD SUCCEEDED **` |
| `xcrun xctest -XCTest ScratchLabDesktopTests.ScratchSamplePlaybackControllerTests <bundle>` (DOT-selector workaround + DerivedData `Frameworks/` symlink to `ScratchLab.debug.dylib`, per `project_test_runner_hang`) | 70/70 tests passed, 0 failures, ~0.2 s |

### Important caveat

This verifies sample auto-load and scheduling readiness only. It does
**not** prove hardware DVS feel, platter-follow accuracy, audio
quality, latency, or Rane end-to-end behavior. The next required step
remains hardware validation with real Rane/DVS movement.

---

## 2026-05-27 — Notation track safe stop point reached (Sections 1–9 closed; HEAD `f1b3b7b`, in sync with `origin/main`)

The notation/timing/semantics/coaching/presentation/replay/debug-Review
track is at a clean, App-Store-safe stop point. Thirty `Notation:`
commits across nine sections (commit range `2c90ed5..f1b3b7b`) shipped
a fully-isolated, pure-Swift notation pipeline plus two DEBUG-only
preview surfaces. Zero production capture / export / scoring / ML /
Practice / Coach / Review behaviour was changed. The next TestFlight
build can be cut from this HEAD safely.

### Sync status

- HEAD = `origin/main` = `f1b3b7b338ec12f4dd52932b5e0c167afc797542`
- Working tree clean.
- `git fetch origin main` confirmed in-sync.

### Completed sections

1. **Section 1 — grammar** (`Models/Notation/Grammar/`): `NotationPrimitive`,
   `NotationPrimitiveDerivation`, `GrammarParameters`. Pure value types.
2. **Section 2 — timing** (`Models/Notation/Timing/`): `TimingGrid`,
   `GridAnnotation`, `Phrase`, `ExpectedTiming`, `TimingWindow`,
   `TimingOriginMarker`, `PhraseTimingSummary`. Pure, deterministic
   musical position projection.
3. **Section 3 — semantics** (`Models/Notation/Semantics/`):
   `ScratchFamily`, `ScratchFamilyAttachment`, `ScratchFamilyAnnotationSet`,
   `ScratchFamilySummary`. Family-vocabulary sidecar layer.
4. **Section 4 — coaching** (`Models/Notation/Coaching/`):
   `CoachingEventVocabulary`, `CoachingEvent`, `DriftCoachingEvaluator`,
   `PhraseCoachingEvaluator`, `CoachingEventSummary`. Pure evaluators
   over presentation data — produce events, do not feed scoring.
5. **Section 5 — presentation / geometry**
   (`Models/Notation/Presentation/`): `NotationPresentationModel`,
   `NotationLaneGeometry`, `NotationPlayheadGeometry`,
   `NotationGridlineGeometry`, `NotationViewportWindow`. Pure mappers
   from primitives + sidecars to renderer-ready geometry.
6. **Section 6 — debug renderer host** (`Views/Notation/`):
   `NotationLaneGeometryView` (DEBUG-callable Canvas renderer),
   `NotationLaneGeometryViewPreview` (`#if DEBUG` preview harness),
   `DebugNotationLaneHostView` (`#if DEBUG` standalone host with
   empty / simple / dense presets).
7. **Section 7 — deterministic replay**
   (`Models/Notation/Presentation/NotationReplayModel.swift`):
   `NotationReplayFrame`, `NotationReplayState`, `NotationReplayProjection`,
   `NotationReplayDriver`. No-clock, no-timer, no-AVFoundation
   value-level frame stepper that composes the four Section 5 mappers.
   Section 7 also added a `.replay` preset to `DebugNotationLaneHostView`
   driven by a `Stepper`-based `frameIndex` (DEBUG-only).
8. **Section 8 — DEBUG Review card**
   (`Views/Notation/DebugReviewNotationCard.swift`): `#if DEBUG`
   standalone card that demonstrates the projection pipeline against
   a synthetic target / captured pair with deterministic timing drift.
   Two stacked `NotationLaneGeometryView` instances share one
   `NotationReplayState` and a frame `Stepper`. **Not wired into
   production Review** — deliberately unreachable from the running
   app per the audit's "no broad MacAnalyzerView redesign" constraint.
9. **Section 9 — final safety audit** (this slice's predecessor). All
   ten audit gates passed; see `Verification summary` below.

### Explicit non-changes

- Production **Practice / Review / Capture / Coach** behavior was not
  intentionally changed. Diff against pre-notation baseline
  (`2c90ed5^..HEAD`) touches zero files matching
  `Capture|Export|Score|MLClassif|Practice|SessionReplayClock|SessionReplayTimeline|SessionReviewValidator|MacAnalyzer|NotationVisualizer|ReviewOverlay|MainMenu|ContentView`.
- The two DEBUG surfaces (`DebugNotationLaneHostView`,
  `DebugReviewNotationCard`) are **not production UX**. Both are
  wrapped top-to-bottom in `#if DEBUG`, both have zero production
  callers, both are unreachable from any navigation entry point.
  Release builds compile them out entirely.
- **No export / schema integration.** `scratchlab_session_export_v4`
  and `scratchlab_session_replay_v1` are byte-identical to the
  pre-notation baseline — `SessionExportCoordinator.swift:23,330`
  and `SessionReplayTimeline.swift:67` were not touched.

### Key files / directories added

```
ScratchLab/Models/Notation/Grammar/        (Section 1)
ScratchLab/Models/Notation/Timing/         (Section 2)
ScratchLab/Models/Notation/Semantics/      (Section 3)
ScratchLab/Models/Notation/Coaching/       (Section 4)
ScratchLab/Models/Notation/Presentation/   (Sections 5 + 7)
ScratchLab/Views/Notation/                 (Sections 6 + 7 + 8)
ScratchLabDesktopTests/{Coaching,Drift,Phrase,Notation,Debug,Expected,Grid,ScratchFamily,Timing}*.swift
ScratchLab.xcodeproj/project.pbxproj       (additive Sources-phase entries only)
```

Source files: 28 new across `Models/Notation/**` and `Views/Notation/**`.
Test files: 28 new in `ScratchLabDesktopTests/`.
Only existing file modified: `project.pbxproj` (file-ref additions).

### Verification summary from Slice 9.1

| Gate | Result |
|---|---|
| `git status --short --branch` | `## main...origin/main` (clean) |
| `git fetch origin main` | fetched, no new commits |
| `git rev-parse HEAD origin/main` | both `f1b3b7b…` — in sync |
| `xcodebuild … -destination 'generic/platform=iOS' build` | `** BUILD SUCCEEDED **` |
| `xcodebuild … -destination 'platform=macOS' build` | `** BUILD SUCCEEDED **` |
| `xcodebuild … -destination 'platform=macOS' build-for-testing` | `** TEST BUILD SUCCEEDED **` |
| Forbidden imports in notation-track Swift | 0 hits for `AVFoundation`, `CoreML`, `CreateML`, `RealityKit`, `ARKit`, `Combine` |
| Determinism sweep (`Date()`, `Timer`, `DispatchQueue`, `TimelineView`, `@StateObject`, `ObservableObject`, `@Published`, `RunLoop`, `asyncAfter`, `NSTimer`, `CADisplayLink`, `mach_absolute_time`, `CFAbsoluteTimeGetCurrent`) | Only match is a doc-comment in `DebugReviewNotationCard.swift:35` asserting *absence* of `TimelineView`. No actual impurity. |
| `Info.plist` / `PrivacyInfo.xcprivacy` / entitlements / signing / `xcschememanagement.plist` | Untouched |
| `reference_frames/` / `reference_videos/` | Untouched |
| Resource files (`.mlmodel`, `.mlmodelc`, `.mlpackage`, audio/video) | Zero added |
| Notation-track tests compile-presence | 27 XCTest classes + 1 swift-testing class, ~387 methods, all linked into the macOS `.xctest` bundle |

### Known limitations

- **No production Review wiring yet.** `DebugReviewNotationCard` exists
  but is unreachable from the running app. `MacAnalyzerView` /
  `NotationVisualizerView` / `ReviewOverlayLaneView` were deliberately
  not modified.
- **No live capture-to-notation bridge yet.** The notation pipeline
  consumes `NotationPresentationModel` directly; there is no adapter
  from `SessionReplayTimeline` (or from live capture snapshots) into
  that shape. The Slice 8.1 plan recommended such an adapter
  (`SessionReplayPresentationAdapter`) but Slice 8.2 shipped the DEBUG
  card instead. The adapter is the natural next minimal step if the
  product needs it.
- **No export schema bump.** Nothing in the notation track persists
  to disk; no encoder runs against any schema-version-bearing file;
  `scratchlab_session_export_v4` / `scratchlab_session_replay_v1`
  unchanged.
- **Test execution environment limitation, build-for-testing works.**
  Per the recorded `project_test_runner_hang` memory, `xcodebuild
  test` / `test-without-building` route through an iOS test-host that
  Gatekeeper denies on this machine; `xcrun xctest` directly cannot
  resolve `@rpath/ScratchLab.debug.dylib` from the bundled-test
  layout. **Canonical verification mode on this project is
  build-for-testing (compile-time contract) plus grep-verify of test
  methods.** Both gates green here. If a CI environment can run the
  full XCTest suite, the existing test bundle compiles and links
  cleanly against the macOS target.

### Next recommended move

**Stop here and make a product decision** before any further wiring.
The notation track is in the safest possible state for an App Store
or TestFlight build: invisible to users, fully isolated, with no
export or scoring entanglement.

Three plausible next moves, in increasing risk:

1. **Stop and ship.** Cut the next TestFlight from `f1b3b7b`. Zero
   user-visible change from the notation work. No coordination cost.
2. **Plan production Review integration separately.** Run a dedicated
   planning slice that decides how `NotationLaneGeometryView` /
   `NotationReplayProjection` should appear on a real Review surface
   (which session, which take, what data source). Don't begin
   implementation until App-Store-safety phrasing (`PROFILE.md`),
   data-source policy, and the location of the new UI are pinned.
3. **Ship `SessionReplayPresentationAdapter`.** The Slice 8.1 planned
   adapter — `SessionReplayTimeline → NotationPresentationModel`
   plus `→ NotationReplayState`. Pure additive value-level mapper,
   no UI, no production caller. Lets a future Slice wire either
   DEBUG surface against real `SessionReplayTimeline` data instead
   of synthetic fixtures, without touching `MacAnalyzerView`.

Recommended sequence: **(1) handoff + ship**, then **(2) plan
production Review integration separately** before any DEBUG-surface
wiring. The two DEBUG surfaces being deliberately unreachable is a
feature before a release cut, not a bug.

---

## 2026-05-25 — Review notation viewport/duration chain LANDED (commits `2163916`, `13c1f89`; manual smoke passed)

Two Review-only fixes that together correct the captured-vs-target
notation comparison surface. The dominant defect was the **target
viewport** compressing the lane to a stale window while the captured
chip's duration was computed against a different basis, so the two
chips visually disagreed even when the underlying data matched.

### Commits (both on `main`, already pushed before this entry)

- **`2163916`** — `Review: add notation diagnostics and target
  viewport windowing`. Adds the per-chip diagnostics line and applies
  windowing to the target viewport so it matches the captured take's
  time span instead of using a stale / wider window.
- **`13c1f89`** — `Review: unify captured evidence duration basis`.
  Brings the captured chip's `dur` onto the same duration basis as the
  target window, so `win` and `dur` agree end-for-end.

### Manual smoke (this session, Karl — after fresh relaunch)

After a clean Cmd-Q + relaunch of the fresh build:

- **Target D1 chip**: `win=0.00s–17.49s`
- **Captured D1 chip**: `dur=17.49s` `first=0.00s` `last=17.49s`
  `movs=9` `audio=1` `fader=0` `midi=0` `src=partial`

Both chips agree on the 17.49 s span; captured-side counters are
non-zero where expected (`movs=9`, `audio=1`); source classification
reads `partial` as expected for this take.

### Stale-screenshot trap (resolved)

The first verification screenshot showed the old `win=0.00s–14.48s`
on the target chip. Root cause: an **8-hour-old `ScratchLabDesktop`
process** was still running and intercepted the `open` call, so the
freshly built binary never came to the foreground. After `Cmd-Q` of
the stale instance and a clean relaunch, the new build rendered
`win=0.00s–17.49s` correctly.

Operational note for future Review smoke tests on this machine:
**confirm the running PID matches the just-built bundle** (or just
Cmd-Q before `open`) before trusting the on-screen chip values.

### Alternative hypothesis ruled out

An **H6 / event-timestamp-offset** hypothesis (the chip showing a
non-zero `first=` because event timestamps were offset from the take
origin) was considered and rejected by the diagnostics: `first=0.00s`
on the captured chip confirms event timestamps share the take origin,
so the visible compression was viewport/duration-basis, not an event
offset.

### Conclusion

The dominant issue was **target viewport compression / duration-basis
mismatch**, now fixed in Review by the two commits above. The
captured and target chips now read consistent windows for the same
take, and the per-chip diagnostics line is in place for future
debugging.

### iOS parity audit

Audited whether an iOS mirror slice was needed. Conclusion: **no
additional iOS mirror needed now.** The shared renderer/model changes
underneath these Review-only fixes are already compiled into the iOS
target and are inert by default (no iOS call site exercises the
windowed/unified path that the macOS Review surface now uses). Revisit
only if/when an iOS Review-equivalent surface is built.

### Scope honoured by this handoff edit

- Touched ONLY `AI_HANDOFF.md`.
- No app code, no pbxproj, no fixtures, no tests.
- No stage, no commit, no push.
- No `Co-Authored-By` trailer.

---

## 2026-05-24 — Phase 4 CLOSED at Slice 1 (manual smoke passed, no further slices in flight)

Audit decision after Slice 1: **stop Phase 4 here.** Slice 1 (commit
`421de18`) fully delivers the original Phase 4 design goal — a
DEBUG-only, opt-in, non-bundled `PlatterPositionTimeline` JSON loader
gated by `BABY_PLATTER_FIXTURE_PATH`. No further slices are in flight.
This entry records the closure decision and the manual smoke result so
both survive `/clear` and any future agent search for "Phase 4".

### Manual smoke result (this session, Karl)

Mac Analyzer → Review tab → "Raw platter timeline (debug)" card behaved
exactly as the Slice 1 entry's `Expected UI (without recording any
take)` section predicted:

- **Fixture fallback.** With no live take drained, the card rendered
  the local-only `baby_platter.json` fixture (env var
  `BABY_PLATTER_FIXTURE_PATH` exported to the running
  `ScratchLabDesktop` Debug process).
- **Live-wins behaviour.** Once a take was recorded, the card swapped
  to the live timeline. The `Source: fixture (debug)` badge under the
  Present chip disappeared and the Source row changed from
  `coachAuthored` to `liveCapture`.

Together these confirm the live-wins / fixture-fills branch in
`MacAnalyzerView.swift:804-808` and the `isFixture` gate at
`MacAnalyzerView.swift:823-829`.

### Deferral conditions (locked in)

- **Slice 2 (standalone loader file + tests).** Deferred until a
  **second consumer** of the loader appears OR a **second fixture**
  (e.g. scribble, transformer) is authored. Today: 1 consumer
  (`platterTimelineDebugCard`), 1 fixture (`baby_platter.json`).
  Extracting `loadDebugPlatterFixture()` now would cost 2 new files +
  4 pbxproj inserts (Sources phase only) for zero behaviour change.
- **Slice 3 (env-var rename to `SCRATCHLAB_DEBUG_PLATTER_FIXTURE_PATH`
  with backward-compat alias).** Deferred until either a **second
  fixture exists** (i.e. a generic env-var name is actually warranted)
  OR a **runtime fixture-switching surface** is built. Renaming now
  would add a permanent backward-compat alias for zero current user
  benefit, and the right generic name depends on what the second
  fixture's contract turns out to be.
- **Hidden debug UI (DEBUG-only file picker / menu for runtime
  fixture switching).** Deferred until Karl explicitly asks for
  interactive runtime fixture switching; the Xcode-scheme env-var
  workflow documented under "How to use `BABY_PLATTER_FIXTURE_PATH`
  in Debug" in the Slice 1 entry below is sufficient for the current
  single-developer case.

### Audit footprint

- No app code touched.
- No commit, no push.
- No pbxproj / fixture files / `reference_frames/` / `reference_videos/`
  / `xcschememanagement.plist` touched.
- No `Co-Authored-By` trailer.
- The only working-tree change from the audit is this `AI_HANDOFF.md`
  edit; it is **not staged** pending Karl's review.

---

## 2026-05-24 — Phase 4 Slice 1: DEBUG-only fixture loader LANDED (commit `421de18`, pushed)

First consumer of the local-only `baby_platter.json` fixture pipeline.
The Mac Analyzer's existing Phase 3.2/3.4 raw-platter DEBUG card now
falls back to the local fixture when no live take has been drained,
giving the developer/visualisation surface something to render in the
empty-state slot. Live capture always wins; the fixture only fills
`nil`.

### Commit

- **SHA**: `421de18`
- **Subject**: `Phase 4: load debug platter fixture in Review card`
- **Pushed to `origin/main`**: `bdf2a53..421de18  main -> main`
- **Footprint**: **1 file changed, 94 insertions, 1 deletion** — entirely
  inside `ScratchLabDesktop/Views/MacAnalyzerView.swift`. Zero new
  files. Zero pbxproj edits.
- **No `Co-Authored-By` trailer** (per `feedback_no_coauthor_trailer`
  memory and `SOUL.md`).

### Context (prior commits this slice builds on)

- `78f321a` — local-only fixture pipeline (tooling + decode tests).
  Produces `Tests/Fixtures/LocalOnly/baby_platter.json` from Karl's
  owned `~/Downloads/demo_baby_scratch.mov`. Gitignored, non-bundled.
- `bdf2a53` — handoff doc capturing the 78f321a pipeline and naming
  Phase 4 as the next-recommended slice.
- `421de18` (this entry) — first consumer of that fixture. Closes
  the Phase 4 BLOCKED status recorded earlier in this file.

### What the slice does

Two additive edits in `MacAnalyzerView.swift`, both inside the existing
`#if DEBUG ... #endif` block that spans lines **780 → 1067**:

1. **`platterTimelineDebugCard`** (was line ~789) — replaces the single
   `let timeline = captureEngine.lastDrainedPlatterPositionTimeline`
   binding with a live-wins-fixture-fills pattern:

   ```swift
   let liveTimeline = captureEngine.lastDrainedPlatterPositionTimeline
   let fixtureTimeline = liveTimeline == nil ? Self.loadDebugPlatterFixture() : nil
   let timeline = liveTimeline ?? fixtureTimeline
   let present = timeline != nil
   let isFixture = (liveTimeline == nil) && (fixtureTimeline != nil)
   ```

   Adds a small `Label("Source: fixture (debug)", systemImage: "doc.text.magnifyingglass")`
   under the existing "Present"/"Missing" badge when `isFixture` is true.

2. **`loadDebugPlatterFixture()`** (new private static helper, added
   right after `decimatedSamples()` at line ~996, before the closing
   `#endif` at line 1067) — reads `BABY_PLATTER_FIXTURE_PATH` from
   `ProcessInfo.processInfo.environment`, expands `~`, checks file
   existence, reads bytes, decodes via the existing
   `PlatterPositionTimeline.init(from:)`, and returns `nil` on any
   failure. Every failure mode is logged at `.debug` via a dedicated
   `Logger(subsystem: "com.machelpnz.scratchlab.mac", category: "PlatterFixtureLoader")`
   (subsystem matches the pre-existing `PerformerMonitorBroadcaster`
   logger in the same file). Empty `samples` collapsed to `nil` so the
   card stays in its "Missing" state for that case.

### How to use `BABY_PLATTER_FIXTURE_PATH` in Debug

The env var must be visible to the running Debug `ScratchLabDesktop`
process — Xcode launched from Finder does not inherit shell env. Two
options:

1. **Xcode scheme.** Product → Scheme → Edit Scheme… → Run → Arguments →
   Environment Variables. Add:

   ```
   BABY_PLATTER_FIXTURE_PATH = $(PWD)/Tests/Fixtures/LocalOnly/baby_platter.json
   ```

   Build & Run the `ScratchLabDesktop` scheme (Debug config).

2. **Shell-launched Xcode / `open`.** From a shell that has the env
   exported, either:

   ```sh
   export BABY_PLATTER_FIXTURE_PATH="$PWD/Tests/Fixtures/LocalOnly/baby_platter.json"
   open ScratchLab.xcodeproj
   ```

   or after building once, run the Debug binary directly:

   ```sh
   BABY_PLATTER_FIXTURE_PATH="$PWD/Tests/Fixtures/LocalOnly/baby_platter.json" \
       open ~/Library/Developer/Xcode/DerivedData/Build/Products/Debug/ScratchLab.app
   ```

Expected UI (without recording any take):

- Mac Analyzer → Review tab → scroll to **"Raw platter timeline (debug)"** card.
- Badge: **Present** (green checkmark).
- Below the badge: **Source: fixture (debug)** with a doc-magnifier icon.
- Mini trace: 40 pt green polyline (auto-scaled to fixture's
  `positionRange`).
- Numeric rows: Sample count 637, Time range 0.0 – 26.5, Duration
  ≈ 26.5 s, Source `coachAuthored`.

### Live-capture preference order

**Live capture always wins.** The fixture is only consulted when
`captureEngine.lastDrainedPlatterPositionTimeline == nil`. Once a take
drains a timeline this session:

- The card switches to the live timeline.
- The "Source: fixture (debug)" badge disappears.
- The Source row reads `liveCapture`.

The fixture cannot be re-shown without restarting the app (deliberate;
keeping a "clear live timeline" affordance out of scope for Slice 1).

### DEBUG-only / local-only / non-bundled guarantees

- **DEBUG-only.** All seven `BABY_PLATTER_FIXTURE_PATH` references in
  `MacAnalyzerView.swift` (lines 792, 1002, 1022, 1029, 1038, 1047,
  1053) sit strictly inside the single `#if DEBUG ... #endif` block at
  lines 780–1067. There are no nested `#if` directives in that range.
  Awk gate (run during verification):

  ```
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:792:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1002:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1022:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1029:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1038:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1047:…
  DEBUG-OK  ScratchLabDesktop/Views/MacAnalyzerView.swift:1053:…
  ```

  Zero `LEAK!` lines. Release builds compile no loader code.

- **Local-only.** `Tests/Fixtures/LocalOnly/baby_platter.json` is
  gitignored by `Tests/Fixtures/LocalOnly/.gitignore` (landed in
  78f321a) and lives outside any Xcode source group.

- **Non-bundled.** The Slice 1 commit added zero entries to any
  `PBXResourcesBuildPhase` or `PBXCopyFilesBuildPhase` (no pbxproj
  edits at all). The pre-existing
  `BabyPlatterFixtureDecodeTests.testFixtureNotBundled` continues to
  run on every `xcodebuild test` invocation and fails if
  `baby_platter.json` ever appears in `Bundle.main`,
  `Bundle.allBundles`, or `Bundle.allFrameworks` — verified green in
  Slice 1's env-unset gate (1 of 5 passed, 4 skipped, 0 failures).

- **Phase 3.3 Review user-facing copy untouched.** The mixed-state
  predicate `hasRawMotionWithoutClassifiedStrokes` at
  `MacAnalyzerView.swift:1469` still reads
  `captureEngine.lastDrainedPlatterPositionTimeline` directly (not the
  fixture), so fixture-loaded data cannot reach Review user-facing copy
  in any build configuration.

### Verification results (all gates green)

| # | Gate | Command | Result |
|---|---|---|---|
| 1 | iOS build | `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` | `** BUILD SUCCEEDED **` ✓ |
| 2 | macOS build | `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` ✓ |
| 3 | macOS build-for-testing | `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'` | `** TEST BUILD SUCCEEDED **` ✓ |
| 4 | rpath symlink (DerivedData, not repo) | `ln -sf ../../../../MacOS/ScratchLab.debug.dylib …/ScratchLabDesktopTests.xctest/Contents/Frameworks/ScratchLab.debug.dylib` | symlink in place ✓ |
| 5 | Tests, `BABY_PLATTER_FIXTURE_PATH` UNSET | `env -u BABY_PLATTER_FIXTURE_PATH xcrun xctest -XCTest ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests <bundle>` | **5 executed, 4 skipped, 1 passed (`testFixtureNotBundled`), 0 failures** in 0.538 s ✓ |
| 6 | Tests, env SET | same invocation with env exported | **5 / 5 passed, 0 failures** in 0.204 s ✓ |
| 7 | grep DEBUG-gate | awk script above against `MacAnalyzerView.swift` | 7 / 7 hits inside `#if DEBUG`, zero leaks ✓ |

`xcrun xctest` invocation pattern uses the **dot** form
(`ScratchLabDesktopTests.BabyPlatterFixtureDecodeTests`), not the
slash form (which is `xcodebuild -only-testing` syntax) — Slice 1's
first env-unset attempt used the slash form and silently reported
"Executed 0 tests"; the fix was documented in
`/Users/karlwatson/.claude/plans/virtual-imagining-sunrise.md` and
verified above.

`xcodebuild test` still hangs at test-host install on this machine per
`project_test_runner_hang`; the `xcrun xctest` + DerivedData symlink
workaround documented in `Tools/Fixtures/README.md` remains the
verified path.

### Files intentionally NOT touched by Slice 1

| Path | Why |
|---|---|
| `ScratchLab/Models/PlatterPositionTimeline.swift` | Schema reused as-is. No changes to the Codable surface. |
| `ScratchLabDesktop/Services/MacCaptureEngine.swift` | Capture lifecycle unchanged. Drain hook from Phase 3.1 still the sole producer of `lastDrainedPlatterPositionTimeline`. |
| `ScratchLabDesktop/Services/PlatterPositionRecorder.swift` | Producer untouched. |
| `ScratchLabDesktop/Services/ScratchMotionRenderer.swift` | Renderer untouched. |
| `ScratchLabDesktop/Views/NotationVisualizerView.swift` | Review user-facing copy fork (Phase 3.3) unchanged. Advanced-tab call site preserved. |
| `ScratchLab.xcodeproj/project.pbxproj` | Zero edits. No new file refs, no build phases, no Resources entries. |
| Copy Bundle Resources phases | None modified anywhere. |
| `Info.plist`, `PrivacyInfo.xcprivacy`, signing, bundle IDs, entitlements | None modified. |
| `Tools/Fixtures/*`, `Tests/Fixtures/LocalOnly/*`, `.gitignore` | None modified. |
| Practice / Coach / scoring / classifier / export pipeline | None modified. |

### Remaining dirty items in the working tree (untouched by this slice)

Per `SOUL.md` "preserve unrelated dirty":

```
 M  ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
 ?? reference_frames/
 ?? reference_videos/
```

- `xcschememanagement.plist` — Xcode scheme-management drift, pre-existing
  since before Slice 1 started.
- `reference_frames/` and `reference_videos/` — pre-existing untracked,
  remain **off-limits** per `SOUL.md` ("Do not use YouTube/Ortofon
  material for training") and the prior `AI_HANDOFF.md`
  reference-material quarantine. Slice 1 did not touch either directory.

This `AI_HANDOFF.md` update itself is dirty (this edit). Not staged.
Not committed. Awaiting Karl's review per the constraint below.

### Slice ledger (for traceability)

- **Plan** (`/Users/karlwatson/.claude/plans/virtual-imagining-sunrise.md`)
  — written after plan mode activated mid-execution; captured remaining
  verification gates and the dot-vs-slash selector fix.
- **Slice 1** — single-file additive edit to
  `ScratchLabDesktop/Views/MacAnalyzerView.swift` (+94 / -1). All three
  Karl-approved decisions honoured: existing env var
  (`BABY_PLATTER_FIXTURE_PATH`) reused; live-capture-wins preference
  order; Slice 1 only (no Slice 2 standalone loader file).
- **Push gate** — auto-mode classifier blocked the direct-to-main push
  initially; Karl ran `! git push origin main` from his own shell.
  Result: `bdf2a53..421de18  main -> main`. `origin/main` HEAD is now
  `421de18`. Verified via `git fetch origin main` + `git log origin/main`.

### Suggested next steps (none in flight)

Phase 4 Slice 1 fully delivers the design goals from the original Phase
4 plan: load `baby_platter.json` only in DEBUG, never ship it, keep the
path explicit and opt-in, preserve production behaviour when the env
var is absent, leave the implementation slice extremely small and
reversible, and allow for future local fixtures by parameterising the
env-var name in a later slice if a second fixture appears.

Possible future slices (each its own approval, **not in scope now**):

- **Slice 2 (deferred).** Extract `loadDebugPlatterFixture()` into a
  standalone file `ScratchLabDesktop/Services/Debug/PlatterFixtureLoader.swift`
  with its own `PlatterFixtureLoaderTests`. Costs 2 new files + 4
  pbxproj inserts (Sources phase only, never Resources). Only worth it
  when a second consumer or a second fixture appears.
- **Slice 3 (deferred).** Generalise the env-var name to
  `SCRATCHLAB_DEBUG_PLATTER_FIXTURE_PATH` with `BABY_PLATTER_FIXTURE_PATH`
  as a backward-compat alias, once a second fixture (e.g. scribble,
  transformer) is authored.
- **Hidden debug UI (deferred).** A DEBUG-only menu / file picker so
  fixtures can be swapped at runtime without scheme edits. Bigger
  slice; only justified if Karl wants interactive fixture-switching.

### Constraints still active

- No app code changes pending review (other than the AI_HANDOFF.md
  edit producing this entry).
- No model training. No model bundling.
- No export-schema changes.
- No scoring / Practice / coaching changes.
- No signing / bundle ID / entitlements / `Info.plist` /
  `PrivacyInfo.xcprivacy` / `Copy Bundle Resources` changes.
- No `Co-Authored-By` trailers.
- **Do not stage or commit anything — including this `AI_HANDOFF.md`
  update — without Karl's explicit approval after review.**

---

## 2026-05-24 — Local-only `baby_platter.json` fixture pipeline LANDED (commit `78f321a`, pushed)

Pipeline to generate a real-motion `PlatterPositionTimeline` JSON
fixture from Karl's own owned demo video, for **test use only**. The
fixture itself is **not** in the commit — only the tooling that
generates it and the validation test that checks it. The fixture is
gitignored, non-bundled, and gated behind the
`BABY_PLATTER_FIXTURE_PATH` env var. Unblocks the Phase 4 BLOCKED
entry below (in this same file).

### Commit

- **SHA**: `78f321a`
- **Subject**: `Add local-only baby platter fixture pipeline`
- **Pushed to `origin/main`**: `14aeace..78f321a  main -> main`
- **Footprint**: 8 files changed, 1065 insertions, 0 deletions.
- **No `Co-Authored-By` trailer** (per `feedback_no_coauthor_trailer`
  memory and `SOUL.md`).

### Purpose

Produce a real, auditable `PlatterPositionTimeline` JSON fixture
from Karl-owned material, on demand, without:

- using `reference_frames/` or `reference_videos/` (off-limits per
  `SOUL.md`);
- using any CV / AI / classifier output;
- bundling any of it into a build product;
- committing the fixture itself;
- touching the production renderer, classifier, scoring, capture
  pipeline, or export schema.

The fixture is intended as the first real consumer-shaped artifact
for Phase 4-style non-bundled loader work.

### Files added (committed)

| Path | Purpose |
|---|---|
| `Tools/Fixtures/extract_frames.sh` | ffmpeg + ffprobe wrapper: PNG frames + per-frame PTS sidecar. Idempotent re-runs. |
| `Tools/Fixtures/click_baby_platter.py` | Python tkinter axis setup + per-frame marker click loop. Includes 20-px min-distance guard and degenerate-axis auto-discard (Slice 2.1 retrofit caught a real bug). |
| `Tools/Fixtures/click_to_platter_timeline.py` | Converter: projects clicks onto axis, normalises by image width, linear interpolation between clicked frames. Refuses to run on a degenerate axis (no auto-derivation; PCA fallback was proposed, rejected by Karl, removed). |
| `Tools/Fixtures/README.md` | Six-step runbook + "what this is not" boundaries + `xcrun xctest` workaround callout. |
| `Tests/Fixtures/LocalOnly/.gitignore` | Local-only safety: gitignores `*.mov`, `*.mp4`, `frames/`, `baby_platter.json`. |
| `ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests.swift` | Five tests; four env-gated, one always-runs bundle-absence guard. |

### Files modified (committed)

- `.gitignore` — added `.scratch_fixture_work/` for extracted frames
  and per-frame timestamps under the existing "Local / offline scratch
  training data" section.
- `ScratchLab.xcodeproj/project.pbxproj` — **4 line insertions**, all
  inside the `ScratchLabDesktopTests` test target only:
  - `PBXBuildFile` entry (line ~151) for the new test
  - `PBXFileReference` entry (line ~345)
  - `PBXGroup` child under `ScratchLabDesktopTests` (line ~434)
  - Sources build phase `F9TESTSRC10AA0010AA10AA` (line ~1075)
  - New UUIDs: `BPF0010000BPF001BPF00001` (file ref) and
    `BPF0011000BPF001BPF00001` (build file). Zero collisions.
  - **No** entries added to any `PBXResourcesBuildPhase`, Copy Bundle
    Resources phase, or non-test target. Confirmed via grep.

### Validation results

| Gate | Command | Result |
|---|---|---|
| iOS build | `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'` | exit 0 ✓ |
| macOS build-for-testing | `xcodebuild build-for-testing -scheme ScratchLab -destination 'platform=macOS'` | `** TEST BUILD SUCCEEDED **` ✓ |
| Test symbols linked | `nm` on built `.xctest` | `BabyPlatterFixtureDecodeTests` Swift symbols present ✓ |
| Test run, no env var | `xcrun xctest -XCTest …BabyPlatterFixtureDecodeTests <bundle>` | 4 skipped + 1 passed (`testFixtureNotBundled` always runs) ✓ |
| Test run, env var set | same, with `BABY_PLATTER_FIXTURE_PATH=$PWD/Tests/Fixtures/LocalOnly/baby_platter.json` | **5 passed, 0 failures** in 0.169 s ✓ |
| Swift Codable round-trip | `swift` one-shot using the production `PlatterPositionTimeline` (lines 1-172 extracted to avoid pulling in `CaptureCore`) | decode → re-encode → decode → Equatable equality ✓; all values finite; samples monotonic by time; confidences in `[0, 1]` ✓ |

Per `project_test_runner_hang` memory, `xcodebuild test` hangs on the
macOS test-host install on this machine. Both runtime test runs above
used `xcrun xctest` on the built `.xctest` bundle, with a
DerivedData-scoped symlink
(`xctest/Contents/Frameworks/ScratchLab.debug.dylib →
../../../../MacOS/ScratchLab.debug.dylib`) to bridge the `@rpath`
gap. **That symlink lives inside `~/Library/Developer/Xcode/DerivedData/`
and is not part of the commit.** The README documents the workaround
in a "Known macOS workaround" callout.

Fixture characteristics on Karl's first valid generation:

- **Source**: `~/Downloads/demo_baby_scratch.mov`, 3840×2160 @ 24 fps,
  26.75 s, 642 frames.
- **Axis**: `axis_start = (1657.6, 1228.8)`, `axis_end = (195.2, 931.2)`,
  unit vector `(-0.9799, -0.1994)` (left-to-right platter travel).
- **Samples**: 637 (190 confidence-1.0 clicked, 447 confidence-0.75
  interpolated).
- **Time span**: `0.000 … 26.500 s`.
- **Position range**: `0.086 … 0.389` (span 0.303 of normalised image
  width), 9 midpoint sign-flips — confirms back-and-forth baby-scratch
  motion.

### What is intentionally NOT committed / NOT bundled

| Path | State | Why |
|---|---|---|
| `Tests/Fixtures/LocalOnly/baby_platter.json` | On disk 63 KB, gitignored | Each developer (currently just Karl) regenerates from their own owned source. Never ships. |
| `.scratch_fixture_work/baby_platter/frames/*.png` | On disk ~2.6 GB, gitignored | Intermediate; can be regenerated by `extract_frames.sh`. |
| `.scratch_fixture_work/baby_platter/frames/timestamps.csv` | On disk, gitignored | Per-frame PTS sidecar; regenerated. |
| `.scratch_fixture_work/baby_platter/axis.json` | On disk, gitignored | Provenance for the manual axis setup; regenerated per session. |
| `.scratch_fixture_work/baby_platter/clicks.csv` | On disk, gitignored | Raw click coordinates; regenerated per session. |
| `~/Downloads/demo_baby_scratch.mov` | Outside the repo entirely | Source media; referenced only via `BABY_PLATTER_VIDEO_PATH`. |
| Anything under `Tests/Fixtures/LocalOnly/` | Outside any Xcode source group | Verified: zero hits for `baby_platter*` in any `PBXResourcesBuildPhase` in `project.pbxproj`. |
| Training-data status | Not training data | Lives under `Tests/Fixtures/LocalOnly/`; `TrainModels` and dataset loaders do not scan this path. |

The `testFixtureNotBundled` test runs on every `xcodebuild test`
invocation (including `nil` env-var) and **fails** if
`baby_platter.json` ever appears in `Bundle.main`, `Bundle.allBundles`,
or `Bundle.allFrameworks` — the bundle-safety net for any future PR.

### Remaining dirty items in the working tree (untouched by this work)

Per `SOUL.md` "preserve unrelated dirty":

```
 M  ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
 ?? reference_frames/
 ?? reference_videos/
```

- `xcschememanagement.plist` — Xcode scheme-management drift, pre-existing
  at session start.
- `reference_frames/` and `reference_videos/` — pre-existing untracked,
  remain **off-limits** per `SOUL.md` ("Do not use YouTube/Ortofon
  material for training") and the prior `AI_HANDOFF.md`
  reference-material quarantine. The fixture pipeline did not touch
  either directory.

This `AI_HANDOFF.md` itself is also dirty (this edit). Not staged. Not
committed. Awaiting Karl's review per the constraint below.

### Slice ledger (for traceability)

- **Slice 1** — `Tools/Fixtures/extract_frames.sh` + repo-root
  `.gitignore` edit. Verified end-to-end: 642 PNGs + 642-line
  `timestamps.csv` produced in 1m50s.
- **Slice 2** — `Tools/Fixtures/click_baby_platter.py`. Parse helpers
  smoke-tested headlessly; GUI walked by Karl.
- **Slice 2.1 (retrofit)** — min-distance axis guard + degenerate-axis
  auto-discard. **Caught a real degenerate-axis bug Karl hit during
  initial use** (saved axis was `(681.6, 1670.4)` twice; subsequent
  relaunches silently reused the bad axis until the auto-discard logic
  landed).
- **Slice 3** — `Tools/Fixtures/click_to_platter_timeline.py` +
  `Tests/Fixtures/LocalOnly/.gitignore`. Initial PCA fallback proposed,
  **rejected by Karl mid-slice** ("Do not use PCA fallback for the real
  fixture yet … was user setup error"), removed; converter now exits
  non-zero on a degenerate axis with a clear redo-axis-setup message.
- **Slice 4** — `BabyPlatterFixtureDecodeTests.swift` + 4 pbxproj
  inserts. Both env-states verified pass.
- **Slice 5** — `Tools/Fixtures/README.md`.

### Next recommended step

**Phase 4 planning ONLY**, using the local fixture via
`BABY_PLATTER_FIXTURE_PATH`. The "Phase 4 BLOCKED" entry further down
this file (also dated 2026-05-24) lists three gates:

| Gate | Status now |
|---|---|
| (a) a real fixture file from Karl | ✓ now produced on demand by this pipeline |
| (b) Karl's explicit "go" message for Phase 4 specifically | **not yet given** |
| (c) `reference_frames/` / `reference_videos/` remain off-limits | ✓ confirmed; today's work did not touch either |

Suggested next prompt when Karl is ready (paste verbatim into a fresh
session or into ChatGPT for an architect-side plan):

```
Plan only. Do not modify app code.

Phase 4: design a non-bundled in-app loader path that can read a
PlatterPositionTimeline JSON from a developer-supplied URL gated by
the BABY_PLATTER_FIXTURE_PATH env var (or an equivalent #if DEBUG
mechanism), without touching:
  - the live capture pipeline (PlatterPositionRecorder, MacCaptureEngine)
  - the v4 session export schema
  - Practice / coaching / scoring
  - Copy Bundle Resources phases
  - signing / bundle IDs / Info.plist / PrivacyInfo.xcprivacy
  - the production renderer (ScratchMotionRenderer)

The fixture format is exactly the schema in
ScratchLab/Models/PlatterPositionTimeline.swift:20-172 and the test
fixture lives at Tests/Fixtures/LocalOnly/baby_platter.json
(gitignored, generated by Tools/Fixtures/click_to_platter_timeline.py).
The validation harness in
ScratchLabDesktopTests/BabyPlatterFixtureDecodeTests.swift already
guards bundle-absence and basic shape.

Output: file paths to touch, smallest-safe slice recommendation,
risk analysis, and explicit STOP for approval before any code.
```

### Constraints still active

- No app code changes pending review.
- No model training. No model bundling.
- No export-schema changes.
- No scoring / Practice / coaching changes.
- No signing / bundle ID / entitlements / `Info.plist` /
  `PrivacyInfo.xcprivacy` / `Copy Bundle Resources` changes.
- No `Co-Authored-By` trailers.
- **Do not stage or commit anything — including this `AI_HANDOFF.md`
  update — without Karl's explicit approval after review.**

---

## 2026-05-24 — Phase 3.4 DEBUG mini trace preview VISUALLY CONFIRMED

Smoke-test pass on a fresh take. The DEBUG raw-platter card now
carries a visual shape preview alongside its numeric rows.

- **Commit verified**: `e34325c` (`Phase 3.4: add DEBUG mini trace
  preview to Review platter card`).
- **Screenshots**:
  - `/Users/karlwatson/Desktop/Screenshot 2026-05-24 at 4.27.02 PM.jpeg`
    (Karl's capture — primary evidence)
  - `/tmp/scratchlab_phase34_trace.png` (Claude's mirror capture)
- **Review card showed (new Phase 3.4 elements)**:
  - Header: **"Raw platter timeline (debug)"** with **Present** badge
  - Label: **"Position over time (auto-scaled)"** (9 pt secondary text)
  - Visible **green mini trace / polyline** in a 40 pt canvas,
    auto-scaled to the timeline's own positionRange (no zero
    baseline). Multiple peaks and valleys visible — consistent with
    a take whose position straddles zero.
- **Visible raw timeline values from this take**:
  - Sample count: **63**
  - Time range: **0.0 – 8.23581362501136**
  - Duration: **8.236 s**
  - Position range: **−0.0668904185295105 – 0.1155923389434814**
  - Source: **liveCapture**
- **Selector-floor honesty note**: derived sample rate ≈
  `63 / 8.236 ≈ 7.7 Hz`, which is **below** the Phase 2
  `shouldRenderRawTrace` 10 Hz selector floor (see
  `LaneContent.defaultMinimumSampleDensity`). If/when a future
  consumer routes this timeline through the production renderer
  fork, it would fall back to the classified-stroke path for this
  take. The Phase 3.2 / 3.4 DEBUG diagnostic card is independent
  of that gate — it shows the captured raw data regardless of
  selector eligibility, which is the right behaviour for a
  developer diagnostic.
- **Phase 3.3 mixed-state copy also still visible on this fresh
  take** (architecture is robust across different capture
  characteristics, not just the Take 002 case from the Phase 3.3
  smoke test):
  - Stage card header: `Raw motion · no classified strokes`
  - Stage card subtitle: `Raw platter motion was captured but
    couldn't be converted into notation.` / `Motion captured for
    diagnostics only.`
  - Sidebar availability label: `No classified strokes — raw
    motion was captured but couldn't be converted into notation.
    Diagnostics only.`
  - Pills: `Record movement 0` / `Audio 1` / `Fader 0` /
    `Mixer MIDI 0`
- **Conclusion**: the Review diagnostic surface now shows both raw
  motion status (Phase 3.2 numeric rows + Phase 3.3 mixed-state
  copy) AND a visual shape preview (Phase 3.4 trace), independent
  of classified-stroke success. Developers can see what the
  producer captured at a glance, with no risk of the diagnostic
  leaking into user-facing notation (still `#if DEBUG` only,
  stripped from release builds, never exported, never scored).
- **Constraints honoured during the smoke test**: no app code
  touched, no commit, no push, no fixture work, no
  `reference_frames/` / `reference_videos/` / `xcschememanagement.plist`
  touched.

---

## 2026-05-24 — Phase 3.3 mixed-state Review copy VISUALLY CONFIRMED

Smoke-test pass on a real take. Recording the evidence here so the
Phase 3.3 result survives `/clear` and future agents can find the
proof without re-running the smoke test.

- **Commit verified**: `2d42ef5` (`Phase 3.3: distinguish raw motion
  vs classified strokes in Review`).
- **Screenshot**: `/tmp/scratchlab_phase33_observe.png` — full Review
  tab on Take 002, mixed-state copy rendered.
- **Review tab showed (new Phase 3.3 mixed-state copy)**:
  - Stage-card header: **"Raw motion · no classified strokes"**
  - Stage-card subtitle line 1: **"Raw platter motion was captured
    but couldn't be converted into notation."**
  - Stage-card subtitle line 2: **"Motion captured for diagnostics
    only."**
  - Sidebar availability label: **"No classified strokes — raw
    motion was captured but couldn't be converted into notation.
    Diagnostics only."**
- **Old misleading copy was ABSENT** (confirms the gate is
  branching correctly):
  - "Audio-only take" — not present
  - "Hand motion wasn't detected" — not present
  - "No record movement detected." — not present
- **Captured-evidence counts remained accurate** (pills in the
  stage card, unchanged from pre-Phase-3.3):
  - Record movement **0**
  - Audio **1**
  - Fader **0**
  - Mixer MIDI **0**
- **Implicit predicate evidence**: the mixed-state copy ONLY fires
  when `MacAnalyzerView.hasRawMotionWithoutClassifiedStrokes`
  evaluates true. Its appearance in the rendered UI is direct
  evidence that:
  - `captureEngine.lastDrainedPlatterPositionTimeline != nil`
  - `timeline.samples.isEmpty == false`
  - `currentRoutineNotationSnapshot.recordMovementEvents.isEmpty`
- **Conclusion**: the Review surface now correctly distinguishes
  raw motion evidence (`PlatterPositionRecorder` output) from
  classified-stroke evidence (the legacy `RoutineDetectedNotationBuilder`
  → `recordMovementEvents` pipeline). The Phase 3.2 architectural
  mismatch ("Audio-only take" claimed when raw motion was present)
  is no longer surfaced to users; the new copy honestly explains
  the state.
- **Constraints honoured during the smoke test**: no app code
  touched, no commit, no push, no fixture work, no
  `reference_frames/` / `reference_videos/` / `xcschememanagement.plist`
  touched.

---

## 2026-05-24 — Phase 3.3 Review mixed-state UX (uncommitted, awaiting approval)

Direct follow-up to the Phase 3.2 visual-confirmation finding. The Review
surface now stops claiming "no motion happened" when the raw platter
pipeline captured signal that the classified-stroke pipeline missed.

- **Slice status: uncommitted, awaiting Karl's approval.** Working
  tree has two modified files. Nothing staged. No commit, no push.
- **Scope honoured**:
  - macOS only.
  - Only the Review surface changes user-visible behaviour. Practice,
    Capture, Advanced, Coach, scoring, exports, schema, renderer,
    fixtures, PlatterPositionRecorder, HandDirectionTracker,
    classifier thresholds: all untouched.
  - No new persistence. No networking. No iOS changes. No pbxproj
    edits.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` preserved as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer.
- **Files modified** (two):
  - `ScratchLabDesktop/Views/MacAnalyzerView.swift` (+59 / −10):
    - New private predicate
      `hasRawMotionWithoutClassifiedStrokes`: `Bool` (placed next to
      `hasPartialReviewNotation`). Returns `true` iff
      `captureEngine.lastDrainedPlatterPositionTimeline` is non-nil
      with `!samples.isEmpty` AND
      `currentRoutineNotationSnapshot?.recordMovementEvents` is
      empty (or the snapshot itself is nil). Strictly Review-side
      diagnostic; does NOT feed scoring/export/notation.
    - Four mixed-state-aware copy adjustments, all of which only
      change wording when both `hasPartialReviewNotation` AND
      `hasRawMotionWithoutClassifiedStrokes` are true; the
      true-audio-only fork keeps its existing wording byte-identically:
      1. `reviewDecisionSummary` (line ~1518): adds
         `"No classified strokes · Raw motion captured for diagnostics only"`.
      2. `reviewNotationAvailabilityMessage` (line ~1663): adds
         `"No classified strokes — raw motion was captured but couldn't be converted into notation. Diagnostics only."`.
      3. `miniNotationTimeline` (line ~5640): replaces the three
         existing Text lines with mixed-state-aware variants:
         `"No classified strokes"` / `"Raw motion captured for diagnostics only."`
         / `"Review timing and motion diagnostics."`.
      4. `reviewCapturedNotationStageCard` call to
         `CapturedNotationDisplayView(snapshot:)` (line ~3435): now
         passes `mixedStateHint: hasRawMotionWithoutClassifiedStrokes`.
  - `ScratchLabDesktop/Views/NotationVisualizerView.swift` (+50 / −16):
    - `CapturedNotationDisplayView` gains one new property:
      `var mixedStateHint: Bool = false`. Default false preserves
      the Advanced-tab call site
      (`NotationVisualizerView.swift:348`) byte-identically; only
      the Review call site (`MacAnalyzerView.swift:3435`) passes
      `true` when the mixed state is detected.
    - Two `isAudioOnlyPartial` forks rewritten to branch on
      `mixedStateHint`:
      - `summaryHeader`'s `sourceLabel` (line ~994): "Audio-only
        take" → `"Raw motion · no classified strokes"` when
        mixed-state.
      - `summaryHeader`'s subtitle block (line ~1031): swaps "Hand
        motion wasn't detected — review timing only." /
        "No record movement detected." for "Raw platter motion was
        captured but couldn't be converted into notation." /
        "Motion captured for diagnostics only."
      - `partialMovementPlaceholder` (line ~1256): swaps the same
        misleading-pair for the mixed-state copy used in
        `miniNotationTimeline`.
- **Why two files instead of one**: the visible "Audio-only take"
  copy in the Review tab's right-hand `Captured evidence` card lives
  in `CapturedNotationDisplayView` inside `NotationVisualizerView.swift`,
  which is also rendered by the Advanced tab. To avoid changing
  Advanced behaviour, the parameter is opt-in and defaults to false.
  This satisfies the "Modify only the Review surface" constraint at
  the behaviour level: Advanced is the ONLY other caller and it
  doesn't pass the parameter, so its rendered output is unchanged.
- **Mixed-state-aware copy (only fires when predicate is true)**:
  - **Sidebar mini-timeline**: `No classified strokes` / `Raw motion
    captured for diagnostics only.` / `Review timing and motion
    diagnostics.`
  - **Decision summary**: `No classified strokes · Raw motion
    captured for diagnostics only`
  - **Availability label**: `No classified strokes — raw motion was
    captured but couldn't be converted into notation. Diagnostics
    only.`
  - **Captured-evidence stage card header**: `Raw motion · no
    classified strokes`
  - **Captured-evidence stage subtitle**: `Raw platter motion was
    captured but couldn't be converted into notation.` / `Motion
    captured for diagnostics only.`
  - **Captured-evidence partial-placeholder**: `No classified
    strokes` / `Raw motion captured for diagnostics only.` /
    `Review timing and motion diagnostics.`
- **True-audio-only behaviour unchanged**: when no raw timeline was
  drained (or drained empty) AND classified strokes are empty, the
  Review still says "Audio-only take" / "Hand motion wasn't detected"
  exactly as before. Only the new mixed state gets the new copy.
- **Phase 3.2 DEBUG raw-platter card unchanged**: still present in
  `reviewSidebar` under `#if DEBUG`, still reads
  `captureEngine.lastDrainedPlatterPositionTimeline` directly, still
  shows sample count / time range / duration / position range /
  source.
- **Builds run**:
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
  - iOS build NOT re-run (no iOS code changed; the two modified
    files are both in the ScratchLabDesktop target only).
- **Tests run**:
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS' -only-testing:<three platter classes>`
    → **TEST EXECUTE SUCCEEDED**. **32 / 32 passed**, 0 failures.
    No new tests added (this is a UI copy slice; the predicate is a
    pure boolean and its inputs are already covered by existing
    PlatterPositionRecorder + LaneRawTrace + PlatterPositionTimeline
    tests). If Karl wants formal coverage of the predicate, a small
    follow-up test against a synthetic snapshot + synthetic timeline
    would be one assertion.
- **Manual visual verification gap**: I could not screenshot the
  Review tab with the new copy rendered — automation-driven tab
  switching needs Accessibility permission I don't have. The app
  built, launched, and didn't crash, but rendered output of the
  Review-tab Captured-evidence card with the new mixed-state copy
  has NOT been visually confirmed by me. Karl can verify by
  launching the rebuilt app and inspecting the same take that
  produced the Phase 3.2 mismatch (sample count: 152, source:
  liveCapture, classified strokes: 0). Expected: the right-side
  "Captured evidence" card now reads `Raw motion · no classified
  strokes` instead of `Audio-only take`.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLabDesktop/Views/MacAnalyzerView.swift
   M ScratchLabDesktop/Views/NotationVisualizerView.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 3.3 scope only — plist pre-existing dirty):
  ```
  ScratchLabDesktop/Views/MacAnalyzerView.swift          | 59 +++++++++++++++----
  ScratchLabDesktop/Views/NotationVisualizerView.swift   | 67 ++++++++++++++++------
  ```
- **Decision needed from Karl**:
  1. Approve for commit? Suggested commit message:
     `Phase 3.3: distinguish raw motion vs classified strokes in Review`.
  2. Approve `next_prompt.md` rewrite pointing back at Phase 4
     (still blocked on the real fixture), with the Phase 3 / 3.1 /
     3.2 / 3.3 chain now fully on `origin/main` once committed?

---

## 2026-05-24 — Phase 3.2 Review debug card VISUALLY CONFIRMED + raw / classified mismatch surfaced

The DEBUG raw-platter-timeline card shipped in `09a7d53` rendered
correctly in the Mac Review tab on a real capture, AND surfaced an
important architectural finding: the new raw pipeline saw motion
that the old classified-stroke pipeline missed.

- **What was tested**: the Phase 3.2 inspector card on the Mac
  Review tab, after running a real macOS routine recording with a
  hand in front of the camera.
- **Card display (raw pipeline output)**:
  - Status: **Present** (green checkmark)
  - Sample count: **152**
  - Time range: **0.0 – 11.844481916668883** seconds
  - Duration: **11.844 s**
  - Position range: **−0.646200031042099 – 0.0**
  - Source: **liveCapture**
  - Derived sample rate: ≈ **12.8 Hz** — above the Phase 1
    selector's 10 Hz floor.
  - Position range is **entirely negative** — the integrator never
    crossed zero. Consistent with a clean sustained backward push
    or a sequence of backward strokes; signed integration is
    producing meaningful directional data.
- **Same Review screen, classified-stroke pipeline output (existing
  notation detector)**:
  - "**Audio-only take. Hand motion wasn't detected — review
    timing only.**"
  - Stroke count: **0**
  - Audio event count: **1**
  - Fader event count: **0**
  - Mixer MIDI count: **0**
  - Captured evidence pills: `Record movement 0`, `Audio 1`,
    `Fader 0`, `Mixer MIDI 0`
  - Confidence chip: `45% confidence` / `audio` / `Audio
    inferred`.
- **Architectural conclusion**: the raw platter-position pipeline
  (Phase 1/2/3/3.1) can capture live hand motion **independently
  of** the classified-stroke detector (`RoutineDetectedNotationBuilder`
  → `DetectedNotationRecordMovementEvent`s → `recordMovementEvents`).
  The classified detector's hysteresis + confidence + semantic-
  direction-change gates rejected the take's motion entirely, but
  the raw `Δx`-integration in `PlatterPositionRecorder` retained
  152 honest samples spanning a non-trivial signed range. This is
  direct evidence that:
  1. The two pipelines have **different failure modes**. The raw
     channel is more forgiving and produces signal even when the
     classified channel produces nothing.
  2. The classified detector's "Hand motion wasn't detected" claim
     is now demonstrably **incomplete** when raw samples exist.
  3. Future Practice / Review / Coach surfaces should not treat
     "no classified strokes" as equivalent to "no motion captured"
     — the two can disagree.
- **Implication for the existing user-facing copy**: the Review
  Captured-evidence card today reads as "no motion" in this exact
  case. With Phase 3.2 in DEBUG only, only developers see the
  raw-timeline contradiction. End-users would see only the
  misleading "Audio-only take" message.
- **Recommended next slice — Phase 3.3 — make Review explain this
  mixed state cleanly** (planning only, NOT scoped in this entry):
  - Surface the raw-timeline presence in a way that doesn't claim
    classified-stroke data exists.
  - Decide whether the "Hand motion wasn't detected" copy should
    soften / change when a non-empty raw timeline is present
    (e.g., "No classified strokes — raw motion captured for
    diagnostics only").
  - Decide whether the raw timeline should EVER feed into anything
    user-facing (scoring? Coach feedback? export?) or stay
    strictly diagnostic. Default per `PROFILE.md` is strictly
    diagnostic until calibration + accuracy are proven.
  - Scope must respect SOUL.md / PROFILE.md constraints: no
    scoring changes, no Practice/coaching changes, no export
    schema changes unless explicitly approved.
- **Constraints honoured by this finding**: no app code touched,
  no project file touched, no fixtures, no `reference_*`, no
  `xcschememanagement.plist`. This is documentation only.

---

## 2026-05-24 — iOS Phase 3.1 equivalent NOT NEEDED (investigation only)

Read-only investigation of whether iOS needs its own `PlatterPositionRecorder`
wiring. Recording here so future agents searching for "iOS Phase 3.1" find
the rationale without re-investigating.

- **Finding**: no iOS Phase 3.1 equivalent is needed right now.
- **Reason**: iOS does not have a local hand-tracking / Vision /
  `(rawPoint, time)` sample pipeline at all.
  - `CompanionCameraBroadcaster.captureOutput(_:didOutput:from:)`
    (line ~863 in `ScratchLab/Services/CompanionCameraBroadcaster.swift`)
    only forwards / JPEG-encodes frames for broadcast to macOS over
    MultipeerConnectivity. It does NOT run Vision and does NOT
    produce platter-position samples.
  - `PracticeModeView.CameraPreviewView`
    (`ScratchLab/Views/PracticeModeView.swift:1372`) is a bare
    `AVCaptureSession` + `AVCaptureVideoPreviewLayer` for visual
    reference only. No `AVCaptureVideoDataOutput`, no sample-buffer
    delegate, no Vision, no recorder path.
  - Zero iOS-target references to `HandDirectionTracker`,
    `VNDetectHumanHandPoseRequest`, or any of the sample-stream
    types Phase 3.1 consumes.
- **Therefore**: `PlatterPositionRecorder.observe(point:at:)` has
  nowhere safe to mount on iOS today. There is no producer to feed
  it, no recording lifecycle (`startRoutineRecording` /
  `finalizeRoutineRecording` don't exist on iOS) to bracket it
  with, and no `lastDrainedPlatterPositionTimeline` consumer to
  read it.
- **iOS debug UI implication**: a Phase 3.2-equivalent card on iOS
  would only ever show "Missing" until either (a) macOS relays raw
  timeline data back over MultipeerConnectivity, or (b) iOS gains
  its own Vision pipeline. Neither change is in scope.
- **Current recommendation: zero iOS code changes.** macOS Phase 3.1
  (commit `7e3286d`) and Phase 3.2 (commit `09a7d53`) ship as the
  full producer + DEBUG inspector surface. iOS remains a passive
  camera/audio source streaming to macOS.
- **Future options if Karl ever decides iOS needs a raw timeline**
  (NOT in scope now — each is its own planning slice):
  1. Add a full iOS Vision / hand-tracking pipeline (heavy:
     duplicates the macOS Vision loop, doubles maintenance,
     device-CPU/thermal budget needs validation).
  2. Relay macOS raw samples / timeline back to iOS via the
     existing `MCSession` (medium: new packet type, end-to-end
     latency, iOS card renders second-hand data).
  3. Promote / tune `HandDirectionTracker` for shared use across
     both targets (conceptually clean but its history + hysteresis
     are tuned for macOS capture cadence; iOS may need different
     parameters, risking Phase 1 invariants).
- **Constraints honoured by this finding**: no app code touched,
  no project file touched, no fixtures, no `reference_*`, no
  `xcschememanagement.plist`. Plan file lives at
  `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  with the full per-question breakdown.

---

## 2026-05-24 — Phase 3.1 MacCaptureEngine wiring smoke test PASSED

Real macOS capture exercised the wiring end-to-end. Recording the
result here so it survives `/clear` and future agents can find it
without re-running the smoke test.

- **What was tested**: Phase 3.1 wiring (commit `7e3286d` on
  `origin/main`) — `PlatterPositionRecorder` mounted inside
  `MacCaptureEngine`'s start / observe / drain lifecycle.
- **How**: Karl ran the macOS `ScratchLab.app` manually, started a
  routine recording via the Capture surface, moved a hand in front
  of the camera, and stopped the recording. The drain block in
  `finalizeRoutineRecording` executed and a temporary one-line
  diagnostic print (since reverted) reported the drained timeline's
  shape.
- **Result**: `finalizeRoutineRecording` reached, drain hook fired,
  `lastDrainedPlatterPositionTimeline` was **non-nil**. Exact
  numbers from the run:
  - `sampleCount` = **261**
  - `timeRange` = **0.0 … 22.69094208333263** seconds
  - `positionRange` = **−0.0806029886007309 … 0.7671469897031784**
    (unbounded signed platter-axis displacement units, per the Phase
    1 docstring on `PlatterPositionSample`)
- **Derived sanity**: ~261 samples / 22.69 s ≈ **11.5 Hz** — above
  the Phase 1 selector's 10 Hz floor with margin, consistent with
  `activeHandPoseInterval` at the active routine-recording cadence.
  The positionRange straddles zero with a non-trivial span, which
  is direct evidence the `Δx` integration produces signed motion in
  both directions (not a stuck-at-zero or one-sided integrator bug).
- **State after smoke test**:
  - Temporary diagnostic `print(...)` block has been **reverted**.
  - `MacCaptureEngine.swift` is byte-identical to `origin/main`'s
    Phase 3.1 commit (`7e3286d`).
  - **No source-code changes remain** from the diagnostic.
  - `git diff -- ScratchLabDesktop/Services/MacCaptureEngine.swift`
    is empty.
  - Remaining dirty / untracked files are only the same
    pre-existing entries from earlier sessions:
    `ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist`
    (modified-unstaged), `reference_frames/` (untracked),
    `reference_videos/` (untracked).
- **Implication for future work**:
  - The Phase 3 + Phase 3.1 producer side is **functionally
    verified** against real camera input. Future consumer slices
    (renderer overlay, fixture comparison, captured-user trace) can
    rely on `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
    being populated after every successful routine recording.
  - Phase 4 (companion loader + non-bundled fixture) remains
    blocked on Karl-provided `baby_platter.json` — see entry below.

---

## 2026-05-24 — Phase 4 BLOCKED — awaiting real `baby_platter.json` from Karl

Phase 4 (companion loader + non-bundled fixture) is **paused**. No
work — no code, no scaffolding, no placeholder JSON. Karl is the
single source of truth for the fixture content and has not yet
provided it.

- **Why blocked**: I cannot author a meaningful raw-platter fixture
  myself. I have no computer-vision capability, and the only
  available reference material in the workspace
  (`reference_frames/`, `reference_videos/`) is **off-limits for
  bundling or for derived assets** per `SOUL.md` ("Do not use
  YouTube/Ortofon material for training.") and the prior
  `AI_HANDOFF.md` entry quarantining them as local-analysis-only.
- **Karl's locked constraints**:
  - Do **NOT** use `reference_frames/` or `reference_videos/` —
    not as a source, not as a derivative, not as inspiration for a
    synthetic surrogate.
  - Do **NOT** bundle fixture data into any Copy Bundle Resources
    phase. The fixture, when it exists, lives outside the app
    bundle (e.g., `ScratchLabDesktopTests/Fixtures/baby_platter.json`
    or similar test-only path).
  - Do **NOT** create a placeholder JSON or synthesise content as a
    substitute for the real fixture. An empty / fake fixture is
    worse than no fixture because it would let tests pass on
    contentless data.
- **Unblock signal**: a real `baby_platter.json` (hand-authored or
  commissioned) appears in the working tree at a non-bundled path,
  AND Karl explicitly approves resuming Phase 4. Until then,
  `AI_HANDOFF/next_prompt.md` gates the slice as DO-NOT-START.
- **What still works after Phase 3.1**:
  - The full `PlatterPositionRecorder` → `MacCaptureEngine` wiring
    is live on `origin/main` (commit `7e3286d`). Every macOS
    routine recording produces a `PlatterPositionTimeline` and
    stashes it in `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
    (in-memory; v4 export schema unchanged).
  - No consumer reads that property yet. Phase 4's loader + tests
    would have been the first consumer-shaped slice; that's now
    deferred along with the rest of Phase 4.
- **Most useful manual smoke test available right now (no code
  changes required from Claude)**:
  1. Build and run `ScratchLabDesktop` on macOS.
  2. Start a routine recording via the Mac Analyzer surface.
  3. Move the tracked hand in front of the camera so
     `HandDirectionTracker.recordObservation(...)` receives
     non-trivial samples.
  4. Stop the recording cleanly (so `fileOutput(...didFinishRecordingTo:)`
     fires and `finalizeRoutineRecording` runs).
  5. Inspect `MacCaptureEngine.lastDrainedPlatterPositionTimeline`
     (via debugger, Xcode preview, or a temporary `print`):
     - Expected: **non-nil** `PlatterPositionTimeline` with
       `samples.count > 0`, `endTime > startTime`,
       `positionRange` spanning a non-trivial range when the hand
       actually moved.
     - If nil after a real move: the wiring did not fire —
       investigate `processVideoSampleBuffer`'s observe call site
       or the `platterPositionRecorder.isRecording` gate.
- **Reminder to anyone reopening Phase 4**: respect the prior
  pre-flight gates in `AI_HANDOFF/next_prompt.md`. Do not start
  without (a) a real fixture file from Karl, (b) Karl's explicit
  "go" message, AND (c) acknowledgement that the
  `reference_frames/` / `reference_videos/` material remains
  off-limits.

---

## 2026-05-24 — Phase 3.1 MacCaptureEngine wiring (uncommitted, awaiting approval)

Karl's Phase 4 pre-flight pivot: Phase 4 (bundled fixture) is paused
because the slice as written required manual angle extraction from a
reference video — which I can't do (no vision) and which would also
violate `SOUL.md` (`reference_frames/` + `reference_videos/` are
local-analysis-only, not shippable). Instead we ship the Phase 3
wiring follow-up first — mounting `PlatterPositionRecorder` inside
`MacCaptureEngine` so live takes actually produce a raw timeline.

- **Slice status: uncommitted, awaiting Karl's approval.** Working
  tree has one modified file (`MacCaptureEngine.swift`). Nothing
  staged. No commit, no push.
- **Pre-flight decisions captured for future Phase 4 (when it resumes)**:
  - Fixture source: defer — when Phase 4 resumes, Karl will hand-author
    or commission the JSON externally; I add only the loader + tests.
  - Fixture bundle membership: NOT bundled — keep as a test fixture
    only until a future slice promotes it.
  - Fixture sample rate (when authored): 30 Hz matching live producer.
- **File modified** (one): `ScratchLabDesktop/Services/MacCaptureEngine.swift`
  (+52 lines). Four small additions, all in `ScratchLabDesktop` target:
  1. **Property declaration block** (next to `handDirectionTracker` at
     line ~1736): adds `platterPositionRecorder` (sibling
     `PlatterPositionRecorder` instance), `platterRecordingStartTime`
     (`CFTimeInterval` host-time anchor for the active take),
     `lastDrainedPlatterPositionTimeline` (`PlatterPositionTimeline?`,
     `private(set)` so it's readable from `@testable import` callers
     but only mutable internally), and `platterRecorderLock`
     (`NSLock` — funnels all recorder access through one lock
     because the recorder is touched by `sessionQueue` (start),
     `videoQueue` (observe), and the `AVCaptureFileOutput` delegate
     queue (drain); mirrors the existing `midiCaptureLock` pattern).
  2. **Start hook** (inside `startRoutineRecording`'s sessionQueue
     block, just before `movieOutput.startRecording(...)` at line
     ~2241): under the lock, clears `lastDrainedPlatterPositionTimeline`,
     captures `platterRecordingStartTime = CACurrentMediaTime()`,
     and calls `platterPositionRecorder.startRecording(at: 0)`.
  3. **Observe hook** (inside `processVideoSampleBuffer` immediately
     after the existing `handDirectionTracker.recordObservation(rawPoint:, at: now)`
     call at line ~3230): under the lock, if `platterPositionRecorder.isRecording`,
     computes take-relative time as `max(0, now - platterRecordingStartTime)`
     and calls `platterPositionRecorder.observe(point: rawTrackedPoint, at: ...)`.
     The `isRecording` gate is a perf optimisation — `observe(...)` is
     itself a no-op when not recording per Phase 3 design.
  4. **Drain hook** (inside `finalizeRoutineRecording` immediately
     after the existing `drainCapturedMidiCCEvents()` call at line
     ~2923): under the lock, computes `platterEndRelative = max(0, CACurrentMediaTime() - platterRecordingStartTime)`,
     calls `platterPositionRecorder.finishRecording(at: platterEndRelative)`,
     stores the result in `lastDrainedPlatterPositionTimeline`, and
     resets `platterRecordingStartTime = 0`.
- **Constraints honoured**:
  - `HandDirectionTracker` — NOT modified. The recorder runs in
    parallel; the existing tracker call at line 3230 is unchanged.
  - `PlatterPositionRecorder` (Phase 3 artefact) — NOT modified.
  - `CaptureCore.DetectedNotationSnapshot` — NOT modified. Codable
    shape unchanged; v4 export schema byte-stable.
  - `scratchlab_session_export_v4` and `scratchlab_detected_notation_v1`
    constants — verified byte-stable.
  - No Practice/scoring/coaching code touched. The wiring is purely
    capture-side instrumentation. The drained timeline lives
    in-memory on the engine and is read by no consumer today.
  - No new files added. No pbxproj edits.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID, or
    entitlements changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` preserved as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer.
- **Concurrency**: the new lock (`platterRecorderLock`) serialises
  every recorder access — start, observe, drain — across the three
  queues that touch it. Mirrors the existing `midiCaptureLock`
  pattern used for `capturedMidiCCEvents` / `midiRecordingStartTime`.
- **No dedicated wiring test** (limitation): a true wiring test would
  need an AVCaptureSession + camera permission + mocked video output —
  large test surface for low marginal value, since Phase 3 already
  proved the recorder's contract with 8 unit cases (including
  sibling-tracker non-interference). Phase 3.1 ships the call-site
  additions only; verification is via macOS build + the full Phase 3
  test suite still passing + manual smoke-testing on a live capture
  session when Karl exercises it.
- **Builds run**:
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → NOT re-run this slice. The Phase 3 commit's iOS blockage
    (CoreSimulator service stuck) likely persists; in any case the
    wiring change is in `ScratchLabDesktop/Services/MacCaptureEngine.swift`
    which is macOS-target-only, so iOS behaviour is unchanged.
- **Tests run** (Phase 1 + Phase 2 + Phase 3 + HandDirectionTracker):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS' -only-testing:<four classes>`
    → **TEST EXECUTE SUCCEEDED**. **48 / 48 passed**, 0 failures.
    (16 HandDirectionTracker + 15 Phase 1 + 9 Phase 2 + 8 Phase 3.)
    Including the existing `HandDirectionTrackerTests` re-run is the
    runtime-level evidence that the wiring did not perturb tracker
    behaviour, complementing Phase 3's unit-level non-interference
    assertion.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLabDesktop/Services/MacCaptureEngine.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 3.1 scope only — plist is pre-existing dirty):
  ```
  ScratchLabDesktop/Services/MacCaptureEngine.swift | 52 ++++++++++++++++++++++
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 3.1: wire PlatterPositionRecorder into MacCaptureEngine lifecycle`.
  2. Approve `next_prompt.md` rewrite pointing at Phase 4 (bundled
     fixture), now that the wiring follow-up is resolved?

---

## 2026-05-24 — Phase 3 live producer (uncommitted, awaiting approval)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has 2 new files + 3 modified files (incl. pbxproj). Nothing staged.
  No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (Phase 3 section). Karl's 2026-05-24 pre-flight decisions:
  - Ribbon layout (Phase 2.1/2.2): **settled** — proceed.
  - Sample rate: **tracker-native** (~30 Hz active / ~4 Hz idle).
  - Buffer strategy: **unbounded with end-of-take drain**.
  - Position unit: **raw integrated platter-axis units** (NOT
    revolutions). Phase 1 docstring relaxed to remove the "revolutions"
    claim — exact wording per Karl: *"Unbounded signed platter-axis
    displacement units, produced by integrating normalized tracker
    deltas. Not calibrated to revolutions yet; calibration is deferred
    to a future slice."*
- **Files added** (2 new, untracked at slice end):
  - `ScratchLabDesktop/Services/PlatterPositionRecorder.swift` —
    sibling consumer of `(rawPoint, time)` tracker samples. API:
    `init(source:)`, `startRecording(at:)`, `observe(point:at:)`,
    `finishRecording(at:) -> PlatterPositionTimeline?`,
    `isRecording: Bool`, `sampleCount: Int`. Integration: each
    `observe` accumulates `Δx = point.x - lastPoint.x` into a signed
    running position; the first sample of a recording lands at
    `position = 0`. Confidence = 1.0 for every sample (direct sensor
    reading). Buffer is unbounded; drained + cleared on `finishRecording`.
    Sample times clamped into `[startTime, +∞)` so the Phase 1
    `samples.first.time >= startTime` invariant always holds. End time
    widened on drain if the last sample overshoots the requested
    `endTime` (keeps `samples.last.time <= endTime` invariant).
    Reference type. Single-threaded usage assumed (Phase 3 ships the
    isolated recorder; future wiring slice will mount it inside
    `MacCaptureEngine`).
  - `ScratchLabDesktopTests/PlatterPositionRecorderTests.swift` — 8
    XCTest cases:
    1. Fresh recorder: `!isRecording`, zero samples, drain returns nil.
    2. Integration produces signed running sum from a 4-sample
       deterministic input.
    3. Drained timeline satisfies Phase 1 invariants (sorted samples,
       in-range times, source label preserved).
    4. `finishRecording` widens `endTime` when the last sample
       overshoots the requested value.
    5. State resets between consecutive recordings (running integration
       cleared, new recording starts at position 0).
    6. `observe(...)` outside an active recording is silently ignored.
    7. Empty recording (start without observe) drains to nil.
    8. **Sibling `HandDirectionTracker` non-interference**: a tracker
       running alongside the recorder produces the EXACT same Direction
       sequence as a tracker running alone with the same input. This
       is the strongest single test of "recorder does not modify the
       tracker".
- **Files modified** (3):
  - `ScratchLab/Models/PlatterPositionTimeline.swift` — Phase 1
    docstring on `PlatterPositionSample` relaxed per Karl's wording.
    Inline `positionRange` docstring also updated ("platter-axis
    displacement units" instead of "revolutions"). No API change; no
    Codable shape change.
  - `ScratchLab/Models/ScratchMotionRenderer.swift` — one docstring
    line on the raw-trace velocity-to-thickness mapping updated to
    say "platter-axis displacement units / second" instead of
    "revolutions/second". No code change.
  - `ScratchLab.xcodeproj/project.pbxproj` (+8 lines) — file refs +
    build files for both new files + group entries. UUID prefix `PPR`.
    `PlatterPositionRecorder.swift` mounted in the
    `ScratchLabDesktop/Services` group (next to `HandDirectionTracker.swift`)
    and the ScratchLabDesktop target's Sources phase only.
    `PlatterPositionRecorderTests.swift` mounted in the flat
    `ScratchLabDesktopTests` group + Sources phase (matches Phase 1/2
    convention).
- **Constraints honoured**:
  - `HandDirectionTracker` — NOT modified. The recorder is an
    independent class; test #8 proves non-interference behaviourally.
  - `CaptureCore.DetectedNotationSnapshot` — NOT modified. Codable
    shape unchanged.
  - `scratchlab_session_export_v4` (line 23) — byte-stable, verified.
  - `scratchlab_detected_notation_v1` (line 379) — byte-stable, verified.
  - `MacCaptureEngine` — NOT modified. The recorder is shipped in
    isolation; future wiring slice will mount it in the capture engine.
  - No `.mlmodel` / `.mlmodelc` / `.mlpackage` / resource / Info.plist /
    PrivacyInfo / signing / Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` preserved as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer.
- **Builds run**:
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BLOCKED** by a system-side CoreSimulator service issue that
    surfaced mid-slice ("CoreSimulator is out of date. Current version
    (1051.50.0) is older than build version (1051.54.0). Simulator
    device support disabled."). `xcrun simctl list devices booted`
    still shows the iPhone 17 simulator alive, but `xcodebuild
    -showdestinations` can't see it — xcodebuild's connection to the
    CoreSimulator service is stuck. Recovery typically requires either
    an Xcode restart or `sudo killall -9
    com.apple.CoreSimulator.CoreSimulatorService`, neither of which
    I performed without explicit permission. **Phase 3 only touches
    the ScratchLabDesktop target — no iOS code was modified — so iOS
    behaviour is unchanged by this slice.** Re-run the iOS build
    after Xcode restart to confirm.
- **Tests run** (Phase 1 + Phase 2 + Phase 3 targeted run):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests
    -only-testing:ScratchLabDesktopTests/LaneRawTraceFallbackTests
    -only-testing:ScratchLabDesktopTests/PlatterPositionRecorderTests`
    → **TEST EXECUTE SUCCEEDED**. **32 / 32 passed**, 0 failures, 0
    unexpected. (15 Phase 1 + 9 Phase 2 + 8 Phase 3.) Total ~0.027 s.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLab/Models/PlatterPositionTimeline.swift
   M ScratchLab/Models/ScratchMotionRenderer.swift
  ?? ScratchLabDesktop/Services/PlatterPositionRecorder.swift
  ?? ScratchLabDesktopTests/PlatterPositionRecorderTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 3 scope — plist is pre-existing dirty, new
  files are untracked until staged):
  ```
  ScratchLab.xcodeproj/project.pbxproj             | 8 +
  ScratchLab/Models/PlatterPositionTimeline.swift  | 18 +++++++++-------
  ScratchLab/Models/ScratchMotionRenderer.swift    | 3 ++-
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 3: PlatterPositionRecorder live producer (unwired, tests-only)`.
  2. Accept macOS-only verification given the system-side iOS build
     blockage, or do you want me to attempt a CoreSimulator service
     restart (requires sudo) before commit?
  3. Approve `next_prompt.md` rewrite pointing at Phase 4 (bundled
     fixture + companion producer)?

---

## 2026-05-24 — Phase 2.2 ribbon time-alignment tune (still uncommitted)

Karl's follow-up decision after reviewing 2.1: in portrait the
85%-from-the-left ribbon NOW position was visually awkward (past
dominated the strip). Tune the **ribbon strip viewport only** — the
motion canvas's `actionLineFraction(for:)` stays untouched.

- **Single edit** in `ScratchLab/Views/ScratchMotionLane.swift`:
  - New private helper `ribbonActionLineFraction(for axis:)`:
    - Portrait (`.vertical`) → returns `0.5` (centered NOW on the
      horizontal strip).
    - Landscape (`.horizontal`) → returns
      `actionLineFraction(for: axis)` (i.e., `0.18` — matches the
      motion's action line for direct vertical alignment).
  - `ribbonStrip(width:now:)`'s `LaneViewport` now uses
    `ribbonActionLineFraction(for: axis)` instead of
    `actionLineFraction(for: axis)`.
  - Docstrings on both helpers updated to reflect the Phase 2.2
    decision.
- **No changes to**: the motion canvas's `actionLineFraction(for:)`,
  the renderer (`ScratchMotionRenderer.swift`), capture pipeline,
  export schema (`scratchlab_session_export_v4`,
  `scratchlab_detected_notation_v1` both byte-stable), resources, or
  the test file.
- **No-events fallback unchanged**: the new helper is only consulted
  by `ribbonStrip(width:now:)`, which is only mounted when
  `content.faderEvents` is non-empty. The no-events VStack still
  collapses to a single full-height motion canvas — visually
  identical to pre-Phase-2.
- **Builds re-run** after the 2.2 tune:
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests re-run** (Phase 1 + Phase 2, 24-case targeted):
  - **24 / 24 passed**, 0 failures, total 0.011 s.

---

## 2026-05-24 — Phase 2.1 ribbon layout restructure (still uncommitted)

Karl rejected the Phase-2 portrait side-ribbon placement during review.
This 2.1 pass restructures the lane so the ribbon sits **visually below
the motion canvas in both orientations** before commit.

- **Change shape (delta from the pre-2.1 Phase-2 working tree)**:
  - `ScratchLab/Views/ScratchMotionLane.swift` — `body` is now a
    `VStack(spacing: 0)` of `laneContent(motionViewport)` on top and a
    dedicated `ribbonStrip(width:now:)` Canvas below. The ribbon strip
    height is a new `ribbonStripHeight: CGFloat = 14` constant. The
    ribbon strip is only added when `content.faderEvents` is non-empty,
    so the no-events path collapses the VStack back to a single
    full-height motion canvas. The ribbon's viewport is
    `axis: .horizontal` with the SAME `actionLineFraction` and
    `secondsAhead` as the motion canvas — visible time window aligned
    with motion. The old in-lane `drawCrossfaderLayer(in:viewport:)`
    method and its call inside the motion Canvas closure are deleted.
  - `ScratchLab/Models/ScratchMotionRenderer.swift` — `ribbonCrossRange`
    now returns `(0, viewport.crossLength)` so the renderer fills the
    full cross extent of whatever viewport it is given (the dedicated
    strip canvas). The `thickness` parameter is kept on the signature
    for source compatibility but is no longer consulted. Updated
    docstring explains the Phase-2.1 rationale.
- **No changes to**: `LaneContent` model fields, the selector predicate
  (`shouldRenderRawTrace(...)`), `drawRawTrace`, fader-event capture,
  schema constants, resources, or the test file's assertions.
- **Time-alignment note for portrait**: the ribbon strip uses the
  motion's `actionLineFraction = 0.85`, so the ribbon's NOW position is
  at x = 85% from the left of the strip — past dominates the strip
  width. This keeps the ribbon's visible-time window exactly matched
  to the motion's; the quirk is that a portrait motion's time axis is
  vertical while the ribbon below it is horizontal, so the NOW indicators
  don't visually intersect (they're orthogonal). The ribbon is read as
  a separate horizontal timeline that shares the motion's visible time
  window. In landscape this works cleanly because both axes are already
  horizontal (NOW at x = 18% from leading edge in both).
- **No pixel-diff snapshot tests** (unchanged from Phase 2 limitation —
  no image-comparison library in the repo).
- **Attempted visual proof**:
  - First attempt: added three `ImageRenderer`-based visual-proof tests
    to `LaneRawTraceFallbackTests` (portrait-with-ribbon,
    landscape-with-ribbon, portrait-no-ribbon → PNG to
    `/tmp/scratchlab_phase21/`). Compilation failed because
    `ScratchMotionLane` is iOS-only (`Views/` group is not in the
    macOS test target's compilation unit, per
    `project_demo_timing_slice.md`). Reverted the tests.
  - Second attempt: built `ScratchLab.app` for the booted iPhone 17
    simulator (id `53B855D2-2933-4A9C-BB75-1AC5D866701E`),
    `simctl install` + `simctl launch`, captured launch screenshot at
    `/tmp/scratchlab_phase21_main.png`. The screenshot proves the app
    builds, installs, and launches cleanly. It does NOT demonstrate the
    new ribbon because the visible main-menu surface (`MainMenuView`)
    does not host `ScratchMotionLane`, and even reaching Practice →
    Baby → Auto-cut would render the no-events fallback (no fader
    events on any shipping call path).
- **Honest visual-proof gap**: producing a feature-demo screenshot
  showing the new ribbon strip below the motion canvas would require
  either:
  - A new iOS XCTest bundle (new pbxproj target — out of scope for a
    polish pass), or
  - Temporary debug-only synthetic fader-event injection in a Practice
    surface (touches Practice/coaching code — out of scope per SOUL.md
    "Do not change Practice/scoring/coaching unless explicitly asked"),
    or
  - An iOS SwiftUI Preview added to `ScratchMotionLane.swift` with
    sample fader events (renderable in Xcode's canvas only —
    cannot be captured non-interactively).
  Pick any of those and I can produce a real visual; until then, the
  ribbon-below-motion claim rests on the code structure (VStack split
  with the ribbon as the second child, only added when events present),
  the inline docstrings, and the existing 9 Phase-2 selector +
  structural tests passing.
- **Builds run** after the 2.1 restructure:
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLab -destination 'platform=iOS Simulator,id=...'`
    → **BUILD SUCCEEDED** (used for simulator install).
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run**: same 24-case suite as Phase 2 (15 Phase 1 + 9 Phase 2)
  → **24 / 24 passed**, 0 failures, total 0.016 s.

---

## 2026-05-24 — Raw platter-position timeline Phase 2 (renderer fork + crossfader ribbon)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has the slice's one new test file + four modified files. Nothing
  staged. No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (Phase 2 section). Three render-style decisions locked at the start
  of the slice: ribbon edge = bottom/trailing; trace style = single hue
  + velocity-modulated thickness; density floor = 10 samples/sec.
- **Files added** (one new, untracked at slice end):
  - `ScratchLabDesktopTests/LaneRawTraceFallbackTests.swift` — 9 XCTest
    cases: 2 back-compat invariants (`LaneContent(notation:)` and
    `LaneContent(reel:)` both produce nil `platterTimeline` + empty
    `faderEvents`), 5 selector predicate cases (no-timeline,
    dense+covers-80%, sparse, low-coverage, tunable floor), 2
    structural smoke tests (drawRawTrace + drawCrossfaderRibbon/Ticks
    via `ImageRenderer`).
- **Files modified** (four):
  - `ScratchLab/Models/TimingLane.swift` (+78 lines) — `LaneContent`
    gains two optional fields: `platterTimeline: PlatterPositionTimeline?`
    (default nil) and `faderEvents: [CaptureCore.DetectedNotationFaderEvent]`
    (default []). Custom designated init with defaults preserves both
    existing extension initialisers (`init(reel:)`, `init(notation:)`)
    byte-identically. New extension method
    `shouldRenderRawTrace(minimumSampleDensity: Double = 10.0)` gates
    the renderer's substrate selection — requires timeline non-nil,
    positive span, density ≥ floor, duration > 0, and span ≥
    `duration * 0.8` (the 80% coverage threshold lives in
    `minimumRawTraceCoverageFraction`).
  - `ScratchLab/Models/ScratchMotionRenderer.swift` (+192 lines) —
    `Style` gains `crossfaderRibbonColor` (default
    `.white.opacity(0.18)`) and `crossfaderTickColor` (default
    `.white.opacity(0.65)`). Three new pure static functions added;
    existing `draw(_:in:viewport:style:)` is unchanged.
    - `drawRawTrace(_:in:viewport:style:)` — single-hue polyline with
      `sqrt(|dp/dt| * 3.0)` thickness curve clamped to
      `[0.5, 1.8] * style.lineWidth`. Restricts to visible samples plus
      one lead-in / lead-out for edge continuity. Normalises through
      `timeline.positionRange` onto cross-axis 0…1.
    - `drawCrossfaderRibbon(_:in:viewport:style:)` — fills `.closed`
      segments with `style.crossfaderRibbonColor`. `.open` segments are
      transparent. `.transitioning(progress: target)` segments fill at
      opacity `(1 - target)` so a closing ramp fades in / an opening
      ramp fades out.
    - `drawCrossfaderTicks(_:in:viewport:style:)` — draws short
      perpendicular ticks at every `.cut`, `.pulse`, `.transformPulse`,
      and `.flareClick` event time.
    - `ribbonCrossRange(viewport:thickness:)` is a private helper that
      places both ribbon and ticks at the larger-cross-coordinate edge
      of the lane (visual BOTTOM in landscape; visual RIGHT in
      portrait — see "Ribbon edge convention deviation" below).
  - `ScratchLab/Views/ScratchMotionLane.swift` (+65 lines) — `init`
    now derives a `CrossfaderStateTimeline` from `content.faderEvents`
    alongside the existing `motionPath`. `drawMotionPath(in:viewport:)`
    branches at the top: if `content.shouldRenderRawTrace()` passes,
    calls `ScratchMotionRenderer.drawRawTrace(...)` and returns; else
    falls back to the existing tiled `MotionPath` rendering loop —
    pixel-identical when both new fields are nil/empty. New
    `drawCrossfaderLayer(in:viewport:)` is added to the Canvas closure
    between `drawMotionPath` and `drawUserEvents`; it returns early
    when `content.faderEvents.isEmpty`, so the no-events path is
    visually identical to pre-Phase-2.
  - `ScratchLab.xcodeproj/project.pbxproj` (+4 lines) — one new file
    ref + one new build file + group + Sources phase entry, all using
    prefix `LRT` (mirrors the Phase 1 `PPT` pattern).
- **Ribbon edge convention deviation flagged**: the locked Phase 2
  decision was "bottom / trailing edge", with an ASCII preview that
  showed the ribbon as a HORIZONTAL strip below the motion area in
  BOTH portrait and landscape. My implementation places the ribbon at
  the larger-cross-coordinate edge — which is the visual BOTTOM in
  landscape (correct, matches preview), but the visual RIGHT side in
  portrait (NOT the bottom that the ASCII showed). Reason: a true
  visual-bottom strip in portrait would require restructuring
  `ScratchMotionLane`'s layout into a VStack (motion canvas + ribbon
  canvas), which is a separate scope from "renderer-only Phase 2". The
  current implementation sits cleanly inside the existing 12%
  cross-axis margin (`crossInsetFraction = 0.12`) and never competes
  with the motion trace. If Karl prefers the visual-bottom-in-portrait
  variant, that's a layout-restructure follow-up (Phase 2.1). The
  inline doc on `ribbonCrossRange` documents this explicitly.
- **Constraints honoured**:
  - No edits to `CaptureCore.swift`, `PracticeReelTimeline.swift`,
    `SessionExportCoordinator.swift`, `HandDirectionTracker.swift`, or
    `MacCaptureEngine.swift`. The renderer *reads*
    `CaptureCore.DetectedNotationFaderEvent` as input (a Codable nested
    struct in the `CaptureCore` enum namespace) but does not modify it.
  - `scratchlab_session_export_v4` constant
    (`SessionExportCoordinator.swift:23`) — byte-stable, unchanged.
  - `scratchlab_detected_notation_v1` constant
    (`SessionExportCoordinator.swift:379`) — byte-stable, unchanged.
  - No `.mlmodel`, `.mlmodelc`, `.mlpackage` touched.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
    entitlements, or Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` left as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).
- **Builds run** (per `feedback_verification_scope.md`):
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**. (First attempt failed on the test file —
    `ScratchNotation.loadBabyScratchFromBundle()` returns optional,
    and SwiftUI `ImageRenderer` is main-actor-isolated. Fixed with
    `try XCTUnwrap(...)` + `@MainActor` on the test class. Second
    attempt clean.)
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run** (Phase 1 + Phase 2 classes, targeted to avoid
  `project_test_runner_hang.md`):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests
    -only-testing:ScratchLabDesktopTests/LaneRawTraceFallbackTests`
    → **TEST EXECUTE SUCCEEDED**. **24 / 24 passed**, 0 failures, 0
    unexpected. (15 Phase 1 + 9 Phase 2.) Total runtime 0.011 s.
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
   M ScratchLab/Models/ScratchMotionRenderer.swift
   M ScratchLab/Models/TimingLane.swift
   M ScratchLab/Views/ScratchMotionLane.swift
  ?? ScratchLabDesktopTests/LaneRawTraceFallbackTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (Phase 2 scope only — plist is pre-existing dirty,
  new file is untracked until staged):
  ```
  ScratchLab.xcodeproj/project.pbxproj           |   4 +
  ScratchLab/Models/ScratchMotionRenderer.swift  | 192 +++++++++++++++++++++
  ScratchLab/Models/TimingLane.swift             |  78 +++++++++
  ScratchLab/Views/ScratchMotionLane.swift       |  65 ++++++-
  ```
- **Limitation surfaced — no pixel snapshot tests.** SwiftUI
  `GraphicsContext` is opaque to XCTest; a true pixel-diff snapshot
  test would need an image-comparison library (none in the repo). The
  pixel-identical guarantee for the no-timeline fallback is therefore
  argued from code structure (the `drawMotionPath` branch routes
  through the identical `ScratchMotionRenderer.draw(motionPath:...)`
  call as pre-Phase-2 when both new fields are defaulted) rather than
  proven by image diff. The two structural smoke tests assert the new
  renderer entry points produce a non-nil rendered CGImage via
  `ImageRenderer`, but do not validate pixel content.
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 2: raw-trace renderer fork + crossfader ribbon (no producer yet)`.
  2. Approve the cross-axis-edge ribbon placement, or request the
     Phase 2.1 layout restructure for a true visual-bottom ribbon in
     portrait?
  3. Approve `next_prompt.md` rewrite pointing at Phase 3 (live
     producer)?

## 2026-05-24 — Raw platter-position timeline Phase 1 (models + tests)

- **Slice status: uncommitted, awaiting Karl's approval.** Working tree
  has the slice's two new files + a pbxproj membership edit. Nothing
  staged. No commit, no push.
- **Plan**: `/Users/karlwatson/.claude/plans/unified-frolicking-iverson.md`
  (approved, with the verification amendment that excludes
  `Tools/TrainModels` swift test from the gate). The Phase 1 coding
  prompt lives at `AI_HANDOFF/next_prompt.md` (committed in `2a5ba2f`,
  pushed to `origin/main`).
- **Files added** (two new, both untracked at slice end):
  - `ScratchLab/Models/PlatterPositionTimeline.swift` — defines
    `PlatterPositionSample` (Codable), `PlatterPositionTimeline`
    (Codable, with failing init enforcing sort + range invariants,
    linear interpolation, `positionRange`), and `CrossfaderStateTimeline`
    (NOT Codable — derived view over
    `CaptureCore.DetectedNotationFaderEvent[]`, lerping
    `.transitioning(progress:)` across event spans).
  - `ScratchLabDesktopTests/PlatterPositionTimelineTests.swift` — 15
    XCTest cases per the prompt: Codable round-trip, 3 invariant
    rejections, 4 interpolation cases, 2 `positionRange` cases, 5
    `CrossfaderStateTimeline` cases.
- **Files modified** (one): `ScratchLab.xcodeproj/project.pbxproj` —
  10 new entries mirroring the `TimingLane.swift` / `ScratchStrokeGeometry.swift`
  shape:
  - File ref `PPT0000000PPT001PPT00001` for the Swift file (+ ref
    `PPT0010000PPT001PPT00001` for the test file).
  - Build files for ScratchLab (iOS, suffix `00002`), ScratchLabDesktop
    (macOS, suffix `00001`), and the test build file
    (`PPT0011000PPT001PPT00001`) for ScratchLabDesktopTests.
  - Group entries: Models group (line 560) for the Swift file;
    ScratchLabDesktopTests group (line 423) for the test file.
  - Sources phase entries for all three targets at the expected line
    positions (901 / 978 / 1059).
- **Convention deviation flagged**: the prompt specified the test path
  as `ScratchLabDesktopTests/Models/PlatterPositionTimelineTests.swift`,
  but the existing `ScratchLabDesktopTests/` directory is FLAT (no
  `Models/` subgroup; 11 sibling test files live at the target root).
  Honoured the flat convention to keep the pbxproj edit minimal — the
  file ships at `ScratchLabDesktopTests/PlatterPositionTimelineTests.swift`.
  If Karl prefers a nested `Models/` subgroup, a follow-up slice can
  add it with a new PBXGroup entry; today the path is consistent with
  every other test file in the target.
- **Constraints honoured**:
  - No edits to `CaptureCore.swift`, `TimingLane.swift`,
    `ScratchStrokeGeometry.swift`, `ScratchMotionRenderer.swift`,
    `ScratchMotionLane.swift`, `PracticeReelTimeline.swift`,
    `SessionExportCoordinator.swift`, `HandDirectionTracker.swift`, or
    `MacCaptureEngine.swift`. The new file *reads*
    `CaptureCore.DetectedNotationFaderEvent` (a nested Codable struct
    on the `CaptureCore` enum namespace) but does not modify it.
  - `scratchlab_session_export_v4` constant
    (`SessionExportCoordinator.swift:23`) — byte-stable, verified.
  - `scratchlab_detected_notation_v1` constant
    (`SessionExportCoordinator.swift:379`) — byte-stable, verified.
  - No `.mlmodel`, `.mlmodelc`, `.mlpackage` touched.
  - No Info.plist, PrivacyInfo.xcprivacy, signing, bundle ID,
    entitlements, or Copy Bundle Resources changes.
  - `xcuserdata/.../xcschememanagement.plist`, `reference_frames/`,
    `reference_videos/` left as pre-existing dirty / untracked.
  - No `Co-Authored-By` trailer (per `feedback_no_coauthor_trailer.md`).
- **Builds run** (per `feedback_verification_scope.md` —
  `Tools/TrainModels swift test` is explicitly NOT in the verification
  gate for app-target-only slices):
  - `xcodebuild build -scheme ScratchLab -destination 'generic/platform=iOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **BUILD SUCCEEDED**.
  - `xcodebuild build-for-testing -scheme ScratchLabDesktop -destination 'platform=macOS'`
    → **TEST BUILD SUCCEEDED**.
- **Tests run** (nice-to-have, narrowed to the new class to avoid the
  `project_test_runner_hang.md` test-host hang risk):
  - `xcodebuild test-without-building -scheme ScratchLabDesktop
    -destination 'platform=macOS'
    -only-testing:ScratchLabDesktopTests/PlatterPositionTimelineTests`
    → **TEST EXECUTE SUCCEEDED**. 15 / 15 passed, 0 failures, 0
    unexpected. Total runtime 0.009 s (pure value-type tests).
- **Working tree at slice end** (`git status --short --branch`):
  ```
  ## main...origin/main
   M ScratchLab.xcodeproj/project.pbxproj
   M ScratchLab.xcodeproj/xcuserdata/karlwatson.xcuserdatad/xcschemes/xcschememanagement.plist
  ?? ScratchLab/Models/PlatterPositionTimeline.swift
  ?? ScratchLabDesktopTests/PlatterPositionTimelineTests.swift
  ?? reference_frames/
  ?? reference_videos/
  ```
  `git diff --stat` (only the pbxproj diff is in scope — the new files
  are untracked until staged; the plist is pre-existing dirty):
  ```
  ScratchLab.xcodeproj/project.pbxproj | 10 ++++++++++
  ```
- **Decision needed from Karl**:
  1. Approve the slice for commit? Suggested commit message:
     `Phase 1: PlatterPositionTimeline + CrossfaderStateTimeline models, tests only`.
  2. Approve the flat test-file location, or move to a new
     `ScratchLabDesktopTests/Models/` subgroup?
  3. Approve `next_prompt.md` rewrite pointing at Phase 2 (renderer
     fork)?

## 2026-05-24 — 2D Coach quarantine + integrated-trace decision

- **`cb33837` pushed to `origin/main`** (`Quarantine the 2D Coach Rig from the
  iOS Try-Demo surface`). Single-file change in
  `ScratchLab/Views/MainMenuView.swift`. iOS Simulator build and macOS
  ScratchLabDesktop build both passed before push.
- **iOS "Try Demo" 2D Coach is quarantined.** The `coachCard` mount was
  removed from `DemoModeView`'s VStack. The `coachCard` computed property,
  `ScratchCoachCardTheme`, `demoControlButton`, `ScratchCoachCardContent`,
  and the shared `ScratchCoachRigView` all remain defined — no coach code
  was deleted. `PracticeModeView` already did not mount the 2D card
  (test-enforced); macOS `MacAnalyzerView` untouched.
- **Geometry / integrated-trace work was intentionally stopped.**
  The SXRATCH-style continuous-trace fix in `ScratchStrokeGeometry` was
  scoped, simulated against `ScratchLab/Resources/CoachDemoAudio/baby_reel.json`,
  and **not applied**. The bundled reel stores classified directional cuts,
  not raw platter-angle samples — naive integration drifts strongly negative
  (Demo 1: 7 backwards vs 3 forwards, net Δ = −1.37; full reel net Δ = −1.94,
  range entirely below the lead-in rest). Symmetric normalize collapses Baby
  Scratch into the lower half of the lane; asymmetric normalize turns it
  into a downward staircase. Karl's call: stop, don't tune blindly. Revisit
  when raw platter-angle capture data exists. Plan file
  (`/Users/karlwatson/.claude/plans/fluffy-yawning-sunset.md`) captures the
  full analysis and three deferred options (A: sticks-only; B: spring-back
  holds; C: integrate with synthetic recovery).
- **`reference_frames/` and `reference_videos/` are local analysis
  artifacts.** They live untracked in the working tree at the repo root.
  They are the extracted SXRATCH-visualizer frames used to diagnose the
  notation-lane vs continuous-trace gap. **Do not commit them unless
  explicitly requested** — they are not bundled, not training data, and
  not user-facing assets.
- **Pre-existing dirty files preserved.** `xcuserdata/.../xcschememanagement.plist`
  remains modified-but-unstaged. Per session policy it stays out of every
  commit on this branch.

## Current task

Slice U - export / ASC safety audit for beta readiness (audit-only).

## Branch / worktree

`/Users/karlwatson/Downloads/ScratchLab-merged-check` - detached HEAD at PR #2 merge.

## Base commit

`26553fe Merge pull request #2 from mastak007/claude/slice-o-onset-diagnostics`

## Goal

Report whether the merged tree is safe to ship for beta along three axes:
1. Review audio onset preview is display-only (no leakage into snapshot / scoring / export).
2. No model or sensitive-resource leakage in the repo or app bundle.
3. User-facing copy contains no overclaiming ML language or banned brand strings.

No fixes implemented - Slice U is audit-only by spec.

## Files changed

None. Audit-only slice. Working tree is clean.

## What changed

Nothing in the codebase. Findings only:

### Audit 1 - Review onset preview safety (clean)

- `ScratchLab/ML/ReviewAudioOnsetPreview.swift:248` carries an explicit user-facing footer disclaimer: `"Diagnostics-only preview. Not part of saved or exported notation."`
- `ScratchLab/Models/CaptureCore.swift:104,112` declare `audioOnsetReviewSummary` and `audioOnsetReviewMarks` as `@Published private(set)` on the runtime diagnostics object. They are populated only by `recordAudioSamplesForOnsetDiagnostics` (lines 158-177) and read only by `ScratchLabDesktop/Views/MacAnalyzerView.swift:1459,1494` for display.
- `ScratchLab/Models/CaptureCore.swift:4702-4762` define `DetectedNotationSnapshot`; its fields are `recordMovementEvents`, `audioEvents`, `faderEvents`, `mixerMidiEvents`. None of them are populated from `audioOnsetReviewMarks` / `audioOnsetReviewSummary` / `ReviewAudioOnsetPreview` (confirmed via repo-wide grep).
- `ScratchLab/Services/SessionExportCoordinator.swift` contains zero references to `audioOnsetReview*`, `ReviewAudioOnsetPreview`, `ReviewAudioOnsetMarksBuilder`, `ReviewAudioOnsetSource`, `reviewMarks`, `timing_marks`, `onsetPreview`, `preview_marks`, or `review_preview`. Export schema version `scratchlab_session_export_v4` is unchanged.
- Captured `DetectedNotationSnapshot.audioEvents` remain the source of truth; preview only re-summarises them via `ReviewAudioOnsetMarksBuilder.summarizeTakeEvents` (`ReviewAudioOnsetPreview.swift:393-429`).
- Source label: `ReviewAudioOnsetPreview.swift:299-308` maps `.selectedTakeSavedEvents` -> `"selected take audio"`. The old wording `"selected take saved audio events"` does not appear anywhere user-facing (verified via grep - remaining occurrences are in code comments and test docstrings only).

### Audit 2 - Model / resource leakage (clean)

- No `.mlmodel`, `.mlmodelc`, `.mlpackage` files anywhere under the repo.
- No `.jsonl` cache files; no `action_windows*` or `action_features_cache*` directories.
- `ScratchLab.xcodeproj/project.pbxproj` contains zero `.mlmodel*` references, no `TASKS.md` / `DEV_LOG.md` / `SOUL.md` / `PROFILE.md` / `AI_HANDOFF*` membership.
- `ScratchLab/Resources/` and `ScratchLabDesktop/Resources/` contain only: Coach USDZ rigs, CoachInstructions JSON, CoachDemoMotion JSON, CoachDemoAudio WAV (`baby_noBeat.wav`, `chirpflare_noBeat.wav`), `Notation/baby_scratch.json`, `reference_beginner/*.wav`, `reference_champ/*.wav`, `reference_pro/*.wav`. No banned strings in bundled JSON (grep negative for `youtube|ortofon|makemkv|sourceMKV|QBERT|SXRATCH|/Users/`).
- The only shipped Swift mention of `/Users/`, `MakeMKV`, `QBERT`, `SXRATCH`, `processed_makemkv`, `sourceMKV` is the banned-token guard list in `ScratchLabDesktop/Services/ScratchTypeMetadataSafety.swift:13-23`. These are guard tokens compared against incoming metadata, never surfaced.
- `TASKS.md` and `DEV_LOG.md` reference paths under `/Users/karlwatson/Movies/CXL DATASET/processed_makemkv/...` but are repo-root docs, NOT bundle-membership files. They cannot ship in the app.

### Audit 3 - ASC / user-facing wording

- No occurrences of `machine learning`, `neural network`, `deep learning`, `detects exactly`, `real-time AI` in shipped Swift (`ScratchLab/`, `ScratchLabDesktop/`, excluding `*Tests*`).
- No user-facing occurrences of `YouTube`, `Ortofon`, `QBERT`, `SXRATCH`. `QBERT` / `SXRATCH` exist only in the banned-token guard list and in tests as negative-fixture inputs.
- `CXL` appears only as a Swift type-name prefix (`CXLDirection`, `CXLTimingClassification`, `CXLNotationCaptureRecorder`, `captureEngine.cxlIsRecording`, etc.) - no `Text(...)` / `Label(...)` / `navigationTitle` / alert with a literal `"CXL"` user string found.
- WARNING `ScratchLab/Views/AIBattleModeView.swift:25,29` ships user-facing `Text("AI BATTLE")` and `Text("Challenge an AI opponent")`. `ScratchLab/Models/GameState.swift:12` ships `case aiChallenge = "AI Challenge"`. These are a scripted game opponent (rookie/flash/cipher/nova/legend scripted characters, no ML inference), but the literal word "AI" can attract App Store / ASC review scrutiny under current AI-disclosure expectations.

## Findings grouped by severity

### Blocker

None.

### Should fix before beta

- **`AIBattleModeView.swift:25,29` + `GameState.swift:12`** - user-facing "AI BATTLE" / "Challenge an AI opponent" / "AI Challenge" copy. The feature is a scripted opponent, not ML, but ASC has been tightening copy review around any "AI" usage. Recommended: rename user-visible strings to neutral wording like `BATTLE`, `Rival Challenge`, or `Opponent Challenge`. The internal enum case (`aiChallenge`) and type names (`AICharacter`) can stay because they are not user-visible. Per PROFILE.md, "avoid `AI detects exactly`, `real-time AI coach`, `deep learning` in user-facing copy" - this is adjacent to that guidance and prudent to clear before TestFlight.

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

- `cd Tools/TrainModels && swift test` - **200 tests passed, 0 failures** (including ReviewAudioOnsetPreviewTests, ReviewAudioOnsetMarksBuilderTests, ReviewAudioOnsetSourceResolverTests, NotationCandidateDiagnosticsTests, sound trainer + ML library suites).
- `xcodebuild -scheme ScratchLabDesktop -destination 'platform=macOS' build` - **BUILD SUCCEEDED**.
- `xcodebuild -scheme ScratchLab -destination 'generic/platform=iOS' build` - **BUILD SUCCEEDED**.

## Tests / builds still needed

- Full `ScratchLabDesktop` XCTest plan (`./scripts/build.sh`) was not re-run in this slice - Slice U is audit-only and the executors already pre-merge ran the full suite per PR #2 history. Re-run on demand if any text-rename fix is later attempted.

## Git status

```
## HEAD (no branch)
```

Working tree clean. No staged or unstaged changes.

## Risks / warnings

- The "AI Battle" copy is the only audit finding that warrants action before TestFlight. It is small and local (3 string literals across 2 files) but renaming will likely cascade into screenshots and feature copy on the ASC listing.
- The dirty checkout at `/Users/karlwatson/Downloads/ScratchLab` was NOT touched - confirmed by working only in `ScratchLab-merged-check`.

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
export changes were made in the current Slice U pass - this is an audit-and-
documentation update only. Slices U.1 and U.2 remain future, separately gated
work and MUST NOT be started in this slice.

### (a) Slice U.1 - "AI BATTLE" / "AI Challenge" user-facing copy neutralization (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Approval covers user-facing string literals only.
- **Scope of impact (in-scope for U.1, NOT touched here)**:
  - `ScratchLab/Views/AIBattleModeView.swift:25` - `Text("AI BATTLE")`
  - `ScratchLab/Views/AIBattleModeView.swift:29` - `Text("Challenge an AI opponent")`
  - `ScratchLab/Models/GameState.swift:12` - `case aiChallenge = "AI Challenge"`
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
    surface - any persisted state (UserDefaults, snapshots, saved sessions,
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

### (b) Slice U.2 - Audit-only Copy Bundle Resources negative-assertion test (Karl-approved)

- **Approval status**: Approved by Karl for execution as a separate future
  slice. Test is audit-only - it inspects `project.pbxproj`, it does not
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
  - Brittle parsing - naive substring matching against `project.pbxproj`
    could false-positive on path fragments. The test must scope matches to
    full file references inside `PBXResourcesBuildPhase` blocks for the
    shipping app targets only, not script-phase or test-target references.
  - If any of these files have **already** been mistakenly added to a Copy
    Bundle Resources phase, the test will fail on first run. That failure
    is the point, but it must be triaged as "remove the resource membership"
    and **never** as "weaken the test".

### (c) Slice U is audit-only - bundle / project / export surfaces are off-limits

- No changes to the app bundle, `ScratchLab.xcodeproj/project.pbxproj`,
  Copy Bundle Resources phases, Info.plist, PrivacyInfo.xcprivacy, signing,
  bundle ID, entitlements, or export schema (`scratchlab_session_export_v4`
  remains unchanged) are permitted in Slice U.
- Any such change requires an explicitly approved future slice (e.g. U.1
  for the copy rename, U.2 for the project-file inspection test) and must
  carry its own approval from Karl before execution.
- Slice U.2's test is itself read-only against the project file - even
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
inside a Copy Bundle Resources phase. Audit-only - do not modify the project.
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
