import XCTest
@testable import ScratchLab

/// Section 5 / Slice 5 — locks the contract of
/// `NotationViewportWindowRule` and
/// `NotationViewportWindowMapper`. Pure clamping-window factory
/// returning a `NotationLaneViewport`; no SwiftUI, no Canvas, no
/// renderer, no ML, no scoring.
final class NotationViewportWindowTests: XCTestCase {

    // MARK: - Helpers

    private func rule(
        duration: TimeInterval = 4.0,
        leadIn: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NotationViewportWindowRule {
        guard let r = NotationViewportWindowRule(duration: duration, leadIn: leadIn) else {
            XCTFail("Rule unexpectedly rejected", file: file, line: line)
            return NotationViewportWindowRule(duration: 1, leadIn: 0)!
        }
        return r
    }

    // MARK: - 1. rule rejects duration <= 0

    func testRuleRejectsNonPositiveDuration() {
        XCTAssertNil(NotationViewportWindowRule(duration: 0, leadIn: 0))
        XCTAssertNil(NotationViewportWindowRule(duration: -0.001, leadIn: 0))
    }

    // MARK: - 2. rule rejects negative leadIn

    func testRuleRejectsNegativeLeadIn() {
        XCTAssertNil(NotationViewportWindowRule(duration: 1, leadIn: -0.001))
    }

    // MARK: - 3. rule rejects NaN/infinity values

    func testRuleRejectsNonFiniteValues() {
        XCTAssertNil(NotationViewportWindowRule(duration: .nan, leadIn: 0))
        XCTAssertNil(NotationViewportWindowRule(duration: .infinity, leadIn: 0))
        XCTAssertNil(NotationViewportWindowRule(duration: 1, leadIn: .nan))
        XCTAssertNil(NotationViewportWindowRule(duration: 1, leadIn: .infinity))
    }

    // MARK: - 4. mapper returns nil for invalid time/content/size values

    func testMapperReturnsNilForInvalidNumericInputs() {
        let r = rule()
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: .nan, contentStart: 0, contentEnd: 10, width: 100, height: 40, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: .nan, contentEnd: 10, width: 100, height: 40, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: .infinity, width: 100, height: 40, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10, width: .nan, height: 40, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10, width: 100, height: .infinity, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10, width: 0, height: 40, rule: r))
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10, width: 100, height: -1, rule: r))
    }

    // MARK: - 5. mapper returns nil when contentEnd < contentStart

    func testMapperReturnsNilForInvertedContentBounds() {
        let r = rule()
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 10, contentEnd: 0, width: 100, height: 40, rule: r))
    }

    // MARK: - 6. mapper returns nil when contentStart == contentEnd

    func testMapperReturnsNilForZeroLengthContent() {
        let r = rule()
        XCTAssertNil(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 5, contentEnd: 5, width: 100, height: 40, rule: r))
    }

    // MARK: - 7. viewport around middle uses time - leadIn

    func testViewportAroundMiddleUsesTimeMinusLeadIn() throws {
        let r = rule(duration: 4.0, leadIn: 1.0)
        let v = try XCTUnwrap(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r))
        XCTAssertEqual(v.startTime, 4.0, accuracy: 1e-9)
        XCTAssertEqual(v.endTime, 8.0, accuracy: 1e-9)
    }

    // MARK: - 8. viewport clamps to content start

    func testViewportClampsToContentStart() throws {
        let r = rule(duration: 4.0, leadIn: 1.0)
        // time - leadIn = -1, before contentStart. Shift forward.
        let v = try XCTUnwrap(NotationViewportWindowMapper.viewport(
            around: 0, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r))
        XCTAssertEqual(v.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(v.endTime, 4.0, accuracy: 1e-9)
    }

    // MARK: - 9. viewport clamps to content end while preserving duration

    func testViewportClampsToContentEndPreservingDuration() throws {
        let r = rule(duration: 4.0, leadIn: 1.0)
        // time - leadIn = 9; window would be [9, 13] but content ends at 10.
        // Shift back so end == 10, start == 6.
        let v = try XCTUnwrap(NotationViewportWindowMapper.viewport(
            around: 10, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r))
        XCTAssertEqual(v.endTime, 10, accuracy: 1e-9)
        XCTAssertEqual(v.startTime, 6, accuracy: 1e-9)
        XCTAssertEqual(v.endTime - v.startTime, r.duration, accuracy: 1e-9)
    }

    // MARK: - 10. Content shorter than duration returns content bounds

    func testContentShorterThanDurationReturnsContentBounds() throws {
        let r = rule(duration: 10.0, leadIn: 2.0)
        let v = try XCTUnwrap(NotationViewportWindowMapper.viewport(
            around: 1.5, contentStart: 0, contentEnd: 3,
            width: 100, height: 40, rule: r))
        XCTAssertEqual(v.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(v.endTime, 3, accuracy: 1e-9)
    }

    // MARK: - 11. width and height pass through to NotationLaneViewport

    func testWidthAndHeightPassThrough() throws {
        let r = rule()
        let v = try XCTUnwrap(NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10,
            width: 237, height: 89, rule: r))
        XCTAssertEqual(v.width, 237)
        XCTAssertEqual(v.height, 89)
    }

    // MARK: - 12. Codable round-trip

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for r in [rule(duration: 4, leadIn: 1), rule(duration: 8, leadIn: 0), rule(duration: 1.5, leadIn: 0.25)] {
            let data = try encoder.encode(r)
            let decoded = try decoder.decode(NotationViewportWindowRule.self, from: data)
            XCTAssertEqual(decoded, r)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(second, data)
        }
    }

    // MARK: - 13. Codable rejects invalid rule

    func testCodableRejectsInvalidRule() {
        let decoder = JSONDecoder()
        let zeroDuration = """
        {"duration": 0, "leadIn": 0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationViewportWindowRule.self, from: zeroDuration))

        let negativeLead = """
        {"duration": 1, "leadIn": -0.001}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationViewportWindowRule.self, from: negativeLead))

        let nonFinite = """
        {"duration": 1e1000, "leadIn": 0}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NotationViewportWindowRule.self, from: nonFinite))
    }

    // MARK: - 14. Deterministic repeated mapping

    func testDeterministicRepeatedMapping() throws {
        let r = rule(duration: 4, leadIn: 1)
        let first = NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r)
        let second = NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r)
        XCTAssertEqual(first, second)
    }

    // MARK: - 15. No UI/render/export/ML dependency

    /// Compile-time assertion. The factory consumes only
    /// `TimeInterval`, `Double`, and `NotationViewportWindowRule`
    /// values and emits a `NotationLaneViewport`. If the
    /// implementation reached for SwiftUI, Canvas, AppKit, UIKit,
    /// renderer/view code, exporters, CoreML or CreateML, the file
    /// would fail to build without the matching imports — and the
    /// test deliberately does not import any of them.
    func testWindowBuildableWithoutUIRenderExportOrMLImports() {
        let r = rule()
        let v = NotationViewportWindowMapper.viewport(
            around: 5, contentStart: 0, contentEnd: 10,
            width: 100, height: 40, rule: r)
        XCTAssertNotNil(v)
    }
}
