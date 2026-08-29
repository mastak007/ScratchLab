Read `CLAUDE.md`, then `SOUL.md` and `PROFILE.md`.
Read `AI_HANDOFF.md` — the top entry (2026-08-29) is current state; older branch histories below it are reference material only.
Run `git status --short --branch` and `git rev-parse HEAD origin/feature/ios-capture-camera-ux`.

## Capture-integrity batch: Slices A+B landed, C–H open (2026-08-29; current)

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
