# ScratchLab Instruments Profiling Guide

ScratchLab emits Points-of-Interest signposts under the subsystem
`com.machelpnz.scratchlab`, category `pointsOfInterest`. Use Instruments to
visualise the audio → coach → notation → render pipeline and to localise
drift, render slowness, or missing pipeline stages without instrumenting
the UI.

## Steps

1. Open ScratchLab in Xcode.
2. Select the **ScratchLabDesktop** scheme.
3. **Product → Profile** (⌘I). Xcode rebuilds Release-config and hands the
   binary to Instruments.
4. Choose the **Time Profiler** template.
5. Add **Points of Interest** to the trace (toolbar `+` → search "Points of
   Interest" → drag onto the timeline).
6. Press **Record**.
7. In the running app:
   - **Practice → Listen** (start the coach demo).
   - Watch coach movement — let the phrase loop a few cycles.
   - Capture a short Baby Scratch take (Capture tab → Record → Stop).
   - Review the take (Review tab).
   - Open the notation monitor (Advanced tab → notation surfaces, or via
     `Open Performer Monitor`).
8. **Stop** recording.
9. Look for these signposts in the Points of Interest track. The names on
   the left are the human-readable signal; the names on the right are the
   exact `os_signpost` names emitted by the source — search for those in
   the Instruments name filter.

| Signal | Signpost name |
|---|---|
| Listen Audio Playback | `CoachPlaybackTick` |
| Coach Pose Lookup | `CoachPoseLookup` |
| Notation Playhead Tick | `NotationTick` |
| Captured Notation Render | `CapturedNotationRender` |
| Movement Event Build | `MovementEventBuild` |

Other signposts on the same track that round out the picture:
`AudioBufferReceived`, `AudioOnsetDetected`, `MIDIReceived`, `FaderMap`,
`HandDirectionAnalyze`, `MovementNormalize`, `NotationSnapshotCreate`,
`TargetNotationRender`, `CameraFrameProcess`, `CaptureFrameProcess`,
`AudioAnalyze`, `CoachRigUpdate`, `ExportZIP`.

## How to read the trace

### Healthy timing

- **Coach pose follows audio playback.** `CoachPlaybackTick` and
  `CoachPoseLookup` should fire interleaved at roughly the notation tick
  rate (~30–60 Hz during Listen). The `time` payload on `CoachPlaybackTick`
  and `CoachPoseLookup` should advance monotonically with each phrase
  cycle and reset cleanly when the demo loops.
- **Notation playhead follows audio playback.** `NotationTick` intervals
  appear back-to-back with no gaps while the coach is playing, and pause
  cleanly when the user pauses Listen.
- **Render markers stay light.** `TargetNotationRender` /
  `CapturedNotationRender` events should be sparse — one per SwiftUI body
  evaluation. Consistent fire rate roughly tied to frame rate.

### Drift

- `CoachPoseLookup.time` and `CoachPlaybackTick.time` payloads diverge
  over repeated phrase cycles instead of resetting at each loop boundary.
- Phrase-cycle markers (look for `NotationTick` density) start lagging
  behind audio onsets seen in `AudioBufferReceived` / `AudioOnsetDetected`.
- Mitigation: inspect `BabyScratchDemoPlaybackCoordinator.notationPhraseTime`
  and the loop wrap logic in `NotationVisualizerView.tick(...)`.

### Slow notation rendering

- `CapturedNotationRender` fires heavily (many events per frame) or its
  surrounding frame interval (Time Profiler frame band) spans tens of
  milliseconds while the rest of the pipeline is idle.
- High `count=` payload values on `CapturedNotationRender` suggest the
  snapshot has a lot of movement events; consider downsampling for the
  render but not for export.
- Mitigation: profile the Canvas closures inside
  `CapturedNotationDisplayView.body` and the lane-rendering helpers.

### Missing notation pipeline

- `MovementEventBuild` fires with `count=0` or never fires after a Stop,
  even when the user clearly performed hand motion during the take.
- Cross-check with `HandDirectionAnalyze` — if the camera path is alive,
  `HandDirectionAnalyze` should fire steadily during the take. If
  `HandDirectionAnalyze` is present but `MovementEventBuild count=0`, the
  detector is collecting samples but the fusion engine isn't producing
  events; inspect `RoutineNotationFusionEngine.snapshot(...)` and the
  trust thresholds.

### MIDI mapping issue

- `MIDIReceived` fires (controller traffic is reaching the app) but
  `FaderMap` stays at zero events — the learned crossfader CC mapping is
  missing or doesn't match the controller's CC.
- Mitigation: in Capture → Input details, re-run **Learn crossfader** with
  the actual fader you want to map and verify `FaderMap` events appear in
  a fresh trace.

## CLI alternative

```bash
xcrun xctrace record \
  --template "Time Profiler" \
  --launch /path/to/ScratchLab.app
```

Open the resulting `.trace` in Instruments and add the Points of Interest
instrument. Filter the subsystem to `com.machelpnz.scratchlab` to hide
system signposts.

## Notes

- Signposts emit only counts, take numbers, and `time=` doubles. No
  filenames, UUIDs, or paths are attached — safe to capture and share.
- The signpost API is effectively zero-cost when no Instruments client is
  attached, so this instrumentation is safe to leave compiled into Debug
  and Release builds.
