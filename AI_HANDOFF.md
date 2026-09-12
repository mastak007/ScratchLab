# ScratchLab CXL verified checkpoint and fresh-worktree handoff — 2026-09-12

## Next task and workspace

The user explicitly requested a fresh task and clean worktree from this verified recovery code because the original conversation repeatedly compacted. Create the new task from the pushed checkpoint referenced by `/Users/karlwatson/Developer/ScratchLab-CXL-Recovery-20260912/evidence/cxl-live-fader-20260912/checkpoint.json`, not from the primary checkout's dirty files or default branch. Once that new worktree exists, use its assigned working directory for all further work. Verify its HEAD equals the checkpoint before starting. The original build source remains `/Users/karlwatson/Developer/ScratchLab-CXL-Recovery-20260912/source`, branch `codex/cxl-capture-recovery-20260912`; it is preserved as build provenance. Do not modify the separately dirty `/Users/karlwatson/Downloads/ScratchLab` checkout.

User authorizes verified commits/pushes, in-place iPhone/Watch reinstall and updated Mac reopening. Current implementation/build/install work is complete. Next is a short Rane ONE MKII hardware test, not another rebuild or audit loop. Do not quit/reinstall the running apps or erase captures without a concrete new reason. Do not start new coding until operator feedback identifies a failure. Preserve excluded untracked `CXLBeatPilotCandidates/` and `ScratchLabDesktopTests/CalibrationCameraOverlayTests.swift.plist` in the recovery source.

## Installed apps and completed verification

Mac: `/Users/karlwatson/Applications/ScratchLab CXL.app`, bundle `com.machelpnz.scratchlab.cxl-authoring`, version1.0.1/build21, universal arm64+x86_64. Executable SHA256 `4cf28f01f9deff4e3d53933ce4e87fda759eb5359d86f0da39879d22d82803b9`. Confirmed running PID63014 after installing at2026-09-12T22:03:23.221277+12:00. Old app retained at `/Users/karlwatson/Applications/ScratchLab CXL.previous-20260912-220323.app`. Signature, identity and permission metadata verified; app data untouched. Sky helper still reports native pipe closed, although exact process launch succeeds. No visual UI acceptance was obtained; do not claim a screenshot check.

Phone and Watch: signed build PASSED; both reinstalled in place and installed inventories verified. Phone launch succeeded. Watch install first disconnected, retry succeeded; Watch remote launch later timed out. Ask the user to tap ScratchLab on Watch at the start of the pilot test. No uninstall or data erasure.

Evidence root: `/Users/karlwatson/Developer/ScratchLab-CXL-Recovery-20260912/evidence/cxl-live-fader-20260912`. See RESULT.md, PILOT_TEST.md, installation.json, running-mac.json, companions-candidates.json, companions-deployment.json and checkpoint.json. Both devices are physical: phone1F80398A-96C8-537A-B0EE-821E186918B9; WatchFA341802-22F1-54A7-811C-68EB29F1BF0A. Phone bundle com.machelpnz.scratchlab; Watch com.machelpnz.scratchlab.watchkitapp.

Final recovery:542unique tests,540passed/2skipped/0failed;1084executions across2configurations. Python capture fixtures84/84passed. Universal Mac Release and signed iPhone+embedded Watch builds passed. All462frozen source/build/test inputs match after builds. Full scripts/build.sh all remained deferred for speed; never call focused suites a full-suite pass. Skips are optional DEBUG capture fixtures (flag absent/no test-host mixer frames).

Original evidence retained: baseline275unique,272pass/1skip/2new playback-regression failures. First full affected attempt541unique,529pass/2skip/10fail; fixed fake-MIDI fixture arming order, actual AVFoundation empty-edit validation and a permanent tap shutdown crash. Corrected rerun passes. Do not discard the original results or call them passes.

## What changed and what it proves

- Healthy connected fader/platter remain green Ready—idle after genuine traffic. Green checks use2columns, errors/warnings below. Old generations, wrong source/calibration and out-of-order callbacks cannot certify current readiness.
- Live parked fader stays visible from real CC8/full calibration. New recordings can seal a take-owned parked observation at Stop, invalidating on any further CC8, connection/mapping/calibration/curve change or pending ingress. Shared derivation bounds held coverage by actual WAV frames and capture time. No synthetic raw MIDI; old takes are not repaired. Approval requires positive coverage through selected media time, not a zero-width open point or a gap.
- Renderer stop/reversal position regressions are fixed by correlated MIDI endpoint settling only once the existing idle fade is silent. Default control cadence and audible ramps are unchanged. Moving physical latency still needs operator testing.
- Latest old take WAV/AAC5.900000s versus video6.034040s exposed a134.040ms camera tail. New mux uses common actually covered track duration and atomically replaces the MOV. It refuses leading/internal empty edits, does not shift starts, pad media, rewrite WAV or relax validation. Original recordings are untouched; matching endpoints do not by themselves prove physical A/V synchronization.
- Permanent meter/monitor tap no longer temporarily becomes the final controller owner on AVFoundation's service queue; independent state and a weak handoff prevent the reproduced shutdown trap. Meter/routing/queue limits unchanged. Older routine/DEBUG capture taps were not broadened, so no universal teardown-safety claim.

## Short pilot batch (give these steps, then wait for operator)

1. Open ScratchLab on Watch. In CXL choose Rane ONE MKII for MIDI/audio and MacBook Pro Camera; Enable Selected Camera & Audio and Enable iPhone & Watch Relay. Move fader/platter once then park; healthy entries should remain green and calibrated right/open should say Open.
2. Capture → Movement check (no beat); Technique → Tear; Fader variant → Fader open throughout; Apply Authoring Setup. Press Record movement check, wait for Recording started, then one slow push/stop/pull for about5–10seconds. No skilled Tear or beat timing required.
3. Stop and Finalize on Mac only. Watch should stop too. If it remains recording, user can stop it manually and report the failure. Connected status does not prove motion transfer or coverage.
4. Play whole take: check picture, recorded sound, fader trace and absence of WAV/MOV duration error. Check physical response against sound/playhead.
5. Save Capture… and retain ZIP; Retake this scratch should preserve setup, New scratch should allow another technique. Review should say Movement check — play and save. Canonical approval and four timed repetitions are intentionally unavailable in diagnostic mode.

Rane ONE MKII is pilot hardware. User reported physical LEDs now in time; that remains operator evidence. Production Seventy-Two+Twelve through72 needs separate source/channel-pair proof and fresh capture acceptance. Beat/count-in remain on independent default output. Watch full capture/Stop/transfer continuity and physical timing remain unverified until this batch succeeds. Do not send as production-ready yet.

Historical handoff details remain in Git history and prior evidence folders. Follow this current checkpoint; do not reopen older /tmp candidates. User was advised Astra Ultra is unnecessary for guided testing; no model setting was changed.
