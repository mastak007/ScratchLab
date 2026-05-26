import XCTest
@testable import ScratchLab

final class OverlayDirectionDiagnosticsTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_781_050_000)
    private static let tolerance: TimeInterval = 0.080
    private static let radius: TimeInterval = 0.500

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - Empty input

    func testEmptyDiagnosticsProducesNoDirectionFindings() {
        let overlay = makeOverlay(target: [], captured: [])
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        XCTAssertTrue(direction.findings.isEmpty)
        XCTAssertEqual(direction.schemaVersion,
                       OverlayDirectionDiagnostics.currentSchemaVersion)
    }

    // MARK: - Agree / disagree

    func testSameDirectionAgrees() {
        let overlay = makeOverlay(
            target:   [(0.50, "forward")],
            captured: [(0.52, "forward")]
        )
        let direction = compute(for: overlay)
        XCTAssertEqual(direction.findings.count, 1)
        let finding = direction.findings[0]
        XCTAssertEqual(finding.agreement, .agree)
        XCTAssertEqual(finding.targetSourceIndex, 0)
        XCTAssertEqual(finding.capturedSourceIndex, 0)
        XCTAssertEqual(finding.targetDirection, "forward")
        XCTAssertEqual(finding.capturedDirection, "forward")
    }

    func testOppositeDirectionDisagrees() {
        let overlay = makeOverlay(
            target:   [(0.50, "forward")],
            captured: [(0.52, "backward")]
        )
        let direction = compute(for: overlay)
        XCTAssertEqual(direction.findings.count, 1)
        let finding = direction.findings[0]
        XCTAssertEqual(finding.agreement, .disagree)
        XCTAssertEqual(finding.targetDirection, "forward")
        XCTAssertEqual(finding.capturedDirection, "backward")
    }

    // MARK: - Unknown when direction is missing

    func testMissingTargetDirectionIsUnknown() {
        // Empty target direction simulates "the target side never
        // recorded which way the stroke went". `agreement` must be
        // `.unknown` and `targetDirection` must surface as nil
        // (not the empty string).
        let overlay = makeOverlay(
            target:   [(0.50, "")],
            captured: [(0.52, "forward")]
        )
        let direction = compute(for: overlay)
        XCTAssertEqual(direction.findings.count, 1)
        let finding = direction.findings[0]
        XCTAssertEqual(finding.agreement, .unknown)
        XCTAssertNil(finding.targetDirection)
        XCTAssertEqual(finding.capturedDirection, "forward")
    }

    func testMissingCapturedDirectionIsUnknown() {
        let overlay = makeOverlay(
            target:   [(0.50, "forward")],
            captured: [(0.52, "")]
        )
        let direction = compute(for: overlay)
        XCTAssertEqual(direction.findings.count, 1)
        let finding = direction.findings[0]
        XCTAssertEqual(finding.agreement, .unknown)
        XCTAssertEqual(finding.targetDirection, "forward")
        XCTAssertNil(finding.capturedDirection)
    }

    func testBothDirectionsMissingIsUnknown() {
        let overlay = makeOverlay(
            target:   [(0.50, "")],
            captured: [(0.52, "")]
        )
        let direction = compute(for: overlay)
        XCTAssertEqual(direction.findings.count, 1)
        XCTAssertEqual(direction.findings[0].agreement, .unknown)
        XCTAssertNil(direction.findings[0].targetDirection)
        XCTAssertNil(direction.findings[0].capturedDirection)
    }

    // MARK: - Early / late still compare direction

    func testEarlyPairComparesDirection() {
        // Captured 200 ms before target — outside the 80 ms tolerance
        // → timing finding is `.early`. Direction should still be
        // compared, not skipped.
        let overlay = makeOverlay(
            target:   [(1.00, "forward")],
            captured: [(0.80, "backward")]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(timing.findings.first?.kind, .early,
                       "sanity: offset 0.20s with 0.08s tolerance must classify as early")
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        XCTAssertEqual(direction.findings.count, 1)
        XCTAssertEqual(direction.findings[0].agreement, .disagree)
    }

    func testLatePairComparesDirection() {
        let overlay = makeOverlay(
            target:   [(1.00, "forward")],
            captured: [(1.20, "forward")]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(timing.findings.first?.kind, .late)
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        XCTAssertEqual(direction.findings.count, 1)
        XCTAssertEqual(direction.findings[0].agreement, .agree)
    }

    // MARK: - Missing / extra excluded

    func testMissingAndExtraTimingFindingsAreExcludedFromDirection() {
        // Targets 0.25 + 0.75 with no nearby captureds → both
        // `.missing`. Captureds 2.50 + 3.50 with no nearby targets
        // → both `.extra` (outside the 0.500 s radius). No paired
        // findings → no direction findings.
        let overlay = makeOverlay(
            target:   [(0.25, "forward"), (0.75, "backward")],
            captured: [(2.50, "forward"), (3.50, "backward")]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        // Sanity: every timing finding is unpaired.
        for finding in timing.findings {
            XCTAssertTrue(finding.kind == .missing || finding.kind == .extra)
        }
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        XCTAssertTrue(direction.findings.isEmpty,
                      "direction findings must be empty when every timing finding is unpaired")
    }

    // MARK: - Mixed scenario

    func testMixedScenarioCountsAgreeDisagreeUnknown() {
        // Targets: 0.25 (forward), 0.75 (forward), 1.25 (backward),
        //          1.75 (forward), 2.50 (backward).
        // Captureds: 0.27 forward (matched, agree),
        //            0.60 backward (early, disagree),
        //            1.74 ""       (late for 1.25, unknown),
        //            2.70 backward (late for 2.50, agree),
        //            3.50 forward (extra → excluded).
        //
        // Note: this mirrors the Slice 4.4 mixed fixture so the
        // pairing layer's behaviour is well-understood.
        let overlay = makeOverlay(
            target: [
                (0.25, "forward"),
                (0.75, "forward"),
                (1.25, "backward"),
                (1.75, "forward"),
                (2.50, "backward")
            ],
            captured: [
                (0.27, "forward"),
                (0.60, "backward"),
                (1.74, ""),
                (2.70, "backward"),
                (3.50, "forward")
            ]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )

        // 5 timing findings of which 4 are paired (matched, early,
        // late, late) and one is `.missing` (target 1.75 has nothing
        // within radius after captured 1.74 was claimed by target
        // 1.25). One captured (3.50) is `.extra`. So direction
        // findings count == 4.
        XCTAssertEqual(direction.findings.count, 4)

        var counts: [OverlayDirectionFinding.Agreement: Int] = [:]
        for finding in direction.findings {
            counts[finding.agreement, default: 0] += 1
        }
        XCTAssertEqual(counts[.agree]    ?? 0, 2)
        XCTAssertEqual(counts[.disagree] ?? 0, 1)
        XCTAssertEqual(counts[.unknown]  ?? 0, 1)

        XCTAssertEqual(direction.counts[.agree] ?? 0, 2)
        XCTAssertEqual(direction.counts[.disagree] ?? 0, 1)
        XCTAssertEqual(direction.counts[.unknown] ?? 0, 1)

        // Order: direction findings preserve the order of paired
        // timing findings. Walk the timing findings and verify the
        // direction findings line up index-by-index for paired
        // entries, with missing/extra skipped.
        var directionIterator = direction.findings.makeIterator()
        for timing in timing.findings {
            switch timing.kind {
            case .matched, .early, .late:
                guard let next = directionIterator.next() else {
                    XCTFail("direction findings array exhausted before timing findings")
                    return
                }
                XCTAssertEqual(next.targetSourceIndex, timing.targetSourceIndex)
                XCTAssertEqual(next.capturedSourceIndex, timing.capturedSourceIndex)
            case .missing, .extra:
                continue
            }
        }
        XCTAssertNil(directionIterator.next(),
                     "direction findings array should be exhausted")
    }

    // MARK: - Determinism

    func testIdenticalInputsProduceIdenticalOutputs() {
        let overlay = makeOverlay(
            target:   [(0.25, "forward"), (0.75, "backward")],
            captured: [(0.27, "forward"), (0.80, "forward")]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        let first = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        let second = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
        XCTAssertEqual(first, second)
    }

    // MARK: - JSON encoding determinism + round-trip

    func testDeterministicJSONEncoding() throws {
        let overlay = makeOverlay(
            target:   [(0.25, "forward"), (0.75, "backward")],
            captured: [(0.27, "forward"), (0.78, "forward")]
        )
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        let direction = OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )

        let first = try encoder.encode(direction)
        let second = try encoder.encode(direction)
        XCTAssertEqual(first, second,
                       "Same inputs must encode to byte-identical JSON")

        let decoded = try JSONDecoder().decode(
            OverlayDirectionDiagnostics.self,
            from: first
        )
        XCTAssertEqual(decoded, direction, "Round-trip preserves equality")
        XCTAssertEqual(decoded.schemaVersion,
                       OverlayDirectionDiagnostics.currentSchemaVersion)
    }

    // MARK: - Helpers

    private func compute(for overlay: ReviewOverlayTimeline) -> OverlayDirectionDiagnostics {
        let timing = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        return OverlayDirectionDiagnostics.compute(
            timingDiagnostics: timing,
            overlay: overlay
        )
    }

    private func makeOverlay(
        target: [(startTime: Double, direction: String)],
        captured: [(startTime: Double, direction: String)]
    ) -> ReviewOverlayTimeline {
        let span = max(
            (target.map(\.startTime).max() ?? 0) + 0.5,
            (captured.map(\.startTime).max() ?? 0) + 0.5
        )
        return ReviewOverlayTimeline(
            target: makeTimeline(events: target, takeDuration: span),
            captured: makeTimeline(events: captured, takeDuration: span)
        )
    }

    private func makeTimeline(
        events: [(startTime: Double, direction: String)],
        takeDuration: Double
    ) -> SessionReplayTimeline {
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["movement"],
            recordMovementEvents: events.map { event in
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: event.startTime,
                    endTime: event.startTime + 0.05,
                    startPosition: 0.0,
                    endPosition: 1.0,
                    direction: event.direction,
                    movementKind: .normalPush,
                    speed: 1.0,
                    confidence: 0.8,
                    source: "detected"
                )
            },
            audioEvents: [],
            faderEvents: [],
            mixerMidiEvents: [],
            capturedAt: Self.referenceDate
        )
        return SessionReplayTimeline.build(from: snapshot, takeDuration: takeDuration)
    }
}
