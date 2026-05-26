import XCTest
@testable import ScratchLab

final class OverlayTimingDiagnosticsTests: XCTestCase {

    private static let referenceDate = Date(timeIntervalSince1970: 1_781_000_000)
    private static let tolerance: TimeInterval = 0.080
    private static let radius: TimeInterval = 0.500

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - Empty

    func testEmptyOverlayProducesNoFindings() {
        let overlay = makeOverlay(targetMovements: [], capturedMovements: [])
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertTrue(diag.findings.isEmpty)
        XCTAssertEqual(diag.toleranceSeconds, Self.tolerance)
        XCTAssertEqual(diag.pairingRadiusSeconds, Self.radius)
        XCTAssertEqual(diag.schemaVersion, OverlayTimingDiagnostics.currentSchemaVersion)
    }

    // MARK: - Perfect alignment

    func testPerfectAlignmentMatchesEverything() {
        let times: [Double] = [0.25, 0.50, 0.75, 1.00]
        let overlay = makeOverlay(targetMovements: times, capturedMovements: times)
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 4)
        for (index, finding) in diag.findings.enumerated() {
            XCTAssertEqual(finding.kind, .matched)
            XCTAssertEqual(finding.offsetSeconds ?? .nan, 0.0, accuracy: 1e-9)
            XCTAssertEqual(finding.targetSourceIndex, index)
            XCTAssertEqual(finding.capturedSourceIndex, index)
        }
    }

    // MARK: - All missing

    func testTargetWithNoCapturedIsAllMissing() {
        let overlay = makeOverlay(
            targetMovements: [0.25, 0.50, 0.75],
            capturedMovements: []
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 3)
        for (index, finding) in diag.findings.enumerated() {
            XCTAssertEqual(finding.kind, .missing)
            XCTAssertNil(finding.offsetSeconds)
            XCTAssertEqual(finding.targetSourceIndex, index)
            XCTAssertNil(finding.capturedSourceIndex)
        }
    }

    // MARK: - All extra

    func testCapturedWithNoTargetIsAllExtra() {
        let overlay = makeOverlay(
            targetMovements: [],
            capturedMovements: [0.1, 0.3, 0.5]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 3)
        for (index, finding) in diag.findings.enumerated() {
            XCTAssertEqual(finding.kind, .extra)
            XCTAssertNil(finding.offsetSeconds)
            XCTAssertNil(finding.targetSourceIndex)
            XCTAssertEqual(finding.capturedSourceIndex, index)
        }
    }

    // MARK: - Within-tolerance early/late labelled matched

    func testEarlyAndLateWithinToleranceLabelledMatched() {
        // Target at 1.0; captured slightly before and slightly after
        // (both well within the 80 ms tolerance).
        let overlay = makeOverlay(
            targetMovements: [1.0, 2.0],
            capturedMovements: [0.97, 2.05]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 2)
        XCTAssertEqual(diag.findings[0].kind, .matched)
        XCTAssertEqual(diag.findings[0].offsetSeconds ?? .nan, -0.03, accuracy: 1e-9)
        XCTAssertEqual(diag.findings[1].kind, .matched)
        XCTAssertEqual(diag.findings[1].offsetSeconds ?? .nan, 0.05, accuracy: 1e-9)
    }

    // MARK: - Outside-tolerance early/late classified

    func testEarlyAndLateOutsideToleranceClassified() {
        // Target at 1.0; captured 200 ms before (early) and target at
        // 2.0; captured 200 ms after (late). Both within the 500 ms
        // pairing radius so they pair to their respective targets.
        let overlay = makeOverlay(
            targetMovements: [1.0, 2.0],
            capturedMovements: [0.80, 2.20]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 2)
        XCTAssertEqual(diag.findings[0].kind, .early)
        XCTAssertEqual(diag.findings[0].offsetSeconds ?? .nan, -0.20, accuracy: 1e-9)
        XCTAssertEqual(diag.findings[0].targetSourceIndex, 0)
        XCTAssertEqual(diag.findings[0].capturedSourceIndex, 0)
        XCTAssertEqual(diag.findings[1].kind, .late)
        XCTAssertEqual(diag.findings[1].offsetSeconds ?? .nan, 0.20, accuracy: 1e-9)
        XCTAssertEqual(diag.findings[1].targetSourceIndex, 1)
        XCTAssertEqual(diag.findings[1].capturedSourceIndex, 1)
    }

    // MARK: - Two captured near one target

    func testDuplicateCapturedNearOneTargetChoosesClosest() {
        // Two captured strokes flank one target. The closer one
        // (offset 30 ms) matches; the farther one (offset 200 ms)
        // surfaces as `.extra` because the target was already claimed.
        let overlay = makeOverlay(
            targetMovements: [1.0],
            capturedMovements: [0.80, 1.03]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 2)

        let matched = diag.findings[0]
        XCTAssertEqual(matched.kind, .matched)
        XCTAssertEqual(matched.offsetSeconds ?? .nan, 0.03, accuracy: 1e-9)
        XCTAssertEqual(matched.targetSourceIndex, 0)
        XCTAssertEqual(matched.capturedSourceIndex, 1)

        let extra = diag.findings[1]
        XCTAssertEqual(extra.kind, .extra)
        XCTAssertNil(extra.offsetSeconds)
        XCTAssertNil(extra.targetSourceIndex)
        XCTAssertEqual(extra.capturedSourceIndex, 0)
    }

    // MARK: - Equidistant tie-break by source index

    func testEquidistantCapturedTieBreakBySourceIndex() {
        // Target at 1.0; two captured equidistant (offsets ±0.10).
        // Greedy pick must be deterministic — the captured with the
        // smaller `sourceIndex` (= 0, at startTime 0.90) wins; the
        // other surfaces as `.extra`.
        let overlay = makeOverlay(
            targetMovements: [1.0],
            capturedMovements: [0.90, 1.10]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag.findings.count, 2)

        let paired = diag.findings[0]
        XCTAssertEqual(paired.kind, .early,
                       "Offset 0.10 > 0.080 tolerance ⇒ early, not matched")
        XCTAssertEqual(paired.offsetSeconds ?? .nan, -0.10, accuracy: 1e-9)
        XCTAssertEqual(paired.capturedSourceIndex, 0)

        XCTAssertEqual(diag.findings[1].kind, .extra)
        XCTAssertEqual(diag.findings[1].capturedSourceIndex, 1)

        // Repeating the call must produce byte-identical output.
        let repeated = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(diag, repeated)
    }

    // MARK: - Mixed scenario

    func testMixedScenarioCombinesAllKinds() {
        // Targets: 0.25 (matched), 0.75 (early), 1.25 (missing — only
        // candidate is past pairingRadius), 1.75 (matched), 2.50
        // (late by 0.2s).
        // Captured: 0.27 (matched to 0.25), 0.60 (early for 0.75),
        // 1.74 (matched to 1.75), 2.70 (late for 2.50), 3.50 (extra,
        // too far from any remaining target).
        let overlay = makeOverlay(
            targetMovements: [0.25, 0.75, 1.25, 1.75, 2.50],
            capturedMovements: [0.27, 0.60, 1.74, 2.70, 3.50]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )

        XCTAssertEqual(diag.findings.count, 6,
                       "5 target findings + 1 leftover extra")

        XCTAssertEqual(diag.findings[0].kind, .matched)
        XCTAssertEqual(diag.findings[0].offsetSeconds ?? .nan, 0.02, accuracy: 1e-9)
        XCTAssertEqual(diag.findings[0].targetSourceIndex, 0)
        XCTAssertEqual(diag.findings[0].capturedSourceIndex, 0)

        XCTAssertEqual(diag.findings[1].kind, .early)
        XCTAssertEqual(diag.findings[1].offsetSeconds ?? .nan, -0.15, accuracy: 1e-9)
        XCTAssertEqual(diag.findings[1].targetSourceIndex, 1)
        XCTAssertEqual(diag.findings[1].capturedSourceIndex, 1)

        // Target 1.25 — nearest unclaimed captured (1.74) is 0.49s
        // away, still inside the 0.500 radius — so it pairs there as
        // `.late`. Target 1.75 then has no unclaimed candidate within
        // radius (the next is 2.70, offset 0.95 > radius), so it's
        // `.missing`.
        XCTAssertEqual(diag.findings[2].kind, .late)
        XCTAssertEqual(diag.findings[2].targetSourceIndex, 2)
        XCTAssertEqual(diag.findings[2].capturedSourceIndex, 2)
        XCTAssertEqual(diag.findings[2].offsetSeconds ?? .nan, 0.49, accuracy: 1e-9)

        XCTAssertEqual(diag.findings[3].kind, .missing)
        XCTAssertEqual(diag.findings[3].targetSourceIndex, 3)
        XCTAssertNil(diag.findings[3].capturedSourceIndex)

        XCTAssertEqual(diag.findings[4].kind, .late)
        XCTAssertEqual(diag.findings[4].targetSourceIndex, 4)
        XCTAssertEqual(diag.findings[4].capturedSourceIndex, 3)
        XCTAssertEqual(diag.findings[4].offsetSeconds ?? .nan, 0.20, accuracy: 1e-9)

        // Captured at 3.50 has no remaining target within radius.
        XCTAssertEqual(diag.findings[5].kind, .extra)
        XCTAssertNil(diag.findings[5].targetSourceIndex)
        XCTAssertEqual(diag.findings[5].capturedSourceIndex, 4)

        // Counts sanity-check.
        let counts = diag.counts
        XCTAssertEqual(counts[.matched] ?? 0, 1)
        XCTAssertEqual(counts[.early]   ?? 0, 1)
        XCTAssertEqual(counts[.late]    ?? 0, 2)
        XCTAssertEqual(counts[.missing] ?? 0, 1)
        XCTAssertEqual(counts[.extra]   ?? 0, 1)
    }

    // MARK: - Inclusive tolerance boundary

    func testInclusiveToleranceBoundary() {
        // Use exact dyadic times so the |offset| == tolerance check
        // is not knocked off by floating-point representation error
        // (e.g. `1.0 + 0.080 - 1.0` is not bit-exactly 0.080 in
        // Double).
        let exactTolerance: TimeInterval = 0.125

        // Captured at exactly target + tolerance must be `.matched`.
        let overlayAtBoundary = makeOverlay(
            targetMovements: [0.5],
            capturedMovements: [0.625]
        )
        let onBoundary = OverlayTimingDiagnostics.compute(
            overlay: overlayAtBoundary,
            toleranceSeconds: exactTolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(onBoundary.findings.first?.kind, .matched,
                       "|offset| == tolerance is inclusive ⇒ matched")
        XCTAssertEqual(onBoundary.findings.first?.offsetSeconds ?? .nan,
                       exactTolerance, accuracy: 1e-12)

        // One ULP-ish past tolerance must classify as `.late`.
        let overlayPastBoundary = makeOverlay(
            targetMovements: [0.5],
            capturedMovements: [0.625 + 1e-6]
        )
        let pastBoundary = OverlayTimingDiagnostics.compute(
            overlay: overlayPastBoundary,
            toleranceSeconds: exactTolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(pastBoundary.findings.first?.kind, .late,
                       "|offset| just past tolerance ⇒ late")

        // Mirror behaviour on the early side.
        let overlayNegativeBoundary = makeOverlay(
            targetMovements: [0.5],
            capturedMovements: [0.375]
        )
        let negativeOnBoundary = OverlayTimingDiagnostics.compute(
            overlay: overlayNegativeBoundary,
            toleranceSeconds: exactTolerance,
            pairingRadiusSeconds: Self.radius
        )
        XCTAssertEqual(negativeOnBoundary.findings.first?.kind, .matched)
        XCTAssertEqual(negativeOnBoundary.findings.first?.offsetSeconds ?? .nan,
                       -exactTolerance, accuracy: 1e-12)
    }

    // MARK: - Deterministic JSON encoding

    func testDeterministicJSONEncoding() throws {
        let overlay = makeOverlay(
            targetMovements: [0.25, 0.50, 0.75],
            capturedMovements: [0.27, 0.60]
        )
        let diag = OverlayTimingDiagnostics.compute(
            overlay: overlay,
            toleranceSeconds: Self.tolerance,
            pairingRadiusSeconds: Self.radius
        )

        let first = try encoder.encode(diag)
        let second = try encoder.encode(diag)
        XCTAssertEqual(first, second,
                       "Same inputs must encode to byte-identical JSON")

        let decoded = try JSONDecoder().decode(OverlayTimingDiagnostics.self, from: first)
        XCTAssertEqual(decoded, diag, "Round-trip preserves equality")
        XCTAssertEqual(decoded.schemaVersion,
                       OverlayTimingDiagnostics.currentSchemaVersion)
    }

    // MARK: - Helpers

    private func makeOverlay(
        targetMovements: [Double],
        capturedMovements: [Double]
    ) -> ReviewOverlayTimeline {
        let span = max(
            (targetMovements.max() ?? 0) + 0.5,
            (capturedMovements.max() ?? 0) + 0.5
        )
        return ReviewOverlayTimeline(
            target: makeTimeline(movements: targetMovements, takeDuration: span),
            captured: makeTimeline(movements: capturedMovements, takeDuration: span)
        )
    }

    private func makeTimeline(
        movements: [Double],
        takeDuration: Double
    ) -> SessionReplayTimeline {
        let snapshot = CaptureCore.DetectedNotationSnapshot(
            notationSource: "detected",
            notationConfidence: nil,
            detectedLabel: nil,
            labelSource: "detected",
            labelConfidence: nil,
            detectionSources: ["movement"],
            recordMovementEvents: movements.enumerated().map { _, time in
                CaptureCore.DetectedNotationRecordMovementEvent(
                    startTime: time,
                    endTime: time + 0.05,
                    startPosition: 0.0,
                    endPosition: 1.0,
                    direction: "forward",
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
