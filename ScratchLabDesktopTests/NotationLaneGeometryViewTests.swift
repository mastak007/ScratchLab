import XCTest
import SwiftUI
@testable import ScratchLab

/// Section 6 / Slice 2 — locks the contract of
/// `NotationLaneGeometryView` at the level appropriate for a
/// standalone SwiftUI Canvas view: the view initialises cleanly for
/// the empty and populated geometry inputs of Section 5, and the
/// source file holds the import-hygiene rules the slice promised.
///
/// SwiftUI rendering itself is verified by Xcode preview, not here.
final class NotationLaneGeometryViewTests: XCTestCase {

    // MARK: - Helpers

    private func laneStroke(
        primitiveIndex: Int = 0,
        xStart: Double = 0,
        xEnd: Double = 100,
        yStart: Double = 10,
        yEnd: Double = 30,
        family: ScratchFamily? = nil,
        coachingKinds: [CoachingEventKind] = []
    ) -> NotationLaneStrokeGeometry {
        NotationLaneStrokeGeometry(
            primitiveIndex: primitiveIndex,
            xStart: xStart,
            xEnd: xEnd,
            yStart: yStart,
            yEnd: yEnd,
            family: family,
            coachingKinds: coachingKinds
        )
    }

    private func gridline(kind: NotationGridlineKind, time: TimeInterval, x: Double) -> NotationGridlineGeometry {
        NotationGridlineGeometry(kind: kind, time: time, x: x)
    }

    // MARK: - 1. View can initialise with empty geometry

    func testInitializesWithEmptyGeometry() {
        let view = NotationLaneGeometryView(
            geometry: NotationLaneGeometryModel(strokes: []),
            gridlines: NotationGridlineGeometryModel(gridlines: []),
            playhead: nil
        )
        XCTAssertEqual(view.geometry.strokes.count, 0)
        XCTAssertEqual(view.gridlines.gridlines.count, 0)
        XCTAssertNil(view.playhead)
    }

    // MARK: - 2. View can initialise with one stroke

    func testInitializesWithOneStroke() {
        let stroke = laneStroke(
            primitiveIndex: 0,
            xStart: 0, xEnd: 100,
            yStart: 10, yEnd: 30,
            family: .baby,
            coachingKinds: [.lateReversal]
        )
        let view = NotationLaneGeometryView(
            geometry: NotationLaneGeometryModel(strokes: [stroke]),
            gridlines: NotationGridlineGeometryModel(gridlines: []),
            playhead: nil
        )
        XCTAssertEqual(view.geometry.strokes.count, 1)
        XCTAssertEqual(view.geometry.strokes.first?.family, .baby)
        XCTAssertEqual(view.geometry.strokes.first?.coachingKinds, [.lateReversal])
    }

    // MARK: - 3. View can initialise with gridlines

    func testInitializesWithGridlines() {
        let lines = [
            gridline(kind: .bar, time: 0.0, x: 0),
            gridline(kind: .beat, time: 0.5, x: 50),
            gridline(kind: .subdivision, time: 0.75, x: 75),
        ]
        let view = NotationLaneGeometryView(
            geometry: NotationLaneGeometryModel(strokes: []),
            gridlines: NotationGridlineGeometryModel(gridlines: lines),
            playhead: nil
        )
        XCTAssertEqual(view.gridlines.gridlines.count, 3)
        XCTAssertEqual(view.gridlines.gridlines.map(\.kind), [.bar, .beat, .subdivision])
    }

    // MARK: - 4. View can initialise with playhead

    func testInitializesWithPlayhead() {
        let playhead = NotationPlayheadGeometry(
            time: 1.0,
            x: 50,
            yTop: 0,
            yBottom: 40,
            isWithinViewport: true
        )
        let view = NotationLaneGeometryView(
            geometry: NotationLaneGeometryModel(strokes: []),
            gridlines: NotationGridlineGeometryModel(gridlines: []),
            playhead: playhead
        )
        XCTAssertEqual(view.playhead, playhead)
    }

    // MARK: - 5. Source file does not import AVFoundation/CoreML/CreateML/AppKit/UIKit/RealityKit/ARKit

    /// Reads the on-disk source of `NotationLaneGeometryView.swift`
    /// (resolved relative to this test file) and asserts that none of
    /// the forbidden module imports appear as actual `import …`
    /// statements. `SwiftUI` is the only sanctioned UI framework
    /// import for this view.
    func testSourceFileHasNoForbiddenImports() throws {
        let url = try sourceFileURL()
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let forbidden = ["AVFoundation", "CoreML", "CreateML", "AppKit", "UIKit", "RealityKit", "ARKit", "Combine"]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for module in forbidden {
                XCTAssertFalse(
                    trimmed.hasPrefix("import \(module)") || trimmed.hasPrefix("import \(module);"),
                    "NotationLaneGeometryView.swift must not import \(module): found \"\(trimmed)\""
                )
            }
        }
    }

    // MARK: - 6. View consumes only Section 5 geometry models

    /// Compile-time assertion. The initialiser only accepts the
    /// three Section 5 geometry types. If the view were modified to
    /// reach into capture/replay/export/ML, the call below would
    /// fail to compile because those types would need to thread
    /// through the signature.
    func testConsumesOnlySection5GeometryModels() {
        let view = NotationLaneGeometryView(
            geometry: NotationLaneGeometryModel(strokes: []),
            gridlines: NotationGridlineGeometryModel(gridlines: []),
            playhead: nil
        )
        // Reading the body must not crash. We don't inspect drawing
        // commands — Xcode preview owns visual verification.
        _ = view.body
    }

    // MARK: - Source-file path resolver

    private func sourceFileURL() throws -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        // #filePath: <root>/ScratchLabDesktopTests/NotationLaneGeometryViewTests.swift
        // source:    <root>/ScratchLab/Views/Notation/NotationLaneGeometryView.swift
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let viewURL = projectRoot
            .appendingPathComponent("ScratchLab")
            .appendingPathComponent("Views")
            .appendingPathComponent("Notation")
            .appendingPathComponent("NotationLaneGeometryView.swift")
        guard FileManager.default.fileExists(atPath: viewURL.path) else {
            throw NSError(
                domain: "NotationLaneGeometryViewTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Source file not found at \(viewURL.path)"]
            )
        }
        return viewURL
    }
}
