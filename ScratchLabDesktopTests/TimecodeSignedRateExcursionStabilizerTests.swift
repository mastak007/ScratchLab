import XCTest
@testable import ScratchLab

final class TimecodeSignedRateExcursionStabilizerTests: XCTestCase {
    private func makeStabilizer(
        threshold: Double = 0.005,
        maximumGap: TimeInterval = 0.1
    ) -> TimecodeSignedRateExcursionStabilizer {
        TimecodeSignedRateExcursionStabilizer(configuration: .init(
            reversalAreaThreshold: threshold,
            maximumIntegrationGap: maximumGap
        ))
    }

    private func sample(
        _ timestamp: TimeInterval,
        _ signedRate: Double,
        signalState: TimecodeSignedRateSignalState = .available
    ) -> TimecodeSignedRateSample {
        TimecodeSignedRateSample(
            timestamp: timestamp,
            signedRate: signedRate,
            signalState: signalState
        )
    }

    private func establishForward(
        _ stabilizer: inout TimecodeSignedRateExcursionStabilizer,
        at timestamp: TimeInterval = 0
    ) {
        XCTAssertEqual(stabilizer.consume(sample(timestamp, 1)), .noChange)
        XCTAssertEqual(stabilizer.committedDirection, .forward)
    }

    func testIsolatedNearZeroSignChatterDoesNotCommitReversal() {
        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)

        let rates: [Double] = [-0.1, 0.1, -0.08, 0.06, -0.09, 0.1]
        for (index, rate) in rates.enumerated() {
            XCTAssertEqual(
                stabilizer.consume(sample(Double(index + 1) * 0.001, rate)),
                .noChange
            )
        }

        XCTAssertEqual(stabilizer.committedDirection, .forward)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0, accuracy: 1e-12)
    }

    func testSustainedOppositeExcursionEmitsExactlyOneReversal() {
        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)

        XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
        let result = stabilizer.consume(sample(0.006, -1))
        XCTAssertEqual(
            result,
            .reversal(.init(
                timestamp: 0.006,
                previousDirection: .forward,
                direction: .backward
            ))
        )

        XCTAssertEqual(stabilizer.consume(sample(0.010, -1)), .noChange)
        XCTAssertEqual(stabilizer.consume(sample(0.020, -1)), .noChange)
        XCTAssertEqual(stabilizer.committedDirection, .backward)
    }

    func testSubThresholdExcursionReturningToCommittedDirectionIsCancelled() {
        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)

        XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
        XCTAssertEqual(stabilizer.consume(sample(0.004, -1)), .noChange)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0.003, accuracy: 1e-12)
        XCTAssertEqual(stabilizer.consume(sample(0.005, 1)), .noChange)

        XCTAssertEqual(stabilizer.committedDirection, .forward)
        XCTAssertEqual(stabilizer.pendingDirection, .unknown)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0, accuracy: 1e-12)
    }

    func testCommittedDirectionSamplesDoNotDuplicateEvents() {
        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)

        for timestamp in [0.001, 0.004, 0.008, 0.012] {
            XCTAssertEqual(stabilizer.consume(sample(timestamp, 0.75)), .noChange)
        }
        XCTAssertEqual(stabilizer.committedDirection, .forward)
    }

    func testTwoRapidLegitimateExcursionsCanCommitTwoReversals() {
        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)

        XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
        guard case .reversal(let first) = stabilizer.consume(sample(0.006, -1)) else {
            return XCTFail("Expected forward-to-backward reversal")
        }
        XCTAssertEqual(first.direction, .backward)

        XCTAssertEqual(stabilizer.consume(sample(0.007, 1)), .noChange)
        guard case .reversal(let second) = stabilizer.consume(sample(0.012, 1)) else {
            return XCTFail("Expected backward-to-forward reversal")
        }
        XCTAssertEqual(second.previousDirection, .backward)
        XCTAssertEqual(second.direction, .forward)
    }

    func testIrregularIntervalsUseActualElapsedTime() {
        var stabilizer = makeStabilizer(threshold: 0.006)
        establishForward(&stabilizer)

        XCTAssertEqual(stabilizer.consume(sample(0.001, -0.5)), .noChange)
        XCTAssertEqual(stabilizer.consume(sample(0.003, -1.5)), .noChange)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0.002, accuracy: 1e-12)
        XCTAssertEqual(stabilizer.consume(sample(0.005, -0.5)), .noChange)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0.004, accuracy: 1e-12)
        XCTAssertEqual(
            stabilizer.consume(sample(0.009, -0.5)),
            .reversal(.init(
                timestamp: 0.009,
                previousDirection: .forward,
                direction: .backward
            ))
        )
    }

    func testLargeTimestampGapCannotManufactureThresholdCrossing() {
        var stabilizer = makeStabilizer(maximumGap: 0.01)
        establishForward(&stabilizer)

        XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
        XCTAssertEqual(stabilizer.consume(sample(1.0, -1)), .integrationGap)
        XCTAssertEqual(stabilizer.committedDirection, .forward)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0, accuracy: 1e-12)

        XCTAssertEqual(stabilizer.consume(sample(1.004, -1)), .noChange)
        XCTAssertEqual(stabilizer.pendingIntegratedArea, 0.004, accuracy: 1e-12)
    }

    func testUnavailableSignalStatesResetPendingEvidenceWithoutFabricatingDirection() {
        for unavailableState in [
            TimecodeSignedRateSignalState.noSignal,
            .unknown
        ] {
            var stabilizer = makeStabilizer()
            establishForward(&stabilizer)

            XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
            XCTAssertEqual(stabilizer.consume(sample(0.004, -1)), .noChange)
            XCTAssertEqual(
                stabilizer.consume(sample(0.005, 0, signalState: unavailableState)),
                .signalUnavailable
            )
            XCTAssertEqual(stabilizer.reportedDirection, .unknown)
            XCTAssertEqual(stabilizer.committedDirection, .forward)
            XCTAssertEqual(stabilizer.pendingIntegratedArea, 0, accuracy: 1e-12)

            XCTAssertEqual(stabilizer.consume(sample(0.020, -1)), .noChange)
            XCTAssertEqual(stabilizer.consume(sample(0.024, -1)), .noChange)
            XCTAssertEqual(stabilizer.committedDirection, .forward)
        }
    }

    func testNonFiniteAndNonMonotonicInputsFailClosed() {
        for invalidSample in [
            sample(-0.001, -1),
            sample(.nan, -1),
            sample(.infinity, -1),
            sample(0.002, .nan),
            sample(0.002, .infinity)
        ] {
            var stabilizer = makeStabilizer()
            establishForward(&stabilizer)
            XCTAssertEqual(stabilizer.consume(sample(0.001, -1)), .noChange)
            XCTAssertEqual(stabilizer.consume(invalidSample), .invalidSample)
            XCTAssertEqual(stabilizer.committedDirection, .forward)
            XCTAssertEqual(stabilizer.reportedDirection, .unknown)
            XCTAssertEqual(stabilizer.pendingIntegratedArea, 0, accuracy: 1e-12)
        }

        var stabilizer = makeStabilizer()
        establishForward(&stabilizer)
        XCTAssertEqual(stabilizer.consume(sample(0.010, -1)), .noChange)
        XCTAssertEqual(
            stabilizer.consume(sample(0.009, -1)),
            .nonMonotonicTimestamp
        )
        XCTAssertEqual(stabilizer.committedDirection, .forward)
        XCTAssertEqual(stabilizer.pendingDirection, .unknown)
    }

    func testThresholdBoundaryBelowExactlyAtAndAbove() {
        let threshold = 0.5

        var below = makeStabilizer(threshold: threshold, maximumGap: 2)
        establishForward(&below)
        XCTAssertEqual(below.consume(sample(0.5, -threshold.nextDown)), .noChange)
        XCTAssertEqual(below.consume(sample(1.5, -threshold.nextDown)), .noChange)
        XCTAssertEqual(below.committedDirection, .forward)

        var exact = makeStabilizer(threshold: threshold, maximumGap: 2)
        establishForward(&exact)
        XCTAssertEqual(exact.consume(sample(0.5, -threshold)), .noChange)
        guard case .reversal = exact.consume(sample(1.5, -threshold)) else {
            return XCTFail("Exactly-at-threshold area must commit")
        }

        var above = makeStabilizer(threshold: threshold, maximumGap: 2)
        establishForward(&above)
        XCTAssertEqual(above.consume(sample(0.5, -threshold.nextUp)), .noChange)
        guard case .reversal = above.consume(sample(1.5, -threshold.nextUp)) else {
            return XCTFail("Above-threshold area must commit")
        }
    }
}
