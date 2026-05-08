# ScratchLab/ML

Phase 1 runtime library for Core ML scratch classification. Sound classifier is real; action classifier is a stub.

## Files

```
ScratchClassLabel.swift          23-case enum; rawValues = trained class folder names
ScratchSoundClassifier.swift     Wraps SNAudioStreamAnalyzer + a Core ML sound model
ScratchActionClassifier.swift    Phase 2 stub — protocol + no-op implementation
ScratchClassifier.swift          Coordinator (sound now, fused with motion in Phase 2)
Models/                          .mlmodel / .mlmodelc files land here once trained
```

## Adding to the Xcode target

The project does **not** use synchronized folders, so these files are not
auto-included. Drag `ScratchLab/ML` into the project navigator inside Xcode
and tick **ScratchLab** as the target. Don't tick any test targets unless you
also wire up the runtime tests in this repo.

The trained sound model goes into `ScratchLab/ML/Models/`. Once it's there,
add it to the **Copy Bundle Resources** build phase of the **ScratchLab**
target. **Do not** add training audio, video, or any dataset folders to the
bundle — only the compiled `.mlmodel` (Xcode compiles to `.mlmodelc` at build
time).

## Training the model

The training CLI lives at `Tools/TrainModels/` (Swift Package, macOS-only).
See [Tools/TrainModels/README.md](../../Tools/TrainModels/README.md). The CLI
reads from a dataset path you pass at runtime — nothing is bundled.

## Wiring into the app

```swift
import AVFoundation

let coordinator = ScratchClassifier()
let format = audioEngine.inputNode.outputFormat(forBus: 0)
coordinator.start(audioFormat: format)

audioEngine.inputNode.installTap(onBus: 0,
                                  bufferSize: 4096,
                                  format: format) { buffer, time in
    coordinator.ingestAudio(buffer: buffer, at: time)
}

// SwiftUI:
@StateObject var classifier = ScratchClassifier()
// classifier.currentPrediction is @Published
```

Until a `.mlmodel` is added to the bundle, `start(...)` returns `false` and
`soundClassifier.lastError == .modelMissing(...)`.

## Phase 2 (later)

- Wire a feature-extracted motion classifier into `ScratchActionClassifier`.
  The motion model consumes `ScratchMotionFrame` (Vision-derived hand pose,
  record edge angle, fader position) — **not** raw camera frames.
- Implement fusion in `ScratchClassifier.handleSoundPrediction` so a unified
  prediction reflects both signals.
- Until then, do not surface `currentPrediction` in App Store-facing UI.

## Constraints

- No training data is bundled.
- No dataset folders are added to Copy Bundle Resources.
- Bundle ID, signing, App Store, and product identity are unchanged by this
  library.
