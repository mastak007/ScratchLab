// CaptureCameraLayoutRegressionTests.swift
// ScratchLabDesktopTests
//
// 2026-08-22: guards against the exact Capture recording-layout regression
// Karl reported recurring — the camera preview expanding to dominate the
// window (`maxHeight: .infinity` with no cap) and `DeckGamificationOverlay`
// (stars/tracking boxes/Edit Boxes) appearing on Capture's "plain preview,
// no overlays" surface. `MacAnalyzerView` is not importable/host-testable
// here, so these are source-string checks — the same pattern already used
// elsewhere in this suite for SwiftUI layout facts (see
// `NotationSheetTests.showRigGuidesUsesCalibrationLocked`,
// `CaptureReliabilityPhase1Tests`'s `isCalibrationEditMode` check).

import Foundation
import Testing

private func layoutTestsRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func layoutSource(_ relativePath: String) throws -> String {
    try String(
        contentsOf: layoutTestsRepoRoot().appendingPathComponent(relativePath),
        encoding: .utf8
    )
}

/// The substring of `source` from the first occurrence of `start` up to the
/// next occurrence of `end`.
private func slice(_ source: String, from start: String, to end: String) throws -> String {
    let head = try #require(source.range(of: start), "source marker not found: \(start)")
    let rest = source[head.lowerBound...]
    let tail = try #require(rest.range(of: end), "source marker not found after start: \(end)")
    return String(rest[..<tail.lowerBound])
}

@Suite("Capture camera layout regression (2026-08-22)")
struct CaptureCameraLayoutRegressionTests {

    @Test("Capture's camera call site does not opt into the calibration/gamification overlay")
    func captureCameraDoesNotOptIntoCalibrationOverlay() throws {
        let source = try layoutSource("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let localCameraStage = try slice(
            source,
            from: "private var localCameraStage: some View {",
            to: "private func liveCameraStage("
        )
        #expect(!localCameraStage.contains("showsCalibrationOverlay: true"),
                "Capture's camera must stay plain video — DeckGamificationOverlay's stars/tracking boxes/Edit Boxes do not belong on the Capture preview")
    }

    @Test("Practice's camera call site still opts into the calibration overlay")
    func practiceCameraStillOptsIntoCalibrationOverlay() throws {
        let source = try layoutSource("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let practiceLiveInput = try slice(
            source,
            from: "private var practiceOptionalLiveInput: some View {",
            to: "private var practiceNotationShouldAnimate"
        )
        #expect(practiceLiveInput.contains("showsCalibrationOverlay: true"),
                "Practice's calibration box editing (Karl's explicit directive) must remain unaffected by the Capture-only fix")
    }

    @Test("liveCameraStage's calibration overlay defaults off")
    func liveCameraStageDefaultsOverlayOff() throws {
        let source = try layoutSource("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let signature = try slice(
            source,
            from: "private func liveCameraStage(",
            to: ") -> some View {"
        )
        #expect(signature.contains("showsCalibrationOverlay: Bool = false"),
                "the shared camera stage must default to plain video; only Practice opts in explicitly")
    }

    @Test("Capture's camera disclosure is height-bounded, not unconstrained")
    func captureCameraSectionIsHeightBounded() throws {
        let source = try layoutSource("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let section = try slice(
            source,
            from: "private var captureCameraSection: some View {",
            to: "private var reviewWorkspace: some View {"
        )
        #expect(section.contains(".frame(maxHeight: 320)"),
                "the camera content must carry an explicit height ceiling")
        #expect(!section.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
                "the outer disclosure must not claim all remaining vertical space in the Capture column")
    }

    @Test("Capture's main content column is scrollable, matching Practice's short-window fix")
    func captureWorkspaceIsScrollable() throws {
        let source = try layoutSource("ScratchLabDesktop/Views/MacAnalyzerView.swift")
        let workspace = try slice(
            source,
            from: "private var captureWorkspace: some View {",
            to: "private var isPracticeScoredAttemptActive: Bool {"
        )
        #expect(workspace.contains("ScrollView {"),
                "header + live notation + camera must stay reachable at short window heights")
    }
}
