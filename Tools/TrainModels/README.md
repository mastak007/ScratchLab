# TrainModels (dev tooling)

Local Swift Package providing:

- **ScratchLabML** — runtime library shared with the iOS app (the same source
  files live in `ScratchLab/ML/`). Hosted here so it can be unit-tested on
  macOS without a running app.
- **SoundTrainer** — CreateML-backed training logic for the scratch sound
  classifier. macOS-only (CreateML is macOS-only).
- **train-sound-classifier** — thin CLI executable.

## Constraints (enforced)

- No training data is bundled with the package or any product it builds.
- The CLI takes a `--dataset` path at runtime; nothing is hard-coded.
- Trained `.mlmodel` files are written with empty `MLModelMetadata` — no
  author, license, or version strings.
- This package is **not** a dependency of the iOS app; the runtime library
  files are shared via path reference, not via SPM linkage.
- Bundle ID, signing, App Store, and product identity are unaffected.

## Phase 1 scope

- Sound classifier only.
- Action / motion classifier is intentionally a stub
  ([ScratchActionClassifier.swift](../../ScratchLab/ML/ScratchActionClassifier.swift)).
  Phase 2 will land a feature-based motion model that consumes
  Vision-derived `ScratchMotionFrame` data, **not** raw camera frames.

## Running tests

```bash
cd Tools/TrainModels
swift test
```

Tests cover:
- `ScratchClassLabel` rawValue uniqueness, case count, model-label parsing
- `ScratchSoundClassifier` config defaults, model-missing error path,
  idempotent stop
- `ScratchClassifier` coordinator default wiring, dependency injection
- `ScratchActionClassifierStub` ingest/reset/throws-on-classify
- `SoundClassifierTrainer.validateDataset` happy path + every documented
  failure mode (missing dir, file-instead-of-dir, no class folders, unknown
  class folder, class below minimum)

Tests do not invoke CreateML training — that path is exercised manually via
the CLI.

## Training a model

Build the dataset first (Python pipeline at the repo root), then:

```bash
cd Tools/TrainModels

# Validate without training:
swift run train-sound-classifier \
    --dataset <path>/coreml_chapter2_dataset/coreml_ready/sound_classifier \
    --validate-only

# Train:
swift run train-sound-classifier \
    --dataset <path>/coreml_chapter2_dataset/coreml_ready/sound_classifier \
    --output  <path>/coreml_chapter2_dataset/models
```

The output directory will receive `ScratchSoundClassifier.mlmodel`. Drag that
file into Xcode under `ScratchLab/ML/Models/` and add it to the **ScratchLab**
target's **Copy Bundle Resources** phase. Xcode compiles it to `.mlmodelc`
during the build.

Training takes roughly 2–10 minutes on Apple Silicon depending on dataset
size and Apple's underlying feature extractor.

## Layout

```
Tools/TrainModels/
  Package.swift
  Sources/
    SoundTrainer/
      SoundClassifierTrainer.swift   Validation + (macOS) training
    TrainSoundClassifier/
      main.swift                     CLI entry
  Tests/
    ScratchLabMLTests/
      ScratchClassLabelTests.swift
      ScratchSoundClassifierTests.swift
      ScratchClassifierTests.swift
    SoundTrainerTests/
      SoundClassifierTrainerTests.swift
  README.md
```
