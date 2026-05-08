// swift-tools-version: 5.9
//
// TrainModels — local development tooling. Provides:
//   * ScratchLabML — the runtime library shared with the iOS app. Sources
//     live in `ScratchLab/ML/` so the app target and this package compile
//     identical files; the package exists to host unit tests on macOS.
//   * SoundTrainer — CreateML-driven training logic (macOS only).
//   * train-sound-classifier — thin CLI that wraps SoundTrainer.
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
        .executable(name: "train-sound-classifier", targets: ["TrainSoundClassifier"])
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
        .testTarget(
            name: "ScratchLabMLTests",
            dependencies: ["ScratchLabML"],
            path: "Tests/ScratchLabMLTests"
        ),
        .testTarget(
            name: "SoundTrainerTests",
            dependencies: ["SoundTrainer", "ScratchLabML"],
            path: "Tests/SoundTrainerTests"
        )
    ]
)
