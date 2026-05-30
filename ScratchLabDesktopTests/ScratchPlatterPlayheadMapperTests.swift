import XCTest
@testable import ScratchLab

/// Scratch Playback Lab — pure platter → sample-position mapping.
/// No AVFoundation, no Core MIDI, no UI, and nothing from the capture/scoring/
/// export pipeline is exercised here. The RANE platter pitch bend is an ABSOLUTE
/// 14-bit angle, so the playhead tracks the wrapped *delta* between successive
/// values, scaled by a small per-tick sensitivity:
///   delta = wrappedDelta(last → raw, 16384) ; position += delta * sampleSecondsPerTick.
final class ScratchPlatterPlayheadMapperTests: XCTestCase {

    // MARK: - Pitch-bend 14-bit decode (via the shared parser the lab consumes)

    func testPitchBendDecodesAs14Bit() {
        let parsed = MIDIMessageParsing.parse([0xE0, 0x32, 0x58])
        XCTAssertEqual(parsed.messageType, .pitchBend)
        XCTAssertEqual(parsed.value, 0x32 | (0x58 << 7)) // 11314
    }

    // MARK: - Wrapped delta (the core of absolute-angle tracking)

    func testWrappedDeltaForwardWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1000, to: 1500), 500)
    }

    func testWrappedDeltaReverseWithoutWrap() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 1500, to: 1000), -500)
    }

    func testWrappedDeltaForwardAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 16300, to: 100), 184)
    }

    func testWrappedDeltaReverseAcrossBoundary() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.wrappedDelta(from: 100, to: 16300), -184)
    }

    // MARK: - Sensitivity scaling

    func testLowerSensitivityProducesSmallerMovement() {
        var hi = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.00001, sampleDuration: 100)
        var lo = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.000001, sampleDuration: 100)
        hi.ingestPitchBend(0); hi.ingestPitchBend(1000)
        lo.ingestPitchBend(0); lo.ingestPitchBend(1000)
        XCTAssertEqual(hi.samplePosition, 1000 * 0.00001, accuracy: 1e-12) // 0.01
        XCTAssertEqual(lo.samplePosition, 1000 * 0.000001, accuracy: 1e-12) // 0.001
        XCTAssertLessThan(lo.samplePosition, hi.samplePosition)
    }

    func testDefaultSensitivityDoesNotTraverseWholeSampleOnOneBigEvent() {
        // The 4,700-tick single event from the hardware video must NOT sweep the
        // whole ~1.047 s sample at default sensitivity.
        var mapper = ScratchPlatterPlayheadMapper(sampleDuration: 1.047)
        mapper.ingestPitchBend(5000)        // seed
        mapper.ingestPitchBend(5000 + 4700) // +4700 ticks
        XCTAssertEqual(mapper.samplePosition, 4700 * 0.00001, accuracy: 1e-9) // 0.047 s
        XCTAssertLessThan(mapper.samplePosition, 0.1)
        XCTAssertFalse(mapper.isAtEnd)
    }

    // MARK: - First event seeds / reset clears seed

    func testFirstEventSeedsLastRawAndDoesNotMove() {
        var mapper = ScratchPlatterPlayheadMapper(sampleDuration: 10.0, samplePosition: 3.0)
        let delta = mapper.ingestPitchBend(12000)
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(mapper.samplePosition, 3.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.lastRawPitchBend, 12000)
    }

    func testResetTrackingMakesNextEventSeedAgain() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.0001, sampleDuration: 100.0)
        mapper.ingestPitchBend(1000)
        mapper.ingestPitchBend(2000) // moves
        let moved = mapper.samplePosition
        mapper.resetTracking()
        XCTAssertNil(mapper.lastRawPitchBend)
        let delta = mapper.ingestPitchBend(9000) // first after reset → seed, no move
        XCTAssertEqual(delta, 0)
        XCTAssertEqual(mapper.samplePosition, moved, accuracy: 1e-12)
    }

    // MARK: - Forward / reverse / invert

    func testForwardAndReverseTracking() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.0001, sampleDuration: 100.0, samplePosition: 0.5)
        mapper.ingestPitchBend(2000)          // seed
        mapper.ingestPitchBend(3000)          // +1000 → +0.1
        XCTAssertEqual(mapper.samplePosition, 0.6, accuracy: 1e-9)
        mapper.ingestPitchBend(2000)          // -1000 → -0.1
        XCTAssertEqual(mapper.samplePosition, 0.5, accuracy: 1e-9)
    }

    func testInvertFlipsTrackingDirection() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.00001, sampleDuration: 100.0,
                                                  inverted: true, samplePosition: 0.5)
        mapper.ingestPitchBend(0)             // seed
        mapper.ingestPitchBend(1000)          // +1000 geometric, inverted → -0.01
        XCTAssertEqual(mapper.samplePosition, 0.49, accuracy: 1e-9)
    }

    // MARK: - Max observed delta + alias risk

    func testMaxObservedDeltaTracksLargestAbsDelta() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.00001, sampleDuration: 100.0)
        mapper.ingestPitchBend(5000)  // seed
        mapper.ingestPitchBend(5500)  // +500
        mapper.ingestPitchBend(2500)  // -3000
        XCTAssertEqual(mapper.maxObservedDelta, 3000)
        mapper.resetMaxObservedDelta()
        XCTAssertEqual(mapper.maxObservedDelta, 0)
    }

    func testAliasWarningThresholdAbove4096() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 4096), .none)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 4097), .warn)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: -5000), .warn)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 8192), .warn)
    }

    func testAliasFailureThresholdAbove8192() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: 8193), .fail)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.aliasRisk(forDelta: -9000), .fail)
    }

    // MARK: - Optional delta safety cap

    func testDeltaSafetyLimitCapsAppliedMovementButKeepsRawDelta() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.0001, sampleDuration: 100.0,
                                                  deltaSafetyLimit: 1000)
        mapper.ingestPitchBend(0)     // seed
        let delta = mapper.ingestPitchBend(8000) // +8000 raw, applied capped to +1000
        XCTAssertEqual(delta, 8000)              // raw delta preserved
        XCTAssertEqual(mapper.lastWrappedDelta, 8000)
        XCTAssertTrue(mapper.lastDeltaClamped)
        XCTAssertEqual(mapper.samplePosition, 1000 * 0.0001, accuracy: 1e-12) // 0.1, not 0.8
    }

    func testNoSafetyLimitDoesNotClamp() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.0001, sampleDuration: 100.0)
        mapper.ingestPitchBend(0)
        mapper.ingestPitchBend(8000)
        XCTAssertFalse(mapper.lastDeltaClamped)
        XCTAssertEqual(mapper.samplePosition, 8000 * 0.0001, accuracy: 1e-12) // 0.8
    }

    // MARK: - Clamp at start / end

    func testClampAtEnd() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.001, sampleDuration: 1.0, samplePosition: 0.9)
        mapper.ingestPitchBend(0)     // seed
        mapper.ingestPitchBend(8000)  // huge forward → clamp to 1.0
        XCTAssertEqual(mapper.samplePosition, 1.0, accuracy: 1e-12)
        XCTAssertTrue(mapper.isAtEnd)
        XCTAssertFalse(mapper.isAtStart)
    }

    func testClampAtStart() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.001, sampleDuration: 1.0, samplePosition: 0.1)
        mapper.ingestPitchBend(8000)  // seed
        mapper.ingestPitchBend(0)     // huge reverse → clamp to 0
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertTrue(mapper.isAtStart)
        XCTAssertFalse(mapper.isAtEnd)
    }

    func testResetPositionReturnsToStart() {
        var mapper = ScratchPlatterPlayheadMapper(sampleDuration: 10.0, samplePosition: 4.0)
        mapper.resetPosition()
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
    }

    func testZeroDurationKeepsPositionAndFractionAtZero() {
        var mapper = ScratchPlatterPlayheadMapper(sampleSecondsPerTick: 0.001, sampleDuration: 0)
        mapper.ingestPitchBend(0)
        mapper.ingestPitchBend(8000)
        XCTAssertEqual(mapper.samplePosition, 0.0, accuracy: 1e-12)
        XCTAssertEqual(mapper.positionFraction, 0.0, accuracy: 1e-12)
    }

    // MARK: - Tick measurement ("rotate one revolution")

    func testTickMeasurementAccumulatesSignedAndAbsoluteTicks() {
        var measurement = PlatterTickMeasurement()
        measurement.record(delta: 500)
        measurement.record(delta: -300)
        measurement.record(delta: 9000)
        XCTAssertEqual(measurement.totalSignedTicks, 9200)
        XCTAssertEqual(measurement.absoluteTickSum, 9800)
    }

    func testTickMeasurementRecordsMaxDeltaEventCountAndAlias() {
        var measurement = PlatterTickMeasurement()
        measurement.record(delta: 500)
        measurement.record(delta: -300)
        measurement.record(delta: 9000) // > 8192 → alias observed
        XCTAssertEqual(measurement.maxPerEventDelta, 9000)
        XCTAssertEqual(measurement.eventCount, 3)
        XCTAssertTrue(measurement.aliasObserved)
    }

    func testTickMeasurementSuggestionAndEmptyState() {
        var measurement = PlatterTickMeasurement()
        XCTAssertNil(measurement.suggestedSampleSecondsPerTick(targetSeconds: 1.0))
        measurement.record(delta: 500)
        measurement.record(delta: 500) // absoluteTickSum = 1000
        XCTAssertEqual(measurement.suggestedSampleSecondsPerTick(targetSeconds: 1.0)!, 1.0 / 1000.0, accuracy: 1e-12)
        XCTAssertNil(measurement.suggestedSampleSecondsPerTick(targetSeconds: 0)) // no target
    }

    // MARK: - Crossfader normalisation + no-value gating

    func testCrossfaderNormalisesFullRange() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 127), 1.0, accuracy: 1e-12)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.normalizedCrossfader(cc: 64), 64.0 / 127.0, accuracy: 1e-12)
    }

    func testGatingDoesNotMuteBeforeFirstValue() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: false, crossfader: 0.0), 1.0)
    }

    func testGatingOffIsAlwaysFullGain() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: false, crossfaderValid: true, crossfader: 0.0), 1.0)
    }

    func testGatingAppliesAfterValueReceived() {
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.0), 0.0)
        XCTAssertEqual(ScratchPlatterPlayheadMapper.outputGain(applyGating: true, crossfaderValid: true, crossfader: 0.5), 0.5, accuracy: 1e-6)
    }

    // MARK: - Per-deck pitch-bend filtering

    func testIsPitchBendChannelMatchesOnlySelectedDeck() {
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 0))
        XCTAssertTrue(ScratchPlatterPlayheadMapper.isPitchBendChannel(1, forDeck: 1))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(0, forDeck: 1))
    }

    func testIsPitchBendChannelRejectsNonPlatterChannelsAndNil() {
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(15, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(nil, forDeck: 0))
        XCTAssertFalse(ScratchPlatterPlayheadMapper.isPitchBendChannel(2, forDeck: 2))
    }

    func testDeckForRawChannelMapping() {
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(0), .left)
        XCTAssertEqual(ScratchPlatterDeck.forRawChannel(1), .right)
        XCTAssertNil(ScratchPlatterDeck.forRawChannel(2))
        XCTAssertEqual(ScratchPlatterDeck.left.rawChannel, 0)
        XCTAssertEqual(ScratchPlatterDeck.right.rawChannel, 1)
    }
}
