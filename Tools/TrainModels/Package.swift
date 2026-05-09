// swift-tools-version: 5.9
//
// TrainModels — local development tooling. Provides:
//   * ScratchLabML — the runtime library shared with the iOS app. Sources
//     live in `ScratchLab/ML/` so the app target and this package compile
//     identical files; the package exists to host unit tests on macOS.
//   * SoundTrainer — CreateML-driven training logic (macOS only) plus a
//     synchronous file-classification helper used by the smoke-test CLI.
//   * MotionTrainer — Vision-driven offline motion-feature extraction +
//     dataset validation for the Phase 2 action classifier. No CreateML
//     in this slice; this just produces JSONL feature caches.
//   * train-sound-classifier — thin CLI that wraps SoundTrainer.
//   * test-sound-classifier — dev-only CLI that runs predictions over a
//     dataset folder to validate a trained .mlmodel before bundling.
//   * train-action-classifier — Phase 2 CLI that validates an action
//     dataset and (optionally) extracts motion features to a JSONL cache.
//     Does NOT train a model in this slice.
//
// This package is NOT a dependency of the iOS app. Bundling: no dataset, no
// training audio/video, no provenance metadata in any artefact.

import PackageDescription

let package = Package(
    name: "TrainModels",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ScratchLabML", targets: ["ScratchLabML"]),
        .library(name: "SoundTrainer", targets: ["SoundTrainer"]),
        .library(name: "MotionTrainer", targets: ["MotionTrainer"]),
        .executable(name: "train-sound-classifier",  targets: ["TrainSoundClassifier"]),
        .executable(name: "test-sound-classifier",   targets: ["TestSoundClassifier"]),
        .executable(name: "train-action-classifier", targets: ["TrainActionClassifier"])
    ],
    targets: [
        // Runtime library. `Sources/ScratchLabML` is a symlink to the canonical
        // `ScratchLab/ML` so this package and the iOS app compile the same
        // source files — single source of truth, no duplication.
        .target(
            name: "ScratchLabML",
            path: "Sources/ScratchLabML",
            exclude: ["README.md", "Models"]
        ),
        // Training logic. Source uses `#if os(macOS)` to avoid pulling
        // CreateML on iOS builds.
        .target(
            name: "SoundTrainer",
            dependencies: ["ScratchLabML"],
            path: "Sources/SoundTrainer"
        ),
        // Thin executable wrapping the trainer.
        .executableTarget(
            name: "TrainSoundClassifier",
            dependencies: ["SoundTrainer"],
            path: "Sources/TrainSoundClassifier"
        ),
        // Dev-only smoke-test CLI: loads a trained .mlmodel from disk and
        // runs predictions over a dataset directory. Never bundles either.
        .executableTarget(
            name: "TestSoundClassifier",
            dependencies: ["SoundTrainer"],
            path: "Sources/TestSoundClassifier"
        ),
        // Phase 2 motion-feature pipeline. Vision is macOS/iOS-only; the
        // source uses Foundation + AVFoundation + Vision unconditionally
        // because the package's platforms list pins macOS 14 / iOS 17.
        .target(
            name: "MotionTrainer",
            dependencies: ["ScratchLabML"],
            path: "Sources/MotionTrainer"
        ),
        // Thin executable wrapping the action-dataset validator and the
        // motion-feature extractor. Does NOT train a model.
        .executableTarget(
            name: "TrainActionClassifier",
            dependencies: ["MotionTrainer"],
            path: "Sources/TrainActionClassifier"
        ),
        .testTarget(
            name: "ScratchLabMLTests",
            dependencies: ["ScratchLabML"],
            path: "Tests/ScratchLabMLTests"
        ),
        .testTarget(
            name: "SoundTrainerTests",
            dependencies: ["SoundTrainer", "ScratchLabML"],
            path: "Tests/SoundTrainerTests"
        ),
        .testTarget(
            name: "MotionTrainerTests",
            dependencies: ["MotionTrainer", "ScratchLabML"],
            path: "Tests/MotionTrainerTests"
        )
    ]
)
