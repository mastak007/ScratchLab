# Timecode Prototype — Real Deck Validation Runbook

**Batch 11 — Validation & Evidence Workflow**
**Date prepared:** 2026-06-17
**Status:** Ready for hardware validation. Docs + minimal debug-text wording update.
**Committed base:** `befad10 Timecode: harden prototype profile flow`

---

## Safety & Legal Notice

- **ScratchLab Timecode Prototype** — experimental validation only.
- **DVS Prototype** — not a final Serato/SDJ compatibility claim.
- No DRM bypass. No audio fixture commits. No production DVS claim.
- All decode/playback paths are `#if DEBUG` or `#if ENABLE_TIMECODE_LIVE_TAP` gated.
- Do NOT commit audio fixtures or recordings captured during validation.

---

## 1. Required Hardware

| Item | Notes |
|------|-------|
| Turntable or controller source | RANE ONE MKII, DDJ-GRV6, or any deck outputting timecode signal |
| Timecode vinyl / CD / signal source | Standard DVS timecode record or controller timecode output |
| Audio interface or mixer output | Must present as a stereo macOS input device |
| Mac input selected | System Settings → Sound → Input → your interface |

**Minimum viable:** Any stereo input carrying a timecode control signal that macOS can see as an audio input device.

**Alternative (controller):** If your controller exposes timecode audio over USB as a stereo input, select that device directly. RANE ONE MKII timecode is available via the phono/line input routing; DDJ-GRV6 exposes it as a USB audio interface channel.

---

## 2. App Setup

### 2.1 Build

```bash
cd /Users/karlwatson/Downloads/ScratchLab
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS' \
  build 2>&1 | tail -20

# Expected: ** BUILD SUCCEEDED **
```

### 2.2 Launch & Navigate

1. Launch the Debug build of ScratchLabDesktop.
2. Open **Analyzer** → **Advanced** tab.
3. In the Advanced section picker, select **Timecode Input**.
4. Confirm the **Timecode Control** card is visible (DEBUG-gated).

### 2.3 Confirm Default State

| Check | Expected |
|-------|----------|
| Mode segmented control | **Disabled** (leftmost, grey) |
| Live tap status | Disabled / Mode off |
| Profile preset | **ScratchLab Prototype** |
| Validation status | **No Signal** (grey) |

If the Mode is anything other than Disabled, switch it back to Disabled before proceeding (the app persists the last mode via `@AppStorage`).

### 2.4 Select Profile

Use the **Profile** segmented control to select:

- **ScratchLab Prototype** — conservative defaults, recommended for first validation.
- **Generic DVS Control Signal** — experimental, if you want to test with a standard DVS carrier.

The Generic DVS preset shows an explicit warning: `Experimental — not Serato/SDJ certified or compatible`.

### 2.5 Enter Control Prototype Mode

1. Switch the **Mode** segmented control to **Timecode Prototype** (rightmost position).
2. The UI updates: calibration section becomes active, pipeline status section appears.

---

## 3. Signal Check

### 3.1 Enable Live Tap

1. In the **Live Tap** section, toggle **Enable live timecode tap** ON.
2. Verify the status badge changes:
   - **Waiting** (yellow) — tap is armed but no buffer received yet.
   - **Receiving** (green) — buffer arrived within the last 0.5 s.
   - **Stale** (orange) — buffer age > 0.5 s but < 2.0 s.

### 3.2 Confirm Mode: Diagnostics Only First

1. Switch Mode to **Diagnostics Only** (middle position).
2. This prevents any motion output — safe first-contact with unknown signal.

### 3.3 Verify Audio Input

In the **Diagnostics** section (displays the `TimecodeInputStatusCard`):

| Metric | Expected | Notes |
|--------|----------|-------|
| Left RMS | Non-zero, typically 0.01–0.50 | Depends on source level |
| Right RMS | Non-zero, similar magnitude to Left | Imbalance > 3:1 suggests cable or routing issue |
| Left Peak | Below 0.95 | > 0.98 may clip |
| Right Peak | Below 0.95 | > 0.98 may clip |
| Signal Health badge | **Usable** (green) | Any other badge = investigate |
| Buffer age | "now" or < 1 s | Stale buffer = tap not receiving |

### 3.4 Signal Health Diagnostics States

| Badge | Meaning | Action |
|-------|---------|--------|
| **Usable** (green) | Stereo signal, healthy levels | ✓ Proceed |
| **No Signal** (grey) | Silence on both channels | Check input device, cable, source |
| **Clipped** (red) | Peak ≥ 0.98 on either channel | Reduce gain at source or interface |
| **Channel Fault** (red) | One channel dead or severe imbalance | Check cable, routing, mono-sum setting |
| **Weak Signal** (yellow) | RMS below threshold, present but quiet | Increase gain or check preamp |
| **Mono Suspect** (yellow) | Channels near-identical, not true stereo | Timecode requires true stereo quadrature |

### 3.5 Signal Check Pass Criteria

- [ ] L/R RMS both non-zero and similar magnitude
- [ ] L/R Peak both below 0.95 (no clipping)
- [ ] Signal Health = **Usable**
- [ ] Buffer age < 1 s (receiving continuously)
- [ ] No channel fault warning

---

## 4. Decode Check

### 4.1 Switch to Control Prototype Mode

1. Switch Mode to **Timecode Prototype** (rightmost position).
2. Verify the **Pipeline Status** section now shows non-zero values.

### 4.2 Forward Movement

| Action | Expected |
|--------|----------|
| Move record / platter forward | **Direction:** `forward` (green) |
| Vary speed | **Rate:** changes proportionally, non-zero |
| Return to stop | **Rate:** drops to near 0 u/s |
| Check Confidence | ≥ threshold (0.3 for ScratchLab Prototype preset) |

### 4.3 Backward Movement

| Action | Expected |
|--------|----------|
| Move record / platter backward | **Direction:** `backward` (red) |
| Vary speed | **Rate:** negative, changes proportionally |
| Return to stop | **Rate:** drops to near 0 u/s |

### 4.4 Stop / Idle

| Action | Expected |
|--------|----------|
| Stop record completely | **Direction:** `unknown` or holds last known |
| Wait 2+ seconds | **Rate:** 0 u/s |
| Check counters | No excessive silence drops |

### 4.5 Confidence Check

| Metric | Expected |
|--------|----------|
| Decoder confidence | ≥ 0.3 (ScratchLab Prototype preset) |
| Average confidence | ≥ 0.3 across session |
| Accepted motion samples | > 0 after a few seconds of movement |

### 4.6 Drop Reasons Check

In the **Pipeline Status** section, inspect the counter grid:

| Counter | Expected | Concerning |
|---------|----------|------------|
| Accepted | > 0 | = 0 after deliberate movement |
| Dropped Silence | Some (expected at stop) | Dominating (> 80% of total) |
| Dropped Clipped | 0 | > 0 → reduce gain |
| Dropped Ch Fault | 0 | > 0 → check cabling |
| Dropped Weak | Low | Dominating → increase gain |
| Dropped Low Conf | Low | Dominating → adjust min confidence slider |

### 4.7 Decode Check Pass Criteria

- [ ] Forward movement produces `direction: forward` with positive rate
- [ ] Backward movement produces `direction: backward` with negative rate
- [ ] Stop/idle drops rate to near 0
- [ ] Confidence ≥ 0.3 during normal-speed movement
- [ ] Accepted motion samples > 0
- [ ] No unexpected drop reasons dominating

---

## 5. Playback Bridge Check

### 5.1 Pre-Flight

Before enabling the playback bridge, confirm:

- [ ] Mode = **Timecode Prototype**
- [ ] Live tap is receiving (status = **Receiving**, green)
- [ ] Validation status = **Prototype Control Active** (green)

If validation status is NOT `usablePrototypeControl`, the bridge will block with **Validation Required**. You can either:
- Fix the signal/decoder issues so validation passes, OR
- Toggle **Override — enable playback without validation** (with the red warning displayed).

### 5.2 Enable Playback Bridge

1. In the **Playback Bridge** section, toggle **Drive playback from prototype timecode** ON.
2. Observe the bridge state badge:

| Bridge State | Color | Meaning |
|-------------|-------|---------|
| **Armed** | Yellow | Bridge enabled, waiting for trusted signal |
| **Driving** | Green | Bridge producing drive output |
| **Bad Signal** | Red | Signal health, confidence, or staleness block |
| **Validation Required** | Orange | Validation hasn't passed + no override |
| **Replay Active** | Blue | Replay take is currently playing |
| **Diagnostics Only** | Orange | Pipeline mode is .diagnosticsOnly |
| **Live Tap Off** | Orange | Live tap toggle is off |

### 5.3 Movement Test Under Playback Bridge

| Action | Expected |
|--------|----------|
| Record forward | Bridge shows **Driving**, dir: `forward`, positive rate |
| Record backward | Bridge shows **Driving**, dir: `backward`, negative rate |
| Stop record | Rate drops to near 0; bridge may stay Armed or drop to Bad Signal |
| Slow movement (< 0.5× normal) | Rate reflects slow movement proportionally |
| Fast movement (> 2× normal) | Rate clamped to `maxPlaybackRate` |
| Rapid reversal | Direction changes cleanly, no spike or dropout |

### 5.4 Playback Bridge Pass Criteria

- [ ] Bridge transitions to **Driving** when signal is trusted
- [ ] Forward/backward direction matches record movement
- [ ] Stop produces near-zero rate
- [ ] Slow movement produces proportionally low rate
- [ ] Fast movement rate is clamped at max, not wild
- [ ] Reversal produces clean direction change without spike rejection
- [ ] Bridge source label = `timecode_prototype_playback`

---

## 6. Prototype Recording Check

### 6.1 Start a Take

1. Ensure Mode = **Timecode Prototype**.
2. In the **Prototype Take** section, click **Start Take**.
3. Verify state badge changes to **Recording** (red).

### 6.2 Scratch a Short Pattern

| Take | Pattern | Approx. Duration |
|------|---------|-------------------|
| T1 | Forward push, return | 0.5–1.0 s |
| T2 | Backward push, return | 0.5–1.0 s |
| T3 | Forward-backward-forward (baby scratch) | 0.3–0.8 s |
| T4 | Slow forward drag | 1.0–3.0 s |

### 6.3 Stop & Inspect

1. Click **Stop Take**.
2. Verify state badge changes to **Stopped** (green).
3. Inspect the recording stats:

| Metric | Expected |
|--------|----------|
| Accepted | > 0 for all takes |
| Dropped | Low relative to accepted |
| Duration | > 0, matches approximate scratch time |
| Source | `timecode_live` |
| Take summary | Shows sample count and source |

### 6.4 Recording Pass Criteria

- [ ] Start Take → state = Recording
- [ ] Stop Take → state = Stopped, accepted > 0
- [ ] Duration is reasonable for the performed pattern
- [ ] Source label = `timecode_live`
- [ ] Dropped count is low relative to accepted
- [ ] Clear button resets to Idle

---

## 7. Failure Capture

Use this section to document known failure modes and their signatures.

### 7.1 No Signal

| Signature | Triage |
|-----------|--------|
| Status = **No Signal** | Check: input device selected in macOS? Cable connected? Source playing? |
| L/R RMS = 0.0000 | Check: audio interface powered on? Gain turned up? |
| Buffer age = "never" | Check: Live Tap enabled? Mode not Disabled? |

### 7.2 Clipped

| Signature | Triage |
|-----------|--------|
| Status = **Clipped** | Check: peak > 0.98 on L or R |
| L/R Peak > 0.98 | Reduce gain at source, interface, or macOS input level |
| Dropped Clipped counter rising | Signal is saturating — decode will be unreliable |

### 7.3 One Channel / Channel Fault

| Signature | Triage |
|-----------|--------|
| Status = **Channel Fault** | Check: one channel RMS near zero while other is healthy |
| L RMS >> R RMS (or vice versa) | Check: cable (TRS vs TS?), interface routing, mono switch engaged? |
| Mono Suspect badge | Channels are near-identical — quadrature decode needs true stereo |

### 7.4 Weak Signal

| Signature | Triage |
|-----------|--------|
| L/R RMS both low (< 0.01) | Increase gain at source or interface |
| Dropped Weak counter rising | Signal below `signalThresholdRMS` |
| Confidence low despite movement | Weak signal → poor phase correlation |

### 7.5 Unstable Decode

| Signature | Triage |
|-----------|--------|
| Direction flickering forward ↔ backward | Check signal health; noise on input? |
| Confidence oscillating | Phase correlation unstable; check for ground hum or interference |
| Spike rejection counter rising | Rate jumping beyond `spikeRejectionThreshold` |
| Held/long dropout counters rising | Signal dropping out intermittently |

### 7.6 Jitter / Spikes

| Signature | Triage |
|-----------|--------|
| Rejected spikes counter > 0 | Smoothing active but catching wild frames |
| Last spike reason shown | Check what the filter rejected |
| Smoothed rate diverges from raw rate | EMA is lagging; may need higher alpha |

---

## 8. Evidence to Report

For each validation session, capture the following evidence (use the **Copy Debug** button in the Validation section to copy a full snapshot to clipboard):

### 8.1 Status Snapshot

```
Paste the output from "Copy Debug" here:
---
<insert debug text>
---
```

### 8.2 Key Metrics Summary

| Field | Value |
|-------|-------|
| Signal health | |
| Left RMS / Peak | / |
| Right RMS / Peak | / |
| Direction | |
| Raw rate | u/s |
| Smoothed rate | u/s |
| Decoder confidence | |
| Accepted | |
| Recorded | |
| Dropped (total) | |
| Dropped silence | |
| Dropped clipped | |
| Dropped ch fault | |
| Dropped weak | |
| Dropped low conf | |
| Rejected spikes | |
| Source label | |
| Validation status | |

### 8.3 Playback Bridge Evidence

| Field | Value |
|-------|-------|
| Bridge enabled? | |
| Bridge state | |
| Direction followed movement? | |
| Rate reflected speed? | |

### 8.4 RANE / Replay Regression Check

| Check | Pass? |
|-------|-------|
| RANE platter input still works? | |
| Replay trust gates still pass tests? | |
| Live camera/Vision tracking unaffected? | |

---

## 9. Pass / Fail Matrix

### PASS — Usable Prototype

All of:

- [ ] Signal check passes (Section 3.5)
- [ ] Decode check passes (Section 4.7)
- [ ] Playback bridge check passes (Section 5.4) — or bridge deliberately not tested yet
- [ ] Prototype recording check passes (Section 6.4)
- [ ] Accepted motion samples > 0
- [ ] Validation status = **Prototype Control Active**
- [ ] No crashes, hangs, or assertion failures
- [ ] RANE / replay regression check clean

**Conclusion:** ScratchLab Timecode Prototype is functional on real hardware. Evidence recorded. Safe to document findings but no production commitment.

### PARTIAL — Diagnostics Work, Playback Blocked

Any of:

- [ ] Signal check passes BUT decode check fails (no accepted motion)
- [ ] Signal check passes BUT confidence persistently below threshold
- [ ] Diagnostics produce valid RMS/peak but decode produces no output
- [ ] Playback bridge blocks on validation despite signal being present

**Conclusion:** Audio pipeline is receiving timecode signal. Signal diagnostics are valid. Decoder or playback bridge needs investigation — likely calibration (input channel, min confidence, signal threshold) or signal quality issue. Record evidence from Sections 7 and 8.

### FAIL — No Decode / Bad Signal / Unstable

Any of:

- [ ] No signal — input device not receiving
- [ ] Clipped — gain staging problem
- [ ] Channel fault — cabling or routing issue
- [ ] Decode produces no accepted motion despite healthy signal
- [ ] Crash or hang during decode

**Conclusion:** Hardware or signal path issue. Triage with Section 7. If healthy signal reaches the tap but decode still produces nothing, the decoder may not support this timecode format — this is a prototype limitation, not a bug.

---

## 10. Safety Note

- **Prototype only.** This validation workflow exercises the ScratchLab Timecode Prototype (`#if DEBUG` + `#if ENABLE_TIMECODE_LIVE_TAP` gated). It does NOT test production DVS support.
- **No final Serato/SDJ compatibility claim.** All labels, presets, and UI copy use "prototype" and "experimental" language. The Generic DVS preset carries an explicit anti-claim.
- **No DRM bypass.** The prototype decoder extracts phase information from the timecode audio signal. It does not decrypt, authenticate, or circumvent any DRM scheme.
- **Do not commit audio fixtures.** Any `.wav` recordings, take files, or captured audio produced during validation must NOT be staged or committed. Keep them outside the repo.
- **Do not ship validation recordings.** Prototype takes recorded by `TimecodePrototypeRecorder` are in-memory only (`#if DEBUG`), never persisted to disk, and never reach the notation/export pipeline.
- **RANE / replay paths are independent.** The timecode pipeline injects motion at the `PlatterPositionTimeline` level via the playback bridge. It does not modify `HandDirectionTracker`, `PlatterPositionRecorder`, `MacCaptureEngine` audio processing, or the camera/Vision pipeline.

---

## Quick-Reference Commands

```bash
# Pre-flight
cd /Users/karlwatson/Downloads/ScratchLab
git status --short --branch
# Expected: main...origin/main [ahead 16], AI_HANDOFF.md + AI_HANDOFF/ + analysis/ dirty

# Build
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS' \
  build 2>&1 | tail -20

# Build for testing
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS' \
  build-for-testing 2>&1 | tail -5

# Run relevant Timecode tests with xcodebuild selectors.
# Do not use direct xcrun xctest for this project.
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeLiveTapTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeLiveIntegrationTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeSignalDiagnosticsTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeDecoderTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodePlaybackBridgeTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodePrototypeProfileTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodePrototypeRecorderTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeStabilityFilterTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeValidationTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/TimecodeFixtureValidationTests
xcodebuild \
  -project ScratchLab.xcodeproj \
  -scheme ScratchLabDesktop \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test \
  -only-testing:ScratchLabDesktopTests/ReplayPlatterSourceTrustGateTests
```

---

## Reference: Key Files

| What | File |
|------|------|
| Validation snapshot model | `ScratchLab/Models/TimecodeValidationSnapshot.swift` |
| Prototype profile | `ScratchLab/Models/TimecodePrototypeProfile.swift` |
| Prototype recorder | `ScratchLab/Models/TimecodePrototypeRecorder.swift` |
| Playback bridge | `ScratchLab/Models/TimecodePlaybackBridge.swift` |
| Control pipeline | `ScratchLab/Models/TimecodeControlPipeline.swift` |
| Phase decoder | `ScratchLab/Models/TimecodePhaseDecoder.swift` |
| Platter adapter | `ScratchLab/Models/TimecodePlatterAdapter.swift` |
| Stability filter | `ScratchLab/Models/TimecodeMotionStabilityFilter.swift` |
| Signal diagnostics | `ScratchLab/Models/TimecodeSignalDiagnostics.swift` |
| Control card (UI) | `ScratchLabDesktop/Views/TimecodeControlCard.swift` |
| Input status card (UI) | `ScratchLabDesktop/Views/TimecodeInputStatusCard.swift` |
| Live tap tests | `ScratchLabDesktopTests/TimecodeLiveTapTests.swift` |
| Integration tests | `ScratchLabDesktopTests/TimecodeLiveIntegrationTests.swift` |
| Playback bridge tests | `ScratchLabDesktopTests/TimecodePlaybackBridgeTests.swift` |
| Profile tests | `ScratchLabDesktopTests/TimecodePrototypeProfileTests.swift` |
| Recorder tests | `ScratchLabDesktopTests/TimecodePrototypeRecorderTests.swift` |
| Stability filter tests | `ScratchLabDesktopTests/TimecodeStabilityFilterTests.swift` |
| Validation tests | `ScratchLabDesktopTests/TimecodeValidationTests.swift` |
| Fixture validation report | `ScratchLab/Models/TimecodeFixtureValidationReport.swift` |

---

## Reference: Default Thresholds (ScratchLab Prototype Profile)

| Threshold | Value | Notes |
|-----------|-------|-------|
| Input channel | Stereo | L+R quadrature |
| Invert direction | false | |
| Rate scale | 1.0× | |
| Min confidence | 0.30 | Decoded frame acceptance |
| Max rate | 5.0 u/s | Velocity clamp |
| Signal threshold RMS | 0.0001 (default) | Silence detection floor |
| EMA alpha (smoothing) | 0.12 | Conservative |
| Spike rejection | 15.0 u/s | Max rate step between frames |
| Short dropout mask | 3 frames | Hold window before EMA reset |
| Trust rebuild | 4 frames | Frames required after EMA reset |
| Validation required | true | Playback bridge gate |
| Playback bridge allowed | false | Must be explicitly enabled |

---

*End of runbook. Do not stage or commit audio fixtures. Do not claim Serato/SDJ compatibility. Prototype only.*
