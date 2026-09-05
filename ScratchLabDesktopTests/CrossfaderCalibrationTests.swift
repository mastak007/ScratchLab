// CrossfaderCalibrationTests.swift
// ScratchLabDesktopTests
//
// Pure-model tests for crossfader calibration, calibrated normalization,
// hysteresis-based state derivation and semantic event naming.
// No CoreMIDI, no MacCaptureEngine, no audio.
//
// The numbers in `RaneRightDeck` come from the 2026-09-04 exported baby-scratch
// session, which is the take that exposed the defect: 826 crossfader samples on
// channel 16 / CC8, observed raw range 0…52, and 12 of 20 derived fader events
// unclassifiable because normalization assumed the fader spanned 0…127. Only
// the measured PARAMETERS are reproduced here — no capture audio, video or
// personal data enters the repository.

import XCTest
@testable import ScratchLab

/// Test-side driver for the armed sweep: arms the current stage, then feeds
/// monotonically-sequenced observations. Mirrors what the operator does —
/// press Capture, then present the position.
private extension CrossfaderCalibrationSweep {
    func armed(at sequence: Int) -> CrossfaderCalibrationSweep {
        arming(atObservationSequence: sequence)
    }

    func fed(
        _ value: Int,
        count: Int,
        from sequence: inout Int,
        now: Date = Date(timeIntervalSince1970: 1_788_000_000)
    ) -> CrossfaderCalibrationSweep {
        var next = self
        for _ in 0..<count {
            sequence += 1
            next = next.ingesting(rawValue: value, observationSequence: sequence, now: now)
        }
        return next
    }

    /// Arm the current stage and hold `value` for `count` fresh observations.
    func capturing(
        _ value: Int,
        count: Int,
        from sequence: inout Int,
        now: Date = Date(timeIntervalSince1970: 1_788_000_000)
    ) -> CrossfaderCalibrationSweep {
        armed(at: sequence).fed(value, count: count, from: &sequence, now: now)
    }
}

final class CrossfaderCalibrationTests: XCTestCase {

    // MARK: - Fixtures

    /// A right-deck crossfader whose audible half runs centre (raw 52) to far
    /// left (raw 0) — the geometry of the take that prompted this work.
    private enum RaneRightDeck {
        static let address = CrossfaderMIDIAddress(
            deviceIdentifier: "Rane ONE MKII",
            deviceName: "Rane ONE MKII",
            channel: 15,
            controller: 8
        )

        static let calibration = CrossfaderCalibration(
            address: address,
            fullLeftRawValue: 0,
            centerRawValue: 52,
            fullRightRawValue: 104,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    /// A conventional left-deck fader: closed at centre 64, open at far right.
    private enum ConventionalLeftOpenRight {
        static let address = CrossfaderMIDIAddress(
            deviceIdentifier: "Generic Mixer",
            deviceName: "Generic Mixer",
            channel: 0,
            controller: 7
        )

        static let calibration = CrossfaderCalibration(
            address: address,
            fullLeftRawValue: 0,
            centerRawValue: 64,
            fullRightRawValue: 127,
            openEnd: .right,
            activeDeck: .leftDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
    }

    // MARK: - Mapping and orientation

    func testOpenEndLeftPutsTheOpenEndAtTheLeftEndStop() {
        let calibration = RaneRightDeck.calibration
        XCTAssertEqual(calibration.openRawValue, 0)
        XCTAssertEqual(calibration.closedRawValue, 52)
        XCTAssertEqual(calibration.beyondClosedRawValue, 104)
    }

    func testOpenEndRightPutsTheOpenEndAtTheRightEndStop() {
        let calibration = ConventionalLeftOpenRight.calibration
        XCTAssertEqual(calibration.openRawValue, 127)
        XCTAssertEqual(calibration.closedRawValue, 64)
        XCTAssertEqual(calibration.beyondClosedRawValue, 0)
    }

    func testNormalizationRunsClosedToOpenRegardlessOfOrientation() {
        // Descending active half (open at the LOW raw end).
        let descending = RaneRightDeck.calibration
        XCTAssertEqual(descending.normalized(rawValue: 52), 0.0)
        XCTAssertEqual(descending.normalized(rawValue: 0), 1.0)
        XCTAssertEqual(descending.normalized(rawValue: 26) ?? -1, 0.5, accuracy: 0.0001)

        // Ascending active half (open at the HIGH raw end).
        let ascending = ConventionalLeftOpenRight.calibration
        XCTAssertEqual(ascending.normalized(rawValue: 64), 0.0)
        XCTAssertEqual(ascending.normalized(rawValue: 127), 1.0)
        // Direction, not just magnitude: moving right must open the deck.
        let quarter = ascending.normalized(rawValue: 80) ?? -1
        XCTAssertGreaterThan(quarter, 0)
        XCTAssertLessThan(quarter, 1)
    }

    func testTravelPastTheClosedEndClampsToClosedRatherThanReversing() {
        // Raw 104 is the far RIGHT stop, past the centre detent. For the right
        // deck that region is still silent — it must read 0, never a negative
        // or wrapped position.
        XCTAssertEqual(RaneRightDeck.calibration.normalized(rawValue: 104), 0.0)
        XCTAssertEqual(RaneRightDeck.calibration.normalized(rawValue: 127), 0.0)
    }

    // MARK: - Half-range controllers (the actual defect)

    func testHalfRangeFaderReachesFullyOpenUnderCalibration() {
        // This is the regression. Raw 0 is a fully open right deck. The old
        // `raw / 127` normalization reported it as 0.0, and raw 52 — fully
        // CLOSED — as 0.41, so a complete cut measured as a 0.41 excursion and
        // fell under the cut gate. Calibrated, the same gesture spans 0 -> 1.
        let calibration = RaneRightDeck.calibration
        XCTAssertEqual(calibration.normalized(rawValue: 0), 1.0)
        XCTAssertEqual(calibration.normalized(rawValue: 52), 0.0)

        let uncalibrated = Double(52) / 127.0
        XCTAssertLessThan(uncalibrated, 0.42, "The take that prompted this never exceeded ~0.41 uncalibrated.")

        let calibratedSpan = abs(
            (calibration.normalized(rawValue: 0) ?? 0) - (calibration.normalized(rawValue: 52) ?? 0)
        )
        XCTAssertEqual(calibratedSpan, 1.0, accuracy: 0.0001)
    }

    func testActiveHalfBoundsCoverOnlyTheCalibratedDecksTravel() {
        let bounds = RaneRightDeck.calibration.activeHalfRawBounds
        XCTAssertEqual(bounds.lowerBound, 0)
        XCTAssertEqual(bounds.upperBound, 52)
        XCTAssertTrue(RaneRightDeck.calibration.isWithinActiveHalf(rawValue: 30))
        XCTAssertFalse(RaneRightDeck.calibration.isWithinActiveHalf(rawValue: 90))
    }

    // MARK: - Calibration validation

    func testEndStopsThatDoNotDifferAreRejected() {
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 64,
            centerRawValue: 64,
            fullRightRawValue: 64,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date()
        )
        XCTAssertFalse(calibration.isUsable)
        XCTAssertTrue(
            calibration.validationIssues().contains(.endpointsNotDistinct(left: 64, right: 64))
        )
        XCTAssertNil(calibration.normalized(rawValue: 64))
    }

    func testCenterOutsideTheEndStopsIsRejected() {
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 10,
            centerRawValue: 5,
            fullRightRawValue: 100,
            openEnd: .right,
            activeDeck: .leftDeck,
            calibratedAt: Date()
        )
        XCTAssertTrue(
            calibration.validationIssues()
                .contains(.centerOutsideEndpoints(center: 5, left: 10, right: 100))
        )
    }

    func testTooNarrowAnActiveHalfIsRejected() {
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 8,
            fullRightRawValue: 127,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date()
        )
        XCTAssertFalse(calibration.isUsable)
        XCTAssertTrue(
            calibration.validationIssues().contains(
                .activeHalfTooNarrow(
                    span: 8,
                    minimumSpan: CrossfaderCalibration.minimumActiveHalfSpan
                )
            )
        )
    }

    func testAFutureSchemaVersionIsRejectedRatherThanReinterpreted() {
        let calibration = CrossfaderCalibration(
            schemaVersion: CrossfaderCalibration.currentSchemaVersion + 1,
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 52,
            fullRightRawValue: 104,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date()
        )
        XCTAssertFalse(calibration.isUsable)
        XCTAssertNil(calibration.normalized(rawValue: 26))
    }

    func testACalibrationIsOnlyValidForItsOwnAddress() {
        let address = RaneRightDeck.calibration.address
        XCTAssertTrue(address.matches(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8))
        XCTAssertFalse(address.matches(deviceIdentifier: "Rane ONE MKII", channel: 1, controller: 6))
        XCTAssertFalse(address.matches(deviceIdentifier: "Other Device", channel: 15, controller: 8))
    }

    func testUserFacingChannelIsOneBased() {
        // The audit reported "channel 16, CC8"; the byte stream carries 15.
        XCTAssertEqual(RaneRightDeck.address.userFacingChannel, 16)
    }

    // MARK: - Calibration sweep

    func testSweepRequiresAHeldPositionBeforeAcceptingIt() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 4,
            settleTolerance: 1,
            // These cases exercise the SETTLE rule. Scale the liveness
            // threshold down to match, so a stability assertion never fails
            // for a liveness reason; liveness has its own cases below.
            minimumFreshObservations: 1
        )
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)
        var sequence = 0

        // Three samples is not enough.
        sweep = sweep.capturing(0, count: 3, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)

        sweep = sweep.fed(0, count: 1, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
    }

    func testSweepRestartsTheHoldWhenTheValueMovesOutOfTolerance() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 4,
            settleTolerance: 1,
            // These cases exercise the SETTLE rule. Scale the liveness
            // threshold down to match, so a stability assertion never fails
            // for a liveness reason; liveness has its own cases below.
            minimumFreshObservations: 1
        )
        var sequence = 0
        sweep = sweep.capturing(0, count: 3, from: &sequence)
        // Bounce off the end stop.
        sweep = sweep.fed(9, count: 1, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)
        sweep = sweep.fed(9, count: 3, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
        XCTAssertEqual(sweep.capturedValues[.fullLeft], 9, "The settled value wins, not the first sample.")
    }

    func testCompletedSweepProducesAUsableCalibration() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 2,
            settleTolerance: 0,
            minimumFreshObservations: 1
        )
        var sequence = 0
        for value in [0, 52, 104] {
            sweep = sweep.capturing(value, count: 2, from: &sequence)
        }
        guard let calibration = sweep.state.calibration else {
            return XCTFail("Sweep did not complete after all three positions settled.")
        }
        XCTAssertTrue(calibration.isUsable)
        XCTAssertEqual(calibration.normalized(rawValue: 0), 1.0)
        XCTAssertEqual(calibration.normalized(rawValue: 52), 0.0)
    }

    func testSweepIgnoresOutOfRangeMIDIValues() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 2,
            settleTolerance: 0,
            minimumFreshObservations: 1
        )
        var sequence = 0
        sweep = sweep.armed(at: sequence)
        sweep = sweep.fed(200, count: 1, from: &sequence)
        sweep = sweep.fed(-4, count: 1, from: &sequence)
        XCTAssertEqual(sweep.settleProgress, 0)
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)
    }

    // MARK: - Persistence

    private func makeTemporaryStore() throws -> CrossfaderCalibrationStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossfaderCalibrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CrossfaderCalibrationStore(directoryURL: directory)
    }

    func testCalibrationRoundTripsThroughTheStore() throws {
        let store = try makeTemporaryStore()
        try store.save(RaneRightDeck.calibration)

        let loaded = store.calibration(
            deviceIdentifier: "Rane ONE MKII",
            channel: 15,
            controller: 8
        )
        XCTAssertEqual(loaded, RaneRightDeck.calibration)
        XCTAssertEqual(loaded?.normalized(rawValue: 0), 1.0)
    }

    func testSavingTheSameAddressReplacesRatherThanDuplicates() throws {
        let store = try makeTemporaryStore()
        try store.save(RaneRightDeck.calibration)

        let updated = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 60,
            fullRightRawValue: 120,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_100_000)
        )
        let document = try store.save(updated)
        XCTAssertEqual(document.calibrations.count, 1)
        XCTAssertEqual(document.calibrations.first?.centerRawValue, 60)
    }

    func testTwoControllersKeepIndependentCalibrations() throws {
        let store = try makeTemporaryStore()
        try store.save(RaneRightDeck.calibration)
        try store.save(ConventionalLeftOpenRight.calibration)

        XCTAssertEqual(store.load().calibrations.count, 2)
        XCTAssertEqual(
            store.calibration(deviceIdentifier: "Generic Mixer", channel: 0, controller: 7)?.openRawValue,
            127
        )
        XCTAssertEqual(
            store.calibration(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8)?.openRawValue,
            0
        )
    }

    func testAnUnusableCalibrationIsRefusedAtSaveTime() throws {
        let store = try makeTemporaryStore()
        let broken = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 64,
            centerRawValue: 64,
            fullRightRawValue: 64,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date()
        )
        XCTAssertThrowsError(try store.save(broken))
        XCTAssertTrue(store.load().calibrations.isEmpty)
    }

    func testACorruptStoreFileLoadsEmptyRatherThanThrowing() throws {
        let store = try makeTemporaryStore()
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().calibrations.isEmpty)
        // And it must still be possible to calibrate again.
        XCTAssertNoThrow(try store.save(RaneRightDeck.calibration))
    }

    func testRemovingACalibrationLeavesTheOthers() throws {
        let store = try makeTemporaryStore()
        try store.save(RaneRightDeck.calibration)
        try store.save(ConventionalLeftOpenRight.calibration)
        try store.remove(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8)

        XCTAssertNil(store.calibration(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8))
        XCTAssertNotNil(store.calibration(deviceIdentifier: "Generic Mixer", channel: 0, controller: 7))
    }

    // MARK: - Hysteresis and jitter

    private func samples(
        _ pairs: [(Double, Int)],
        calibration: CrossfaderCalibration
    ) -> [CrossfaderPositionSample] {
        pairs.map { time, raw in
            CrossfaderPositionSample(
                takeRelativeTime: time,
                rawValue: raw,
                normalizedPosition: calibration.normalized(rawValue: raw) ?? 0
            )
        }
    }

    func testOverlappingHysteresisBandsAreRefused() {
        let bad = CrossfaderHysteresis(
            closedAtOrBelow: 0.7,
            openAtOrAbove: 0.3,
            minimumDwellSeconds: 0.01
        )
        XCTAssertFalse(bad.isUsable)
        XCTAssertNil(CrossfaderStateDeriver.stateIntervals(samples: [], hysteresis: bad))
    }

    func testJitterAtTheClosedThresholdDoesNotMintACut() {
        let calibration = RaneRightDeck.calibration
        // Sitting open, with single-sample dips across the closed threshold —
        // exactly what a controller does at ~800 Hz near a boundary.
        var pairs: [(Double, Int)] = []
        var time = 0.0
        for index in 0..<200 {
            // raw 0 == fully open; a lone excursion to raw 50 (nearly closed).
            let raw = index % 37 == 0 ? 50 : 2
            pairs.append((time, raw))
            time += 0.001
        }
        let stream = samples(pairs, calibration: calibration)
        let intervals = CrossfaderStateDeriver.stateIntervals(
            samples: stream,
            hysteresis: .default
        )
        let events = CrossfaderStateDeriver.semanticEvents(intervals: intervals ?? [])
        XCTAssertTrue(
            events.allSatisfy { $0.kind != .cut },
            "1 ms jitter spikes must not be reported as deliberate cuts."
        )
    }

    func testARealCutSurvivesTheJitterFilter() {
        let calibration = RaneRightDeck.calibration
        var pairs: [(Double, Int)] = []
        var time = 0.0
        // 60 ms fully open.
        for _ in 0..<60 { pairs.append((time, 2)); time += 0.001 }
        // 20 ms transit.
        for step in 0..<20 { pairs.append((time, 2 + step * 2)); time += 0.001 }
        // 60 ms fully closed — well past the 8 ms dwell.
        for _ in 0..<60 { pairs.append((time, 52)); time += 0.001 }

        let stream = samples(pairs, calibration: calibration)
        guard let intervals = CrossfaderStateDeriver.stateIntervals(
            samples: stream,
            hysteresis: .default
        ) else {
            return XCTFail("Derivation refused a usable calibration and hysteresis.")
        }
        let events = CrossfaderStateDeriver.semanticEvents(intervals: intervals)
        XCTAssertEqual(events.filter { $0.kind == .cut }.count, 1)
        XCTAssertEqual(events.filter(\.kind.isUnknown).count, 0)
    }

    func testASlowReturnToOpenIsNamedOpeningNotUnknown() {
        // The 2026-09-04 take's `unknown` events were mostly slow, deliberate
        // returns to open — 2.4 s of travel classified as "unknown" because
        // the only vocabulary was cut-or-nothing.
        let calibration = RaneRightDeck.calibration
        var pairs: [(Double, Int)] = []
        var time = 0.0
        // 2.4 s of travel, matching the slow return measured in that take
        // (2.0105 s -> 4.4302 s). Only the part of the sweep inside the dead
        // band counts as the transition, so the sweep has to be genuinely slow
        // to exceed `defaultMaximumCutDuration`; a 0.5 s sweep crosses the band
        // in ~0.25 s and is correctly a release, not an `opening`.
        for _ in 0..<50 { pairs.append((time, 52)); time += 0.001 }     // closed
        for step in 0..<2_400 {                                         // 2.4 s open sweep
            pairs.append((time, max(0, 52 - (step * 52 / 2_400))))
            time += 0.001
        }
        for _ in 0..<50 { pairs.append((time, 0)); time += 0.001 }      // open

        let stream = samples(pairs, calibration: calibration)
        guard let intervals = CrossfaderStateDeriver.stateIntervals(
            samples: stream,
            hysteresis: .default
        ) else {
            return XCTFail("Derivation refused a usable calibration and hysteresis.")
        }
        let events = CrossfaderStateDeriver.semanticEvents(intervals: intervals)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .opening)
        XCTAssertEqual(
            CrossfaderDerivation(intervals: intervals, events: events).unknownEventRatio,
            0
        )
    }

    func testThreeAlternatingCutsCollapseIntoATransformPulse() {
        let calibration = RaneRightDeck.calibration
        var pairs: [(Double, Int)] = []
        var time = 0.0
        func hold(_ raw: Int, milliseconds: Int) {
            for _ in 0..<milliseconds { pairs.append((time, raw)); time += 0.001 }
        }
        func transit(from: Int, to: Int, milliseconds: Int) {
            for step in 0..<milliseconds {
                pairs.append((time, from + (to - from) * step / milliseconds))
                time += 0.001
            }
        }
        hold(2, milliseconds: 40)
        for _ in 0..<2 {
            transit(from: 2, to: 52, milliseconds: 15)
            hold(52, milliseconds: 30)
            transit(from: 52, to: 2, milliseconds: 15)
            hold(2, milliseconds: 30)
        }

        let stream = samples(pairs, calibration: calibration)
        guard let intervals = CrossfaderStateDeriver.stateIntervals(
            samples: stream,
            hysteresis: .default
        ) else {
            return XCTFail("Derivation refused a usable calibration and hysteresis.")
        }
        let events = CrossfaderStateDeriver.semanticEvents(intervals: intervals)
        XCTAssertTrue(
            events.contains { $0.kind == .transformPulse },
            "Four alternating cuts inside the pulse gap should read as a transform figure, got \(events.map(\.kind))"
        )
    }

    func testDerivationRefusesToRunWithoutAUsableCalibration() {
        let broken = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 64,
            centerRawValue: 64,
            fullRightRawValue: 64,
            openEnd: .left,
            activeDeck: .rightDeck,
            calibratedAt: Date()
        )
        XCTAssertNil(
            CrossfaderStateDeriver.derive(
                rawEvents: [(0.0, 10), (0.1, 40)],
                calibration: broken
            ),
            "An unusable calibration must yield no derivation, never a raw/127 fallback."
        )
    }

    func testAFaderParkedOpenProducesNoEventsAndStaysOpen() {
        let calibration = RaneRightDeck.calibration
        let pairs = (0..<300).map { index in (Double(index) * 0.001, 1) }
        guard let derivation = CrossfaderStateDeriver.derive(
            rawEvents: pairs.map { ($0.0, $0.1) },
            calibration: calibration
        ) else {
            return XCTFail("Derivation refused a usable calibration.")
        }
        XCTAssertTrue(derivation.stayedOpenThroughout)
        XCTAssertTrue(derivation.events.isEmpty)
        XCTAssertEqual(derivation.unknownEventRatio, 0, "An empty event list is missing evidence, not bad quality.")
    }

    // MARK: - 2026-09-04 hardware-smoke regressions
    //
    // The physical smoke committed a calibration of full-left 0, centre 0,
    // full-right 126 without the operator being able to say the fader had
    // moved for every position. Two independent defects allowed it, and each
    // has its own case below.

    /// DEFECT 1 — liveness. The host polls a "latest value" cache every 20 ms,
    /// so a silent controller re-reads the SAME message forever. The settle
    /// counter alone cannot tell that apart from a held fader, and settled
    /// every position instantly.
    func testStaleObservationsAloneCannotSettleACalibrationStep() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 4,
            settleTolerance: 1,
            minimumFreshObservations: 3
        )
        // Far more samples than the settle rule needs, but every one of them
        // repeats the SAME message the arm boundary already saw.
        sweep = sweep.armed(at: 7)
        for _ in 0..<50 {
            sweep = sweep.ingesting(rawValue: 0, observationSequence: 7, now: Date())
        }
        XCTAssertEqual(
            sweep.state.currentStep,
            .fullLeft,
            "A stale value re-read on a timer must never settle a position."
        )
        XCTAssertNil(sweep.capturedValues[.fullLeft])
    }

    func testFreshObservationsSettleAStepOnceBothGatesAreMet() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 4,
            settleTolerance: 1,
            minimumFreshObservations: 3
        )
        var sequence = 0
        sweep = sweep.capturing(0, count: 4, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
        XCTAssertEqual(sweep.capturedValues[.fullLeft], 0)
    }

    func testEachStepRequiresItsOwnFreshObservations() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 2,
            settleTolerance: 0,
            minimumFreshObservations: 2
        )
        var sequence = 0
        sweep = sweep.capturing(0, count: 2, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
        // Centre is UNARMED, so nothing at all reaches it — not even fresh
        // messages — until the operator presses its Capture button.
        for _ in 0..<20 {
            sequence += 1
            sweep = sweep.ingesting(rawValue: 0, observationSequence: sequence, now: Date())
        }
        XCTAssertEqual(sweep.state.currentStep, .center)
        XCTAssertNil(sweep.capturedValues[.center])
    }

    func testRetryingAStepDiscardsTheFreshObservationsThatPaidForTheRejectedHold() {
        var sweep = CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .left,
            activeDeck: .rightDeck,
            settleSampleCount: 2,
            settleTolerance: 0,
            minimumFreshObservations: 2
        )
        var sequence = 0
        sweep = sweep.capturing(0, count: 1, from: &sequence)
        sweep = sweep.retryingCurrentStep()
        XCTAssertEqual(sweep.freshObservationCount, 0)
        XCTAssertTrue(sweep.state.isAwaitingArm, "a retry returns the stage to its instruction")
        // Re-arm, then one fresh message is not enough on its own.
        sweep = sweep.capturing(0, count: 1, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)
        sweep = sweep.fed(0, count: 1, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
    }

    /// DEFECT 2 — distinctness. `centerOutsideEndpoints` used an INCLUSIVE
    /// bounds check, so a centre sitting exactly on an end stop passed. The
    /// exact figures the hardware smoke persisted are the fixture.
    func testTheHardwareSmokeCalibrationIsRejected() {
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 0,
            fullRightRawValue: 126,
            openEnd: .right,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_530_991)
        )
        XCTAssertFalse(calibration.isUsable)
        XCTAssertTrue(
            calibration.validationIssues().contains {
                if case .centerNotDistinctFromEndpoints = $0 { return true }
                return false
            },
            calibration.validationIssues().map(\.message).description
        )
        XCTAssertNil(
            calibration.normalized(rawValue: 63),
            "An unusable calibration must normalize to nil, never to a fabricated position."
        )
    }

    func testCentreTouchingEitherEndStopIsRejected() {
        for centre in [0, 1, 125, 126] {
            let calibration = CrossfaderCalibration(
                address: RaneRightDeck.address,
                fullLeftRawValue: 0,
                centerRawValue: centre,
                fullRightRawValue: 126,
                openEnd: .right,
                activeDeck: .rightDeck,
                calibratedAt: Date(timeIntervalSince1970: 1_788_530_991)
            )
            XCTAssertFalse(
                calibration.isUsable,
                "Centre \(centre) is within \(CrossfaderCalibration.minimumCenterMargin) steps of an end stop."
            )
        }
    }

    func testAGenuinelyDistinctCentreIsAccepted() {
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 63,
            fullRightRawValue: 126,
            openEnd: .right,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_530_991)
        )
        XCTAssertTrue(calibration.isUsable, calibration.validationIssues().map(\.message).description)
    }

    /// A store must refuse the persisted 2026-09-04 measurements outright, so
    /// no take can ever be recorded against them.
    func testTheStoreRefusesToSaveANonDistinctCentre() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossfaderCalibrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = CrossfaderCalibrationStore(directoryURL: directory)
        let calibration = CrossfaderCalibration(
            address: RaneRightDeck.address,
            fullLeftRawValue: 0,
            centerRawValue: 0,
            fullRightRawValue: 126,
            openEnd: .right,
            activeDeck: .rightDeck,
            calibratedAt: Date(timeIntervalSince1970: 1_788_530_991)
        )
        XCTAssertThrowsError(try store.save(calibration))
        XCTAssertNil(
            store.calibration(deviceIdentifier: "Rane ONE MKII", channel: 15, controller: 8)
        )
    }

    // MARK: - D4: explicit operator capture boundary
    //
    // On the 2026-09-05 hardware test, pressing Start Calibration immediately
    // began sampling the fader's existing position, so stage 1 could settle
    // before Karl had read the instruction or moved anything.

    private func d4Sweep(
        settle: Int = 4,
        fresh: Int = 2
    ) -> CrossfaderCalibrationSweep {
        CrossfaderCalibrationSweep(
            address: RaneRightDeck.address,
            openEnd: .right,
            activeDeck: .rightDeck,
            settleSampleCount: settle,
            settleTolerance: 1,
            minimumFreshObservations: fresh
        )
    }

    func testANewSweepStartsUnarmedAndCollectsNothing() {
        let sweep = d4Sweep()
        XCTAssertTrue(sweep.state.isAwaitingArm)
        XCTAssertEqual(sweep.state.currentStep, .fullLeft)
        XCTAssertNil(sweep.armBoundarySequence)
        XCTAssertEqual(sweep.settleProgress, 0)
        XCTAssertEqual(sweep.freshObservationProgress, 0)
    }

    func testObservationsWhileUnarmedCannotSettleAStage() {
        var sweep = d4Sweep()
        // A hundred perfectly good, perfectly fresh readings — and the stage
        // has not been armed, so not one of them counts.
        for sequence in 1...100 {
            sweep = sweep.ingesting(rawValue: 0, observationSequence: sequence, now: Date())
        }
        XCTAssertTrue(sweep.state.isAwaitingArm)
        XCTAssertNil(sweep.capturedValues[.fullLeft])
        XCTAssertEqual(sweep.freshObservationCount, 0)
    }

    func testArmingEstablishesAFreshBoundaryAndOnlyLaterObservationsCount() {
        var sweep = d4Sweep().armed(at: 500)
        XCTAssertEqual(sweep.armBoundarySequence, 500)
        // Everything at or before the boundary is pre-arm and rejected.
        for sequence in 400...500 {
            sweep = sweep.ingesting(rawValue: 0, observationSequence: sequence, now: Date())
        }
        XCTAssertEqual(sweep.freshObservationCount, 0)
        XCTAssertNil(sweep.capturedValues[.fullLeft])
        // Post-arm observations do count.
        var sequence = 500
        sweep = sweep.fed(0, count: 4, from: &sequence)
        XCTAssertEqual(sweep.capturedValues[.fullLeft], 0)
    }

    func testCompletingAStageDoesNotAutoArmTheNextOne() {
        var sequence = 0
        var sweep = d4Sweep().capturing(0, count: 4, from: &sequence)
        XCTAssertEqual(sweep.state.currentStep, .center)
        XCTAssertTrue(sweep.state.isAwaitingArm, "centre must wait for its own Capture action")
        XCTAssertNil(sweep.armBoundarySequence)
        // Plenty of fresh centre readings, still unarmed, still nothing taken.
        for _ in 0..<40 {
            sequence += 1
            sweep = sweep.ingesting(rawValue: 63, observationSequence: sequence, now: Date())
        }
        XCTAssertNil(sweep.capturedValues[.center])
    }

    func testEveryStageRequiresItsOwnExplicitCaptureAction() {
        var sequence = 0
        var sweep = d4Sweep()
        sweep = sweep.capturing(0, count: 4, from: &sequence)
        XCTAssertEqual(sweep.capturedValues[.fullLeft], 0)
        sweep = sweep.capturing(63, count: 4, from: &sequence)
        XCTAssertEqual(sweep.capturedValues[.center], 63)
        XCTAssertEqual(sweep.state.currentStep, .fullRight)
        XCTAssertTrue(sweep.state.isAwaitingArm)
        sweep = sweep.capturing(126, count: 4, from: &sequence)
        XCTAssertNotNil(sweep.state.calibration)
    }

    func testRetryClearsTheCurrentStageAndReturnsItToUnarmed() {
        var sequence = 0
        var sweep = d4Sweep().capturing(0, count: 4, from: &sequence)
        sweep = sweep.capturing(63, count: 4, from: &sequence)
        XCTAssertEqual(sweep.capturedValues[.center], 63)

        // Retry the CURRENT stage (full right), which has not been taken yet.
        sweep = sweep.retryingCurrentStep()
        XCTAssertTrue(sweep.state.isAwaitingArm)
        XCTAssertEqual(sweep.state.currentStep, .fullRight)
        XCTAssertNil(sweep.armBoundarySequence)
        XCTAssertEqual(
            sweep.capturedValues[.fullLeft], 0,
            "a retry must leave completed stages untouched"
        )
        XCTAssertEqual(sweep.capturedValues[.center], 63)
    }

    func testSamplesReceivedBeforeARetryCannotLeakIntoIt() {
        var sequence = 0
        var sweep = d4Sweep().capturing(0, count: 4, from: &sequence)
        // Part-way through centre, then retry.
        sweep = sweep.capturing(63, count: 2, from: &sequence)
        let sequenceAtRetry = sequence
        sweep = sweep.retryingCurrentStep()
        // Replay the pre-retry observations: every one is at or before the
        // point the retry happened, and none may count.
        for replay in 1...sequenceAtRetry {
            sweep = sweep.ingesting(rawValue: 63, observationSequence: replay, now: Date())
        }
        XCTAssertTrue(sweep.state.isAwaitingArm)
        XCTAssertEqual(sweep.freshObservationCount, 0)
        XCTAssertNil(sweep.capturedValues[.center])
    }

    func testAnInvalidCentreStillCannotProduceACommittableCalibration() {
        var sequence = 0
        var sweep = d4Sweep()
        // 0 / 0 / 126 — the exact 2026-09-04 shape, now captured through
        // explicit arm actions. The distinctness rule still refuses it.
        for value in [0, 0, 126] {
            sweep = sweep.capturing(value, count: 4, from: &sequence)
        }
        let calibration = try? XCTUnwrap(sweep.state.calibration)
        XCTAssertNotNil(calibration)
        XCTAssertFalse(calibration?.isUsable ?? true)
    }

    func testAValidArmedSweepProducesACommittableCalibration() throws {
        var sequence = 0
        var sweep = d4Sweep()
        for value in [0, 69, 126] {
            sweep = sweep.capturing(value, count: 4, from: &sequence)
        }
        let calibration = try XCTUnwrap(sweep.state.calibration)
        XCTAssertTrue(calibration.isUsable, calibration.validationIssues().map(\.message).description)
        XCTAssertEqual(calibration.fullLeftRawValue, 0)
        XCTAssertEqual(calibration.centerRawValue, 69)
        XCTAssertEqual(calibration.fullRightRawValue, 126)
    }

    /// Both orientations still work through the armed flow.
    func testBothOpenEndOrientationsSurviveTheArmedFlow() throws {
        for openEnd in CrossfaderOpenEnd.allCases {
            var sequence = 0
            var sweep = CrossfaderCalibrationSweep(
                address: RaneRightDeck.address,
                openEnd: openEnd,
                activeDeck: .rightDeck,
                settleSampleCount: 4,
                settleTolerance: 1,
                minimumFreshObservations: 2
            )
            for value in [0, 69, 126] {
                sweep = sweep.capturing(value, count: 4, from: &sequence)
            }
            let calibration = try XCTUnwrap(sweep.state.calibration)
            XCTAssertTrue(calibration.isUsable, "\(openEnd) must still calibrate")
        }
    }

    /// Restarting the whole sweep clears armed state and every measurement.
    func testRestartingTheSweepClearsArmedStateSafely() {
        var sequence = 0
        var sweep = d4Sweep().capturing(0, count: 4, from: &sequence)
        XCTAssertEqual(sweep.capturedValues[.fullLeft], 0)

        let restarted = CrossfaderCalibrationSweep(
            address: sweep.address,
            openEnd: sweep.openEnd,
            activeDeck: sweep.activeDeck,
            settleSampleCount: sweep.settleSampleCount,
            settleTolerance: sweep.settleTolerance,
            minimumFreshObservations: sweep.minimumFreshObservations
        )
        XCTAssertTrue(restarted.state.isAwaitingArm)
        XCTAssertEqual(restarted.state.currentStep, .fullLeft)
        XCTAssertNil(restarted.armBoundarySequence)
        XCTAssertTrue(restarted.capturedValues.isEmpty)
    }

    /// Arming twice cannot widen an already-open window.
    func testArmingAnAlreadyArmedStageIsANoOp() {
        let sweep = d4Sweep().armed(at: 10)
        let again = sweep.arming(atObservationSequence: 999)
        XCTAssertEqual(again.armBoundarySequence, 10)
    }
}
