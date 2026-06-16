# Timecode Batch 1 — Architecture Audit

**Date:** 2026-06-17
**Status:** Foundation only — no final decoder, no commercial compatibility claim.

---

## 1. Existing Audio Capture / Input Path

### Desktop (macOS)

- **MacCaptureEngine** (`ScratchLabDesktop/Services/MacCaptureEngine.swift`, ~5477 lines)
  - Uses `AVCaptureSession` with `AVCaptureAudioDataOutput`
  - Audio input selection via `AVCaptureDevice.DiscoverySession`
  - Buffer flow: `CMSampleBuffer` → `audioPacket(from:)` → `AudioPacket { [Float], sampleRate }`
  - RMS computed via `vDSP_rmsqv` with 10× gain
  - Feeds `MacScratchDetector.process(samples:sampleRate:)` for baby scratch detection
  - During recording, feeds `RoutineAudioCaptureWriter` (WAV output) and `ScratchAudioNotationDetector`
  - Serato direct capture: `AudioHardwareCreateProcessTap` (macOS 14.2+) + aggregate device

### iOS

- **AudioEngine** (`ScratchLab/Audio/AudioEngine.swift`, ~1664 lines)
  - Uses `AVAudioEngine.inputNode.installTap(onBus:bufferSize:format:)`
  - Buffer flow: `AVAudioPCMBuffer` → `audioPacket(from:)` → `InputAudioPacket { [Float], sampleRate }`
  - FFT analysis with 2048-sample windows, 50% overlap
  - Pattern matching via `ScratchPatternMatcher`

### Key observation

Both pipelines convert raw audio buffers into `AudioPacket`-like structs carrying `[Float]` samples + sample rate. The timecode tap should follow the same pattern: accept raw samples, compute basic diagnostics, but NOT run FFT or pattern matching in Batch 1.

---

## 2. Existing Scratch Playback / Platter Control Path

### Live Camera Path (production)

```
Camera → Vision hand pose → HandDirectionTracker.recordObservation
  → RoutineDetectedNotationBuilder.recordObservation
  → RoutineNotationEventNormalizer.normalize
  → RoutineNotationFusionEngine.fuseMovementEvents
  → DetectedNotationSnapshot
```

### Replay Path

```
PlatterPositionTimeline → replayDiagnosticsFromPlatterTimeline()
  → HandDirectionTracker (replay mode)
  → RoutineDetectedNotationBuilder (replay mode)
  → RoutineNotationFusionEngine (isReplaySource: true, bypasses gates)
  → frozenReviewDiagnostics
```

### Virtual Platter Path (prototype, DEBUG-gated)

```
DragGesture → VirtualPlatter → VirtualPlatterSampleMapper → AVAudioPlayer
```

### Where decoded timecode motion should eventually feed

Timecode-derived motion (after decoding) would enter at the **PlatterPositionRecorder** level — producing `PlatterPositionSample` entries that feed into `PlatterPositionTimeline`. This is the same abstraction that the RANE platter and replay sources use.

For Batch 1, we do NOT implement any decoder. We only prepare the input buffer abstraction that a future decoder would read from.

---

## 3. Existing Debug / Review Card Patterns

### Card styling conventions

- **Sidebar cards:** `.background(Color(nsColor: .controlBackgroundColor), RoundedRectangle(cornerRadius: 18))`, padding 14-20
- **Stage cards:** `.background(Color.white.opacity(0.05), RoundedRectangle(cornerRadius: 18))`, padding 16
- **Inner sections:** `.background(Color.white.opacity(0.04), RoundedRectangle(cornerRadius: 12))`

### Debug gating

- All debug cards use `#if DEBUG`
- `AdvancedSection` enum with `@AppStorage` persisted section picker
- Debug cards in the review sidebar: `platterTimelineDebugCard` (inside `#if DEBUG`)

### Existing debug views

- `TravelLaneDebugView` — standalone DEBUG-gated panel
- `platterTimelineDebugCard` — inline card in review sidebar
- `debugNotationDiagnosticChip` — single-row mono chip under stage cards
- `movementFunnelInlineView` — precomputed debug funnel text rows

---

## 4. Existing Fixture / Test-Loading Patterns

### Patterns used

1. **Bundle JSON fixtures** — checked-in `.json` in `ScratchLabDesktopTests/Fixtures/`, loaded via `Bundle(for: Self.self)`
2. **Env-var-gated local fixtures** — `XCTSkip` when env var is unset, never bundled
3. **Inline JSON in test code** — `Data(json.utf8)` + `JSONDecoder`
4. **Synthetic struct construction** — direct model object creation with test values
5. **Stub/mock protocol implementations** — for classifier/engine dependencies

### Audio in tests

- No test loads actual WAV audio
- `BabyScratchClassifier.testBabyScratchClassifierIsSilentOnEmptyAudio` passes empty `[Float]` samples
- For Batch 1, we follow the same pattern: synthetic buffers only, no audio file loading

---

## 5. What Must Not Be Touched

- `MacCaptureEngine` — no changes to live capture pipeline
- `HandDirectionTracker` — no changes to direction tracking state machine
- `RoutineDetectedNotationBuilder` / `RoutineNotationEventNormalizer` / `RoutineNotationFusionEngine` — no changes
- `PlatterPositionRecorder` — no changes
- Replay trust logic (`isReplaySource`, `replayDiagnosticsFromPlatterTimeline`)
- Camera overlay logic (`CameraPassthroughNotationView`, `CameraNotationOverlayCalibration`)
- Notation pipeline (`LiveNotationOverlayModel`, captured notation)
- `AudioEngine` (iOS) — no changes
- Export/upload schema — no changes
- Build numbers, bundle IDs, signing — no changes
- Pre-existing dirty docs (`AI_HANDOFF.md`, `AI_HANDOFF/`, `analysis/`, `deep-research-skills/`) — keep unstaged

---

## 6. Proposed New Files / Classes for Batch 1

All new model files go in `ScratchLab/Models/` (shared framework, no platform dependency).
The debug UI goes in `ScratchLabDesktop/Views/`.
Tests go in `ScratchLabDesktopTests/`.

| File | Type | Purpose |
|------|------|---------|
| `ScratchLab/Models/TimecodeInputSample.swift` | Struct | Single stereo sample with hostTime, L/R values, flags |
| `ScratchLab/Models/TimecodeAudioBuffer.swift` | Struct | Multi-sample buffer with format metadata |
| `ScratchLab/Models/TimecodeSourceState.swift` | Struct/Enum | Source selection state |
| `ScratchLab/Models/TimecodeSignalDiagnostics.swift` | Struct | Pure diagnostics engine (RMS, peak, clipping, silence, imbalance, health enum) |
| `ScratchLab/Models/TimecodeInputTap.swift` | Class | Tap abstraction (buffer accumulator, diagnostics producer) |
| `ScratchLabDesktop/Views/TimecodeInputStatusCard.swift` | View | DEBUG-gated status card in Advanced sidebar |
| `ScratchLabDesktopTests/TimecodeSignalDiagnosticsTests.swift` | XCTestCase | Pure unit tests, no hardware required |

**No new WAV/fixture files** unless explicitly approved. Tests use synthetic `[Float]` buffers.

---

## 7. Proposed Future Slice Plan

### Batch 2 — Timecode Decoder (future)
- Implement timecode signal decoder (frequency-shift keying or equivalent)
- Extract absolute position and direction from timecode audio
- Map decoded position to platter motion

### Batch 3 — Timecode Motion Integration (future)
- Feed decoded timecode motion into `PlatterPositionRecorder`
- Produce `PlatterPositionTimeline` from timecode source
- Enable timecode-driven replay path

### Batch 4 — Timecode Source Selection UX (future)
- Production UI for timecode input source selection
- Calibration workflow
- Integration with existing audio input routing

---

## 8. Data Flow Diagram (Batch 1 Scope)

```
┌─────────────────────────────────────────────────────┐
│  Batch 1 scope                                      │
│                                                     │
│  Synthetic [Float] buffers (tests)                  │
│         │                                           │
│         ▼                                           │
│  TimecodeInputTap                                   │
│    ├── accumulate buffers                           │
│    ├── produce TimecodeAudioBuffer                  │
│    └── expose for diagnostics                       │
│         │                                           │
│         ▼                                           │
│  TimecodeSignalDiagnostics                          │
│    ├── compute L/R RMS                              │
│    ├── compute L/R peak                             │
│    ├── detect clipping                              │
│    ├── detect silence                               │
│    ├── detect channel imbalance                     │
│    ├── detect mono/stereo                           │
│    └── produce SignalHealth enum                    │
│         │                                           │
│         ▼                                           │
│  TimecodeInputStatusCard (#if DEBUG)                │
│    ├── source selection / inactive                  │
│    ├── L/R level bars                               │
│    ├── signal health badge                          │
│    └── warnings (silence/clipping/channel)          │
│                                                     │
├─────────────────────────────────────────────────────┤
│  Future batches (not implemented)                   │
│                                                     │
│  Live audio input → TimecodeDecoder → PlatterPos…   │
│  → HandDirectionTracker → Notation pipeline         │
└─────────────────────────────────────────────────────┘
```

---

## 9. Key Decisions

1. **Pure models in shared framework** — `TimecodeInputSample`, `TimecodeAudioBuffer`, `TimecodeSignalDiagnostics`, `TimecodeSourceState` live in `ScratchLab/Models/` so both macOS and iOS can import them. No platform-specific code.

2. **Tap is model-only in Batch 1** — `TimecodeInputTap` is a class (reference type, so it can be shared/observed) but does NOT connect to `AVCaptureSession` or `AVAudioEngine`. It exposes a `push(buffer:)` method for synthetic/test use and a `diagnose()` method. Live audio wiring is deferred to `#if DEBUG && ENABLE_TIMECODE_LIVE_TAP` gate.

3. **No decoder** — deliberately no FSK demodulation, no position extraction, no timecode protocol implementation.

4. **No commercial claims** — all diagnostics are labeled "signal health" not "decoded position."

5. **DEBUG-gated UI** — the status card only appears in `#if DEBUG` builds, inside the Advanced → Audio section.

6. **Synthetic-only tests** — no WAV fixtures, no hardware dependency.
