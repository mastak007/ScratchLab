import XCTest
@testable import ScratchLab

final class ClickPlacementTests: XCTestCase {

    func testInvalidFractionsAreRejected() {
        let invalidValues: [Double] = [
            .nan,
            .infinity,
            -0.1,
            1.1
        ]

        for value in invalidValues {
            XCTAssertNil(
                ClickPlacement(fraction: value, role: .custom, feel: .even),
                "Expected \(value) to be rejected"
            )
        }
    }

    func testValidFractionsAreAccepted() {
        let validValues = [0.0, 0.25, 0.5, 0.75, 1.0]

        for value in validValues {
            XCTAssertNotNil(
                ClickPlacement(fraction: value, role: .custom, feel: .even),
                "Expected \(value) to be accepted"
            )
        }
    }

    func testPlacementPreservesFractionRoleAndFeel() {
        let placement = ClickPlacement(fraction: 0.25, role: .low, feel: .triplet)

        XCTAssertEqual(placement?.fraction, 0.25)
        XCTAssertEqual(placement?.role, .low)
        XCTAssertEqual(placement?.feel, .triplet)
    }

    func testClickGroupOrderingIsPreservedAndEqualityRespectsOrder() {
        let low = ClickPlacement(fraction: 0.25, role: .low, feel: .even)!
        let middle = ClickPlacement(fraction: 0.5, role: .middle, feel: .even)!
        let high = ClickPlacement(fraction: 0.75, role: .high, feel: .even)!

        let authored = ClickGroup(half: .forward, placements: [high, low, middle])
        let reordered = ClickGroup(half: .forward, placements: [low, middle, high])

        XCTAssertEqual(authored.placements, [high, low, middle])
        XCTAssertEqual(authored.placements.map(\.fraction), [0.75, 0.25, 0.5])
        XCTAssertNotEqual(authored, reordered)
    }

    func testForwardOnlyPattern() {
        let middle = ClickPlacement(fraction: 0.5, role: .middle, feel: .even)!
        let pattern = StrokeHalfPattern.forwardOnly([middle])

        XCTAssertEqual(pattern.forward?.half, .forward)
        XCTAssertNil(pattern.backward)
        XCTAssertEqual(pattern.forwardClickCount, 1)
        XCTAssertEqual(pattern.backwardClickCount, 0)
        XCTAssertEqual(pattern.totalClickCount, 1)
        XCTAssertTrue(pattern.isForwardOnly)
        XCTAssertFalse(pattern.isSymmetricOrbit)
    }

    func testSymmetricForwardBackwardOrbitPattern() {
        let low = ClickPlacement(fraction: 0.25, role: .low, feel: .even)!
        let high = ClickPlacement(fraction: 0.75, role: .high, feel: .even)!
        let pattern = StrokeHalfPattern.orbit(
            forward: [low, high],
            backward: [high, low]
        )

        XCTAssertEqual(pattern.forward?.half, .forward)
        XCTAssertEqual(pattern.backward?.half, .backward)
        XCTAssertEqual(pattern.forwardClickCount, 2)
        XCTAssertEqual(pattern.backwardClickCount, 2)
        XCTAssertEqual(pattern.totalClickCount, 4)
        XCTAssertFalse(pattern.isForwardOnly)
        XCTAssertTrue(pattern.isSymmetricOrbit)
    }

    func testAsymmetricNMPattern() {
        let low = ClickPlacement(fraction: 0.25, role: .low, feel: .even)!
        let middle = ClickPlacement(fraction: 0.5, role: .middle, feel: .even)!
        let high = ClickPlacement(fraction: 0.75, role: .high, feel: .even)!
        let pattern = StrokeHalfPattern.orbit(
            forward: [low, middle, high],
            backward: [high, low]
        )

        XCTAssertEqual(pattern.forwardClickCount, 3)
        XCTAssertEqual(pattern.backwardClickCount, 2)
        XCTAssertEqual(pattern.totalClickCount, 5)
        XCTAssertFalse(pattern.isForwardOnly)
        XCTAssertFalse(pattern.isSymmetricOrbit)
    }

    func testCodableRoundTripForPattern() throws {
        let low = ClickPlacement(fraction: 0.25, role: .low, feel: .burst)!
        let high = ClickPlacement(fraction: 0.75, role: .high, feel: .triplet)!
        let pattern = StrokeHalfPattern.orbit(
            forward: [low, high],
            backward: [high, low]
        )

        let data = try JSONEncoder().encode(pattern)
        let decoded = try JSONDecoder().decode(StrokeHalfPattern.self, from: data)

        XCTAssertEqual(decoded, pattern)
    }

    func testClickPlacementHasNoScratchSampleTimelineDependency() throws {
        let source = try String(
            contentsOfFile: "ScratchLab/Models/Notation/Grammar/ClickPlacement.swift",
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("ScratchSampleTimeline"))
    }
}
