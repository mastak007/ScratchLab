// swift-tools-version: 5.9
//
// ScratchNotation — local development tooling for generating ScratchLab
// notation timelines from dataset evidence (audio onsets, visual motion,
// optional beat grid). Phase 1: model + generator + JSON codec + tests.
// This package is intentionally NOT a dependency of the iOS app target;
// it produces JSON sidecars consumed by a future review UI.

import PackageDescription

let package = Package(
    name: "ScratchNotation",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "ScratchNotation",
            targets: ["ScratchNotation"]
        )
    ],
    targets: [
        .target(
            name: "ScratchNotation",
            path: "Sources/ScratchNotation"
        ),
        .testTarget(
            name: "ScratchNotationTests",
            dependencies: ["ScratchNotation"],
            path: "Tests/ScratchNotationTests"
        )
    ]
)
